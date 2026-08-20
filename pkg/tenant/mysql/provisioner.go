// Package mysql provisions one MySQL database and least-privilege tenant user per tenant.
package mysql

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"

	mysqlDriver "github.com/go-sql-driver/mysql"

	"github.com/mem9-ai/drive9/pkg/mysqlutil"
	"github.com/mem9-ai/drive9/pkg/tenant"
	"github.com/mem9-ai/drive9/pkg/tenant/schema"
)

const (
	EnvAdminDSN       = "DRIVE9_MYSQL_ADMIN_DSN"
	EnvDatabasePrefix = "DRIVE9_MYSQL_DATABASE_PREFIX"
	EnvUserPrefix     = "DRIVE9_MYSQL_USER_PREFIX"
	EnvAccountHost    = "DRIVE9_MYSQL_ACCOUNT_HOST"
	EnvTLS            = "DRIVE9_MYSQL_TLS"

	defaultDatabasePrefix = "drive9_t_"
	defaultUserPrefix     = "drive9_u_"
	defaultAccountHost    = "%"
	databaseHashLength    = 32
	userHashLength        = 20
	maxDatabaseNameLength = 64
	maxUserNameLength     = 32
)

type Config struct {
	AdminDSN       string
	DatabasePrefix string
	UserPrefix     string
	AccountHost    string
	TLSEnabled     bool
}

type Provisioner struct {
	adminDSN       string
	host           string
	port           int
	databasePrefix string
	userPrefix     string
	accountHost    string
	tlsEnabled     bool
}

var _ tenant.Provisioner = (*Provisioner)(nil)
var _ tenant.Deprovisioner = (*Provisioner)(nil)

func NewProvisionerFromEnv() (*Provisioner, error) {
	rawDSN := strings.TrimSpace(os.Getenv(EnvAdminDSN))
	if rawDSN == "" {
		return nil, fmt.Errorf("%s is required", EnvAdminDSN)
	}

	tlsEnabled := true
	if rawTLS := strings.TrimSpace(os.Getenv(EnvTLS)); rawTLS != "" {
		parsed, err := strconv.ParseBool(rawTLS)
		if err != nil {
			return nil, fmt.Errorf("invalid %s: %w", EnvTLS, err)
		}
		tlsEnabled = parsed
	}

	return New(Config{
		AdminDSN:       rawDSN,
		DatabasePrefix: envOrDefault(EnvDatabasePrefix, defaultDatabasePrefix),
		UserPrefix:     envOrDefault(EnvUserPrefix, defaultUserPrefix),
		AccountHost:    envOrDefault(EnvAccountHost, defaultAccountHost),
		TLSEnabled:     tlsEnabled,
	})
}

func New(cfg Config) (*Provisioner, error) {
	rawDSN := strings.TrimSpace(cfg.AdminDSN)
	if rawDSN == "" {
		return nil, fmt.Errorf("%s is required", EnvAdminDSN)
	}
	parsed, err := mysqlDriver.ParseDSN(rawDSN)
	if err != nil {
		return nil, fmt.Errorf("parse %s: %w", EnvAdminDSN, err)
	}
	if parsed.MultiStatements {
		return nil, fmt.Errorf("%s must not enable multiStatements", EnvAdminDSN)
	}
	if parsed.Net != "tcp" {
		return nil, fmt.Errorf("%s must use a tcp MySQL address", EnvAdminDSN)
	}
	host, port, err := tcpHostPort(parsed.Addr)
	if err != nil {
		return nil, fmt.Errorf("parse MySQL admin address: %w", err)
	}

	databasePrefix := strings.ToLower(strings.TrimSpace(cfg.DatabasePrefix))
	if databasePrefix == "" {
		databasePrefix = defaultDatabasePrefix
	}
	if err := validatePrefix(databasePrefix, maxDatabaseNameLength-databaseHashLength); err != nil {
		return nil, fmt.Errorf("invalid database prefix: %w", err)
	}
	userPrefix := strings.ToLower(strings.TrimSpace(cfg.UserPrefix))
	if userPrefix == "" {
		userPrefix = defaultUserPrefix
	}
	if err := validatePrefix(userPrefix, maxUserNameLength-userHashLength); err != nil {
		return nil, fmt.Errorf("invalid user prefix: %w", err)
	}
	accountHost := strings.TrimSpace(cfg.AccountHost)
	if accountHost == "" {
		accountHost = defaultAccountHost
	}
	if err := validateAccountHost(accountHost); err != nil {
		return nil, fmt.Errorf("invalid account host: %w", err)
	}

	parsed.DBName = ""
	parsed.ParseTime = true
	adminDSN := parsed.FormatDSN()
	return &Provisioner{
		adminDSN:       adminDSN,
		host:           host,
		port:           port,
		databasePrefix: databasePrefix,
		userPrefix:     userPrefix,
		accountHost:    accountHost,
		tlsEnabled:     cfg.TLSEnabled,
	}, nil
}

