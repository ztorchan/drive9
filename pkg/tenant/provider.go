package tenant

import "fmt"

const (
	ProviderDB9             = "db9"
	ProviderTiDBZero        = "tidb_zero"
	ProviderTiDBCloudNative = "tidb_cloud_native"
	ProviderMySQL           = "mysql"

	// ProviderTiDBCloudStarterLegacy is kept only for tenant rows persisted
	// before starter provisioning was removed. Do not accept it for new
	// provisioning configuration.
	ProviderTiDBCloudStarterLegacy = "tidb_cloud_starter"
)

func NormalizeProvider(provider string) (string, error) {
	switch provider {
	case ProviderDB9, ProviderTiDBZero, ProviderTiDBCloudNative, ProviderMySQL:
		return provider, nil
	default:
		return "", fmt.Errorf("unsupported provider: %s", provider)
	}
}

// UsesTiDBCloudNativeCredentials reports whether provider uses the TiDB Cloud
// Native public/private-key request and default-credential contract.
func UsesTiDBCloudNativeCredentials(provider string) bool {
	return provider == ProviderTiDBCloudNative
}

func SmallInDB(provider string) bool {
	switch provider {
	case ProviderTiDBZero, ProviderTiDBCloudNative, ProviderTiDBCloudStarterLegacy, ProviderMySQL:
		return true
	default:
		return false
	}
}

// UsesTiDBAutoEmbedding reports whether the provider should run the TiDB
// database-managed auto-embedding mode.
func UsesTiDBAutoEmbedding(provider string) bool {
	switch provider {
	case ProviderTiDBZero, ProviderTiDBCloudNative, ProviderTiDBCloudStarterLegacy:
		return true
	default:
		return false
	}
}

// SupportsClusterDelete reports whether a persisted tenant provider can delete
// its backing database or TiDB Cloud cluster. The legacy starter value is kept
// only so rows persisted before starter provisioning was removed keep their
// cleanup path.
func SupportsClusterDelete(provider string) bool {
	return provider == ProviderTiDBCloudNative || provider == ProviderTiDBCloudStarterLegacy || provider == ProviderMySQL
}

// SupportsAppSemanticTasks reports whether the provider supports app-managed
// embedding and semantic extraction tasks. MySQL intentionally exposes only
// the non-semantic filesystem schema.
func SupportsAppSemanticTasks(provider string) bool {
	return provider == ProviderDB9
}

// SupportsSemanticTasks reports whether a provider has any semantic task
// implementation, either database-managed or app-managed.
func SupportsSemanticTasks(provider string) bool {
	return UsesTiDBAutoEmbedding(provider) || SupportsAppSemanticTasks(provider)
}
