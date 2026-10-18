//go:build darwin

package mlx

import "testing"

func TestHermeneusMetal4MinimumOS(t *testing.T) {
 for _, tc := range []struct{ version string; allowed bool }{
  {"14.0", false}, {"15.7", false}, {"26", false}, {"26.0", false},
  {"26.1.9", false}, {"26.2", true}, {"26.2.1", true}, {"27", true},
  {"27.0", true}, {"", false}, {"unknown", false}, {"26.invalid", false},
  {"26.-1", false}, {"-1.2", false},
 } {
  if got := hermeneusVersionAtLeast(tc.version, 26, 2); got != tc.allowed {
   t.Errorf("version %q: Metal 4 allowed=%v, want %v", tc.version, got, tc.allowed)
  }
 }
 if !isCompatibleMLXVariant("mlx_metal_v3") { t.Fatal("Metal 3 fallback was disabled") }
}