func (p *Provisioner) ProviderType() string { return tenant.ProviderMySQL }

func (p *Provisioner) TenantDBTLSEnabled() bool {
	return p != nil && p.tlsEnabled
}

func (p *Provisioner) DatabaseName(tenantID string) (string, error) {
	if p == nil {
		return "", fmt.Errorf("nil MySQL provisioner")
	}
	if strings.TrimSpace(tenantID) == "" {
		return "", fmt.Errorf("tenant ID is required")
	}
	return p.databasePrefix + tenantDigest(tenantID, databaseHashLength), nil
}

func (p *Provisioner) Username(tenantID string) (string, error) {
	if p == nil {
		return "", fmt.Errorf("nil MySQL provisioner")
	}
	if strings.TrimSpace(tenantID) == "" {
		return "", fmt.Errorf("tenant ID is required")
	}
	return p.userPrefix + tenantDigest(tenantID, userHashLength), nil
}

func (p *Provisioner) InitSchema(ctx context.Context, dsn string) error {
	return schema.InitMySQLNoEmbeddingTenantSchemaContext(ctx, dsn)
}

func (p *Provisioner) Provision(ctx context.Context, tenantID string) (*tenant.ClusterInfo, error) {
	databaseName, err := p.DatabaseName(tenantID)
	if err != nil {
		return nil, err
	}
	username, err := p.Username(tenantID)
	if err != nil {
		return nil, err
	}
	password, err := randomPassword()
	if err != nil {
		return nil, fmt.Errorf("generate tenant MySQL password: %w", err)
	}
	cluster := &tenant.ClusterInfo{
		TenantID:  tenantID,
		ClusterID: databaseName,
		Host:      p.host,
		Port:      p.port,
		Username:  username,
		Password:  password,
		DBName:    databaseName,
		Provider:  tenant.ProviderMySQL,
	}

	db, err := p.openAdmin(ctx)
	if err != nil {
		return nil, err
	}
	defer func() { _ = mysqlutil.CloseInstrumented(db) }()

	if err := ensureDatabase(ctx, db, databaseName); err != nil {
		return cluster, fmt.Errorf("create tenant database: %w", err)
	}
	if err := ensureUser(ctx, db, username, password, p.accountHost); err != nil {
		return cluster, fmt.Errorf("create tenant MySQL user: %w", err)
	}
	if err := grantDatabase(ctx, db, databaseName, username, p.accountHost); err != nil {
		return cluster, fmt.Errorf("grant tenant MySQL user: %w", err)
	}
	return cluster, nil
}

func (p *Provisioner) Deprovision(ctx context.Context, cluster *tenant.ClusterInfo) error {
	if p == nil {
		return fmt.Errorf("nil MySQL provisioner")
	}
	if cluster == nil {
		return fmt.Errorf("tenant cluster is required")
	}
	if cluster.Provider != "" && cluster.Provider != tenant.ProviderMySQL {
		return fmt.Errorf("unsupported cluster provider %q", cluster.Provider)
	}
	databaseName, err := p.DatabaseName(cluster.TenantID)
	if err != nil {
		return err
	}
	if cluster.DBName != databaseName {
		return fmt.Errorf("refusing to delete unexpected tenant database %q", cluster.DBName)
	}
	if cluster.ClusterID != "" && cluster.ClusterID != databaseName {
		return fmt.Errorf("refusing to delete unexpected tenant cluster %q", cluster.ClusterID)
	}
	username, err := p.Username(cluster.TenantID)
	if err != nil {
		return err
	}
	if cluster.Username != "" && cluster.Username != username {
		return fmt.Errorf("refusing to delete unexpected tenant MySQL user %q", cluster.Username)
	}

	db, err := p.openAdmin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = mysqlutil.CloseInstrumented(db) }()
	if _, err := db.ExecContext(ctx, "DROP DATABASE IF EXISTS "+quoteIdentifier(databaseName)); err != nil {
		return fmt.Errorf("drop tenant database: %w", err)
	}
	if _, err := db.ExecContext(ctx, "DROP USER IF EXISTS "+accountLiteral(username, p.accountHost)); err != nil {
		return fmt.Errorf("drop tenant MySQL user: %w", err)
	}
	return nil
}

