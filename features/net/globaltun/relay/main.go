// gtrelay - the gateway half of globaltun: a SOCKS5 relay that terminates and
// re-originates every flow as an ordinary socket.
//
// This is a port of rsocks.py with one purpose: removing the gateway's last
// prerequisite. The Python version needs a python3 on the far side, which an
// arbitrary box may not have; this builds with CGO off into a single static
// binary with no libc, no dynamic loader and no interpreter, so the only thing
// the gateway must provide is an sshd and a writable /tmp.
//
// Nothing here enumerates interfaces. The reference gateway is an unrooted
// Android phone under proot, where netlink is blocked for apps, so anything
// that reads routes or addresses (sing-box's tun inbound, for one) wedges on
// startup. Sockets are all that works, and sockets are all this uses.
package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"sync"
	"syscall"
	"time"
)

const (
	// Magic CONNECT targets. ssh -L carries a byte stream and sshd never
	// sendto()s, so datagrams reach us framed inside one TCP connection and
	// have to be addressed by something the SOCKS5 request can carry.
	muxHost  = "udp.mux.arpa"
	icmpHost = "icmp.mux.arpa"
	muxPort  = 1
	bufsz    = 65536
)

// Frame: [atyp:1][addr:4|16][port:2][len:2][payload]. Only atyp 1 is ever
// emitted -- the local side sends v4 destinations and replies come back from
// v4 peers -- but atyp 4 is accepted so a v6-capable local side is not a
// protocol change on this end.
func packFrame(ip net.IP, port int, payload []byte) []byte {
	v4 := ip.To4()
	if v4 == nil {
		v4 = net.IPv4zero.To4()
	}
	b := make([]byte, 9+len(payload))
	b[0] = 1
	copy(b[1:5], v4)
	binary.BigEndian.PutUint16(b[5:7], uint16(port))
	binary.BigEndian.PutUint16(b[7:9], uint16(len(payload)))
	copy(b[9:], payload)
	return b
}

func readFrame(c net.Conn) (net.IP, int, []byte, error) {
	var h [1]byte
	if _, err := io.ReadFull(c, h[:]); err != nil {
		return nil, 0, nil, err
	}
	var ip net.IP
	switch h[0] {
	case 1:
		a := make([]byte, 4)
		if _, err := io.ReadFull(c, a); err != nil {
			return nil, 0, nil, err
		}
		ip = net.IP(a)
	case 4:
		a := make([]byte, 16)
		if _, err := io.ReadFull(c, a); err != nil {
			return nil, 0, nil, err
		}
		ip = net.IP(a)
	default:
		return nil, 0, nil, fmt.Errorf("bad atyp %d", h[0])
	}
	var t [4]byte
	if _, err := io.ReadFull(c, t[:]); err != nil {
		return nil, 0, nil, err
	}
	port := int(binary.BigEndian.Uint16(t[0:2]))
	n := int(binary.BigEndian.Uint16(t[2:4]))
	p := make([]byte, n)
	if _, err := io.ReadFull(c, p); err != nil {
		return nil, 0, nil, err
	}
	return ip, port, p, nil
}

// One TCP stream <-> one unconnected UDP socket doing real sendto/recvfrom, so
// the peer sees datagrams from this box and replies to it directly.
func udpMux(c net.Conn) {
	u, err := net.ListenUDP("udp4", nil)
	if err != nil {
		c.Close()
		return
	}
	var once sync.Once
	shut := func() { once.Do(func() { u.Close(); c.Close() }) }
	defer shut()

	go func() { // UDP replies -> TCP frames
		defer shut()
		buf := make([]byte, bufsz)
		for {
			n, addr, err := u.ReadFromUDP(buf)
			if err != nil {
				return
			}
			if _, err := c.Write(packFrame(addr.IP, addr.Port, buf[:n])); err != nil {
				return
			}
		}
	}()

	for { // TCP frames -> real UDP sendto
		ip, port, data, err := readFrame(c)
		if err != nil {
			return
		}
		// A single unroutable destination must not kill the mux: every UDP
		// flow on this client shares this one stream.
		_, _ = u.WriteToUDP(data, &net.UDPAddr{IP: ip, Port: port})
	}
}

// ICMP echo over an unprivileged ping socket: SOCK_DGRAM + IPPROTO_ICMP, which
// needs no CAP_NET_RAW as long as the box leaves net.ipv4.ping_group_range
// open -- Android does. The kernel rewrites the echo id to the socket's own;
// seq survives, and seq is what the local side keys replies on.
//
// Built by hand rather than with net.ListenPacket, which would give a RAW
// socket here and fail without the capability. FilePacketConn then hands the
// fd to the runtime poller, so this behaves like any other Go socket.
func icmpPacketConn() (net.PacketConn, error) {
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_DGRAM, syscall.IPPROTO_ICMP)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), "icmp")
	defer f.Close() // FilePacketConn dups; this closes only our copy.
	return net.FilePacketConn(f)
}

