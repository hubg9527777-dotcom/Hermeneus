package hermeneusaccess

import (
	"context"
	"errors"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"sync"
)

type NativeEndpoint struct {
	Port        int
	Path        string
	directory   string
	reservation net.Listener
}

var nativeEndpoints = struct {
	sync.RWMutex
	entries map[string]*NativeEndpoint
}{entries: make(map[string]*NativeEndpoint)}

// The TCP number is only an internal routing key. All native model traffic uses
// a Unix socket inside a private directory; no native TCP listener is exposed.
func NewNativeEndpoint() (*NativeEndpoint, error) {
	reservation, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	directory, err := os.MkdirTemp("/tmp", "hn-")
	if err != nil {
		reservation.Close()
		return nil, err
	}
	endpoint := &NativeEndpoint{Port: reservation.Addr().(*net.TCPAddr).Port,
		Path: filepath.Join(directory, "model.sock"), directory: directory, reservation: reservation}
	nativeEndpoints.Lock()
	nativeEndpoints.entries[reservation.Addr().String()] = endpoint
	nativeEndpoints.Unlock()
	return endpoint, nil
}

func ReleaseNativeEndpoint(port int) {
	key := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	nativeEndpoints.Lock()
	endpoint := nativeEndpoints.entries[key]
	delete(nativeEndpoints.entries, key)
	nativeEndpoints.Unlock()
	if endpoint != nil {
		endpoint.reservation.Close()
		os.RemoveAll(endpoint.directory)
	}
}

func dialNative(ctx context.Context, network, address string) (net.Conn, error) {
	nativeEndpoints.RLock()
	endpoint := nativeEndpoints.entries[address]
	var path string
	if endpoint != nil {
		path = endpoint.Path
	}
	nativeEndpoints.RUnlock()
	if path == "" {
		return nil, errors.New("native endpoint is not registered; refusing TCP fallback")
	}
	return (&net.Dialer{}).DialContext(ctx, "unix", path)
}

func ServeNativeUnix(handler http.Handler) error {
	path := os.Getenv("HERMENEUS_NATIVE_SOCKET")
	if path == "" || !filepath.IsAbs(path) {
		return errors.New("missing private native socket")
	}
	info, err := os.Lstat(filepath.Dir(path))
	if err != nil || !info.IsDir() || info.Mode().Perm() != 0700 {
		return errors.New("native socket directory is not private")
	}
	listener, err := net.Listen("unix", path)
	if err != nil {
		return err
	}
	defer listener.Close()
	return (&http.Server{Handler: protect(handler, false)}).Serve(listener)
}
