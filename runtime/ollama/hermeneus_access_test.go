package hermeneusaccess

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestNativeListenerRequiresCapability(t *testing.T) {
	token := strings.Repeat("a", 44)
	t.Setenv("HERMENEUS_OLLAMA_TOKEN", token)
	protected := Protect(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) }))
	for _, test := range []struct {
		auth, origin, peer string
		want               int
	}{
		{"", "", "127.0.0.1:1234", 403}, {"Bearer wrong", "", "127.0.0.1:1234", 403},
		{"Bearer " + token, "https://evil.invalid", "127.0.0.1:1234", 403},
		{"Bearer " + token, "", "192.0.2.1:1234", 403},
		{"Bearer " + token, "", "127.0.0.1:1234", 204},
	} {
		req := httptest.NewRequest("POST", "http://127.0.0.1/completion", nil)
		req.RemoteAddr = test.peer
		if test.auth != "" {
			req.Header.Set("Authorization", test.auth)
		}
		if test.origin != "" {
			req.Header.Set("Origin", test.origin)
		}
		result := httptest.NewRecorder()
		protected.ServeHTTP(result, req)
		if result.Code != test.want {
			t.Fatalf("got %d, want %d", result.Code, test.want)
		}
	}
}

func TestClientDoesNotLeakCapabilityAcrossRedirect(t *testing.T) {
	t.Setenv("HERMENEUS_OLLAMA_TOKEN", strings.Repeat("a", 44))
	leaked := false
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { leaked = true }))
	defer other.Close()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+strings.Repeat("a", 44) {
			t.Error("missing capability")
		}
		if r.URL.Path == "/external" {
			http.Redirect(w, r, other.URL, 307)
			return
		}
		if r.URL.Path == "/health" {
			http.Redirect(w, r, "/status", 307)
			return
		}
		io.WriteString(w, "ready")
	}))
	defer server.Close()
	client := NewClient(false)
	response, err := client.Get(server.URL + "/health")
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if _, err := client.Get(server.URL + "/external"); err == nil {
		t.Fatal("cross-endpoint redirect accepted")
	}
	if leaked {
		t.Fatal("capability leaked")
	}
	if _, err := client.Get("http://example.invalid/"); err == nil {
		t.Fatal("external host accepted")
	}
}
