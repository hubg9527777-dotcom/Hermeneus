package hermeneusaccess

import (
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestNativeEndpointHasPrivateDirectoryAndNoTCPFallback(t *testing.T) {
	endpoint, err := NewNativeEndpoint()
	if err != nil {
		t.Fatal(err)
	}
	defer ReleaseNativeEndpoint(endpoint.Port)
	info, err := os.Stat(endpoint.directory)
	if err != nil || info.Mode().Perm() != 0700 {
		t.Fatal("Native socket directory must be 0700")
	}
	// An arbitrary loopback listener must never receive the capability.
	hit := false
	attacker := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { hit = true }))
	defer attacker.Close()
	t.Setenv("HERMENEUS_OLLAMA_TOKEN", strings.Repeat("a", 44))
	if _, err := NewClient(false).Get(attacker.URL); err == nil {
		t.Fatal("Unregistered TCP endpoint accepted")
	}
	if hit {
		t.Fatal("Untrusted local process received native request")
	}
}