func icmpMux(c net.Conn) {
	u, err := icmpPacketConn()
	if err != nil {
		fmt.Println("icmp socket failed:", err)
		c.Close()
		return
	}
	var once sync.Once
	shut := func() { once.Do(func() { u.Close(); c.Close() }) }
	defer shut()

	go func() {
		defer shut()
		buf := make([]byte, bufsz)
		for {
			n, addr, err := u.ReadFrom(buf)
			if err != nil {
				return
			}
			ip := net.IPv4zero
			if a, ok := addr.(*net.UDPAddr); ok {
				ip = a.IP
			}
			if _, err := c.Write(packFrame(ip, 0, buf[:n])); err != nil {
				return
			}
		}
	}()

	for {
		ip, _, data, err := readFrame(c)
		if err != nil {
			return
		}
		_, _ = u.WriteTo(data, &net.UDPAddr{IP: ip, Port: 0})
	}
}

// Close both ends as soon as either direction ends: a half-open relay here
// would leak a goroutine and an fd per connection for the 300s the Python
// version spent in select().
func pipe(a, b net.Conn) {
	var once sync.Once
	shut := func() { once.Do(func() { a.Close(); b.Close() }) }
	go func() { defer shut(); io.Copy(a, b) }()
	defer shut()
	io.Copy(b, a)
}

func reply(c net.Conn, code byte) {
	c.Write(append([]byte{5, code, 0, 1}, make([]byte, 6)...))
}

func handle(c net.Conn) {
	defer c.Close()
	c.SetDeadline(time.Now().Add(30 * time.Second))

	var hdr [2]byte
	if _, err := io.ReadFull(c, hdr[:]); err != nil || hdr[0] != 5 {
		return
	}
	if _, err := io.ReadFull(c, make([]byte, int(hdr[1]))); err != nil {
		return
	}
	if _, err := c.Write([]byte{5, 0}); err != nil {
		return
	}

	var req [4]byte
	if _, err := io.ReadFull(c, req[:]); err != nil {
		return
	}
	var host string
	switch req[3] {
	case 1:
		a := make([]byte, 4)
		if _, err := io.ReadFull(c, a); err != nil {
			return
		}
		host = net.IP(a).String()
	case 3:
		var l [1]byte
		if _, err := io.ReadFull(c, l[:]); err != nil {
			return
		}
		a := make([]byte, int(l[0]))
		if _, err := io.ReadFull(c, a); err != nil {
			return
		}
		host = string(a)
	case 4:
		a := make([]byte, 16)
		if _, err := io.ReadFull(c, a); err != nil {
			return
		}
		host = net.IP(a).String()
	default:
		reply(c, 8)
		return
	}
	var pb [2]byte
	if _, err := io.ReadFull(c, pb[:]); err != nil {
		return
	}
	port := int(binary.BigEndian.Uint16(pb[:]))

	if req[1] != 1 { // CONNECT only
		reply(c, 7)
		return
	}

	// The mux targets are answered before any dial: they name a mode, not a
	// destination, and .arpa guarantees they can never resolve to a real host.
	if port == muxPort && (host == muxHost || host == icmpHost) {
		reply(c, 0)
		c.SetDeadline(time.Time{})
		if host == muxHost {
			udpMux(c)
		} else {
			icmpMux(c)
		}
		return
	}

	r, err := net.DialTimeout("tcp", net.JoinHostPort(host, strconv.Itoa(port)), 15*time.Second)
	if err != nil {
		reply(c, 5)
		return
	}
	reply(c, 0)
	c.SetDeadline(time.Time{})
	for _, s := range []net.Conn{c, r} {
		if t, ok := s.(*net.TCPConn); ok {
			t.SetNoDelay(true)
		}
	}
	pipe(c, r)
}

func main() {
	// Preflight. The caller has to know whether this gateway can execute the
	// binary at all -- a noexec /tmp, or the wrong architecture, both fail
	// here -- and it cannot learn that by starting the real thing, which would
	// bind the port and never return.
	if len(os.Args) > 1 && os.Args[1] == "-check" {
		fmt.Println("gtrelay ok")
		return
	}

	port := os.Getenv("RSOCKS_PORT")
	if port == "" {
		port = "1080"
	}
	addr := net.JoinHostPort("127.0.0.1", port)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		fmt.Println("listen failed:", err)
		os.Exit(1)
	}
	// First line of the log: the caller greps it back over ssh to decide
	// whether the relay really came up, so it must be printed before the
	// accept loop and must not be buffered away.
	fmt.Printf("gtrelay listening on %s pid=%d (tcp+udp+icmp)\n", addr, os.Getpid())
	for {
		c, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			fmt.Println("accept:", err)
			time.Sleep(50 * time.Millisecond)
			continue
		}
		go handle(c)
	}
}