func (p *Provisioner) openAdmin(ctx context.Context) (*sql.DB, error) {
	if p == nil || p.adminDSN == "" {
		return nil, fmt.Errorf("MySQL provisioner is not configured")
	}
	return mysqlutil.OpenInstrumented(ctx, p.adminDSN, mysqlutil.RoleMeta)
}

func ensureDatabase(ctx context.Context, db *sql.DB, databaseName string) error {
	if db == nil {
		return fmt.Errorf("nil admin database")
	}
	_, err := db.ExecContext(ctx, "CREATE DATABASE IF NOT EXISTS "+quoteIdentifier(databaseName)+" CHARACTER SET utf8mb4")
	return err
}

func ensureUser(ctx context.Context, db *sql.DB, username, password, accountHost string) error {
	account := accountLiteral(username, accountHost)
	passwordLiteral := quoteString(password)
	if _, err := db.ExecContext(ctx, "CREATE USER IF NOT EXISTS "+account+" IDENTIFIED BY "+passwordLiteral); err != nil {
		return err
	}
	_, err := db.ExecContext(ctx, "ALTER USER "+account+" IDENTIFIED BY "+passwordLiteral)
	return err
}

func grantDatabase(ctx context.Context, db *sql.DB, databaseName, username, accountHost string) error {
	_, err := db.ExecContext(ctx, "GRANT ALL PRIVILEGES ON "+quoteIdentifier(databaseName)+".* TO "+accountLiteral(username, accountHost))
	return err
}

func tcpHostPort(addr string) (string, int, error) {
	host, portText, err := net.SplitHostPort(addr)
	if err != nil {
		return "", 0, err
	}
	port, err := strconv.Atoi(portText)
	if err != nil || port <= 0 || port > 65535 {
		return "", 0, fmt.Errorf("invalid port %q", portText)
	}
	if host == "" {
		return "", 0, fmt.Errorf("empty host")
	}
	return host, port, nil
}

func validatePrefix(prefix string, maxLength int) error {
	if prefix == "" || len(prefix) > maxLength {
		return fmt.Errorf("must be between 1 and %d ASCII characters", maxLength)
	}
	for i, r := range prefix {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9' && i > 0) || r == '_' {
			continue
		}
		return fmt.Errorf("contains unsupported character %q", r)
	}
	if prefix[0] < 'a' || prefix[0] > 'z' {
		return fmt.Errorf("must start with a lowercase letter")
	}
	return nil
}

func validateAccountHost(accountHost string) error {
	if accountHost == "" || len(accountHost) > 255 {
		return fmt.Errorf("must be between 1 and 255 characters")
	}
	for _, r := range accountHost {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') ||
			(r >= '0' && r <= '9') || strings.ContainsRune("._:%-", r) {
			continue
		}
		return fmt.Errorf("contains unsupported character %q", r)
	}
	return nil
}

func quoteIdentifier(identifier string) string {
	return "`" + strings.ReplaceAll(identifier, "`", "``") + "`"
}

func accountLiteral(username, accountHost string) string {
	return quoteString(username) + "@" + quoteString(accountHost)
}

func quoteString(value string) string {
	value = strings.ReplaceAll(value, "\\", "\\\\")
	value = strings.ReplaceAll(value, "'", "''")
	return "'" + value + "'"
}

func tenantDigest(tenantID string, length int) string {
	digest := sha256.Sum256([]byte(tenantID))
	return hex.EncodeToString(digest[:])[:length]
}

func randomPassword() (string, error) {
	buf := make([]byte, 24)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}

func envOrDefault(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}
