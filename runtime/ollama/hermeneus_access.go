// Package hermeneusaccess protects private native inference listeners and clients.
package hermeneusaccess

import (
	"crypto/subtle"
	"errors"
	"net"
	"net/http"
	"os"
)

func Protect(next http.Handler) http.Handler { return protect(next, true) }

func protect(next http.Handler, requireLoopback bool) http.Handler {
	token := os.Getenv("HERMENEUS_OLLAMA_TOKEN")
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		peer := net.ParseIP(host)
		authorization := r.Header.Values("Authorization")
		if len(token) < 32 || (requireLoopback && (err != nil || peer == nil || !peer.IsLoopback())) ||
			len(r.Header.Values("Origin")) != 0 || len(authorization) != 1 ||
			subtle.ConstantTimeCompare([]byte(authorization[0]), []byte("Bearer "+token)) != 1 {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		next.ServeHTTP(w, r)
	})
}

type transport struct {
	next  http.RoundTripper
	token string
}

func (t transport) RoundTrip(r *http.Request) (*http.Response, error) {
	// Native inference clients have no reason to contact external hosts or proxies.
	if r.URL.Scheme != "http" || r.URL.Hostname() != "127.0.0.1" {
		return nil, errors.New("native inference endpoint must be loopback")
	}
	request := r.Clone(r.Context())
	if t.token != "" {
		request.Header.Set("Authorization", "Bearer "+t.token)
	}
	return t.next.RoundTrip(request)
}

func NewClient(disableKeepAlives bool) *http.Client {
	return &http.Client{
		Transport: transport{next: &http.Transport{DisableKeepAlives: disableKeepAlives, Proxy: nil, DialContext: dialNative},
			token: os.Getenv("HERMENEUS_OLLAMA_TOKEN")},
		CheckRedirect: func(r *http.Request, previous []*http.Request) error {
			if len(previous) >= 10 || r.URL.Scheme != previous[0].URL.Scheme || r.URL.Host != previous[0].URL.Host {
				return errors.New("native inference redirect outside original endpoint")
			}
			return nil
		},
	}
}
