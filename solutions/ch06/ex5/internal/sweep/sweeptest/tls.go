// START head OMIT

package sweeptest

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"math/big"
	"net"
	"net/http/httptest"
	"testing"
	"time"
)

// END head OMIT

// START server OMIT
// NewTLSServer starts a Fleet over TLS with a self-signed certificate that
// expires at notAfter, and returns the server and a pool that trusts it.
// The server is closed when the test ends.
func NewTLSServer(t testing.TB, notAfter time.Time) (
	*httptest.Server, *x509.CertPool) {

	t.Helper()
	cert, leaf := selfSigned(t, notAfter)
	srv := httptest.NewUnstartedServer(NewFleet())
	srv.TLS = &tls.Config{Certificates: []tls.Certificate{cert}}
	srv.StartTLS()
	t.Cleanup(func() {
		srv.CloseClientConnections() // unblock any /slow handlers
		srv.Close()
	})
	roots := x509.NewCertPool()
	roots.AddCert(leaf)
	return srv, roots
}

// END server OMIT

// START cert OMIT
// selfSigned makes a certificate for the loopback addresses, valid from an
// hour ago until notAfter, signed by its own key.
func selfSigned(t testing.TB, notAfter time.Time) (
	tls.Certificate, *x509.Certificate) {

	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(time.Now().UnixNano()),
		Subject:               pkix.Name{CommonName: "fleet.test"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              notAfter,
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		IsCA:                  true, // it signs itself
		IPAddresses:           []net.IP{net.IPv4(127, 0, 0, 1), net.IPv6loopback},
		DNSNames:              []string{"localhost"},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	leaf, err := x509.ParseCertificate(der)
	if err != nil {
		t.Fatal(err)
	}
	cert := tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key, Leaf: leaf}
	return cert, leaf
}

// END cert OMIT
