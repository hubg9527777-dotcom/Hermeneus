package cmd

import (
	"fmt"
	"net"
	"os"
	"strconv"

	"github.com/ollama/ollama/envconfig"
)

// The parent keeps the listener open. Do not release-and-rebind a reserved port.
func hermeneusListener() (net.Listener, error) {
	raw := os.Getenv("HERMENEUS_OLLAMA_LISTENER_FD")
	if raw == "" {
		// Explicit source/CLI development remains possible; the desktop always
		// supplies an inherited descriptor and never selects this path.
		return net.Listen("tcp", envconfig.Host().Host)
	}
	fd, err := strconv.Atoi(raw)
	if err != nil || fd < 0 {
		return nil, fmt.Errorf("invalid inherited listener descriptor")
	}
	file := os.NewFile(uintptr(fd), "hermeneus-listener")
	if file == nil {
		return nil, fmt.Errorf("missing inherited listener")
	}
	defer file.Close()
	listener, err := net.FileListener(file)
	if err != nil {
		return nil, err
	}
	address, ok := listener.Addr().(*net.TCPAddr)
	if !ok || !address.IP.Equal(net.IPv4(127, 0, 0, 1)) || address.String() != envconfig.Host().Host {
		listener.Close()
		return nil, fmt.Errorf("inherited listener does not match private endpoint")
	}
	return listener, nil
}
