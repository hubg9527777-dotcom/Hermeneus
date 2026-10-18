package cmd

import (
	"net"
	"strconv"
	"testing"
)

func TestHermeneusInheritedListenerRetainsParentPort(t *testing.T) {
	parent, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer parent.Close()
	file, err := parent.(*net.TCPListener).File()
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	t.Setenv("OLLAMA_HOST", parent.Addr().String())
	t.Setenv("HERMENEUS_OLLAMA_LISTENER_FD", strconv.Itoa(int(file.Fd())))
	child, err := hermeneusListener()
	if err != nil {
		t.Fatal(err)
	}
	if child.Addr().String() != parent.Addr().String() {
		t.Fatal("Wrong inherited endpoint")
	}
	child.Close()
	if attacker, err := net.Listen("tcp4", parent.Addr().String()); err == nil {
		attacker.Close()
		t.Fatal("Parent port was released")
	}
}

func TestHermeneusInheritedListenerRejectsWrongEndpoint(t *testing.T) {
	parent, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer parent.Close()
	file, err := parent.(*net.TCPListener).File()
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	t.Setenv("OLLAMA_HOST", "127.0.0.1:1")
	t.Setenv("HERMENEUS_OLLAMA_LISTENER_FD", strconv.Itoa(int(file.Fd())))
	if child, err := hermeneusListener(); err == nil {
		child.Close()
		t.Fatal("Wrong endpoint accepted")
	}
}
