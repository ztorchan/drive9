package mysql

import (
	"context"
	"strings"
	"testing"

	"github.com/mem9-ai/drive9/pkg/tenant"
)

func TestNewProvisioner(t *testing.T) {
	p, err := New(Config{
		AdminDSN:       "root:secret@tcp(127.0.0.1:3307)/mysql?parseTime=true",
		DatabasePrefix: "drive9_t_",
		UserPrefix:     "drive9_u_",
		TLSEnabled:     true,
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if p.ProviderType() != tenant.ProviderMySQL {
		t.Fatalf("provider = %q, want %q", p.ProviderType(), tenant.ProviderMySQL)
	}
	if !p.TenantDBTLSEnabled() {
		t.Fatal("TLS should be enabled")
	}
	if p.host != "127.0.0.1" || p.port != 3307 {
		t.Fatalf("admin address = %s:%d", p.host, p.port)
	}

	databaseName, err := p.DatabaseName("tenant-1")
	if err != nil {
		t.Fatalf("DatabaseName: %v", err)
	}
	username, err := p.Username("tenant-1")
	if err != nil {
		t.Fatalf("Username: %v", err)
	}
	if databaseName == username || !strings.HasPrefix(databaseName, "drive9_t_") || !strings.HasPrefix(username, "drive9_u_") {
		t.Fatalf("generated names = %q, %q", databaseName, username)
	}
	if len(databaseName) > maxDatabaseNameLength || len(username) > maxUserNameLength {
		t.Fatalf("generated names exceed MySQL limits: %q, %q", databaseName, username)
	}
	otherDatabaseName, err := p.DatabaseName("tenant-2")
	if err != nil {
		t.Fatalf("DatabaseName second tenant: %v", err)
	}
	if databaseName == otherDatabaseName {
		t.Fatal("different tenants must not share a database name")
	}
}

func TestNewProvisionerFromEnv(t *testing.T) {
	t.Setenv(EnvAdminDSN, "root:secret@tcp(localhost:3306)/mysql")
	t.Setenv(EnvDatabasePrefix, "tenant_")
	t.Setenv(EnvUserPrefix, "user_")
	t.Setenv(EnvAccountHost, "%")
	t.Setenv(EnvTLS, "true")

	p, err := NewProvisionerFromEnv()
	if err != nil {
		t.Fatalf("NewProvisionerFromEnv: %v", err)
	}
	if p.databasePrefix != "tenant_" || p.userPrefix != "user_" || p.accountHost != "%" {
		t.Fatalf("provider configuration = %+v", p)
	}
	if !p.TenantDBTLSEnabled() {
		t.Fatal("expected TLS enabled from environment")
	}
}

func TestNewProvisionerRejectsUnsafeConfiguration(t *testing.T) {
	tests := []struct {
		name string
		cfg  Config
	}{
		{
			name: "multi statements",
			cfg:  Config{AdminDSN: "root:secret@tcp(localhost:3306)/mysql?multiStatements=true"},
		},
		{
			name: "unix socket",
			cfg:  Config{AdminDSN: "root:secret@unix(/tmp/mysql.sock)/mysql"},
		},
		{
			name: "unsafe database prefix",
			cfg:  Config{AdminDSN: "root:secret@tcp(localhost:3306)/mysql", DatabasePrefix: "tenant-"},
		},
		{
			name: "unsafe account host",
			cfg:  Config{AdminDSN: "root:secret@tcp(localhost:3306)/mysql", AccountHost: "%' OR 1=1 --"},
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := New(tt.cfg); err == nil {
				t.Fatal("expected configuration error")
			}
		})
	}
}

func TestDeprovisionNamesAreTenantScoped(t *testing.T) {
	p, err := New(Config{AdminDSN: "root:secret@tcp(localhost:3306)/mysql"})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	name, err := p.DatabaseName("tenant-1")
	if err != nil {
		t.Fatalf("DatabaseName: %v", err)
	}
	if err := p.Deprovision(context.Background(), nil); err == nil {
		t.Fatal("nil cluster should be rejected before any database operation")
	}
	if err := p.Deprovision(context.Background(), &tenant.ClusterInfo{
		TenantID:  "tenant-1",
		ClusterID: name,
		DBName:    "other_database",
		Provider:  tenant.ProviderMySQL,
	}); err == nil || !strings.Contains(err.Error(), "unexpected tenant database") {
		t.Fatalf("unexpected database should be rejected, got %v", err)
	}
}

func TestQuoteHelpers(t *testing.T) {
	if got := quoteIdentifier("tenant_name"); got != "`tenant_name`" {
		t.Fatalf("quoteIdentifier = %q", got)
	}
	if got := accountLiteral("user_name", "%"); got != "'user_name'@'%'" {
		t.Fatalf("accountLiteral = %q", got)
	}
}
