package tenant

import "testing"

func TestNormalizeProvider(t *testing.T) {
	for _, p := range []string{ProviderDB9, ProviderTiDBZero, ProviderTiDBCloudNative, ProviderMySQL} {
		got, err := NormalizeProvider(p)
		if err != nil {
			t.Fatalf("provider %s should be accepted: %v", p, err)
		}
		if got != p {
			t.Fatalf("expected %s got %s", p, got)
		}
	}
	if _, err := NormalizeProvider("bad-provider"); err == nil {
		t.Fatal("expected error for invalid provider")
	}
	if _, err := NormalizeProvider(ProviderTiDBCloudStarterLegacy); err == nil {
		t.Fatal("legacy starter provider should not be accepted for new provisioning")
	}
}

func TestSmallInDB(t *testing.T) {
	for _, provider := range []string{ProviderTiDBZero, ProviderTiDBCloudNative, ProviderTiDBCloudStarterLegacy, ProviderMySQL} {
		if !SmallInDB(provider) {
			t.Fatalf("%s should store small files in db", provider)
		}
	}
	if SmallInDB(ProviderDB9) {
		t.Fatal("db9 should not store small files in db")
	}
}

func TestUsesTiDBAutoEmbedding(t *testing.T) {
	for _, provider := range []string{ProviderTiDBZero, ProviderTiDBCloudNative, ProviderTiDBCloudStarterLegacy} {
		if !UsesTiDBAutoEmbedding(provider) {
			t.Fatalf("provider %s should use TiDB auto-embedding mode", provider)
		}
	}
	for _, provider := range []string{ProviderDB9, ProviderMySQL} {
		if UsesTiDBAutoEmbedding(provider) {
			t.Fatalf("%s should not use TiDB auto-embedding mode", provider)
		}
	}
}

func TestSupportsClusterDelete(t *testing.T) {
	for _, provider := range []string{ProviderTiDBCloudNative, ProviderTiDBCloudStarterLegacy, ProviderMySQL} {
		if !SupportsClusterDelete(provider) {
			t.Fatalf("%s should support cluster delete", provider)
		}
	}
	for _, provider := range []string{ProviderDB9, ProviderTiDBZero} {
		if SupportsClusterDelete(provider) {
			t.Fatalf("%s should not support cluster delete", provider)
		}
	}
}

func TestSupportsSemanticTasks(t *testing.T) {
	if !SupportsSemanticTasks(ProviderDB9) {
		t.Fatal("db9 should support app-managed semantic tasks")
	}
	for _, provider := range []string{ProviderTiDBZero, ProviderTiDBCloudNative} {
		if !SupportsSemanticTasks(provider) {
			t.Fatalf("%s should support database-managed semantic tasks", provider)
		}
	}
	if SupportsSemanticTasks(ProviderMySQL) || SupportsAppSemanticTasks(ProviderMySQL) {
		t.Fatal("mysql should not support semantic tasks")
	}
}

func TestUsesTiDBCloudNativeCredentials(t *testing.T) {
	for _, provider := range []string{ProviderTiDBCloudNative} {
		if !UsesTiDBCloudNativeCredentials(provider) {
			t.Fatalf("%s should use the TiDB Cloud native credential family", provider)
		}
	}
	for _, provider := range []string{ProviderDB9, ProviderTiDBZero, ProviderTiDBCloudStarterLegacy, ProviderMySQL} {
		if UsesTiDBCloudNativeCredentials(provider) {
			t.Fatalf("%s should not use the TiDB Cloud native credential family", provider)
		}
	}
}
