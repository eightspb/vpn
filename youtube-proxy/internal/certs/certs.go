package certs

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"time"
)

// Manager handles CA and server certificate lifecycle.
type Manager struct {
	CACert     *x509.Certificate
	CAKey      *ecdsa.PrivateKey
	TLSConfig  *tls.Config
	caCertPath string
	caKeyPath  string
}

// Load loads or generates CA and server certificates.
func Load(caCertPath, caKeyPath, serverCertPath, serverKeyPath string) (*Manager, error) {
	if err := os.MkdirAll(filepath.Dir(caCertPath), 0755); err != nil {
		return nil, err
	}

	m := &Manager{caCertPath: caCertPath, caKeyPath: caKeyPath}

	if _, err := os.Stat(caCertPath); os.IsNotExist(err) {
		fmt.Println("[certs] Root CA not found, generating...")
		if err := m.generateCA(caCertPath, caKeyPath); err != nil {
			return nil, fmt.Errorf("generate CA: %w", err)
		}
		fmt.Printf("[certs] Root CA generated: %s\n", caCertPath)
		fmt.Println("[certs] Install ca.crt on your devices to trust the proxy.")
	}

	if err := m.loadCA(caCertPath, caKeyPath); err != nil {
		return nil, fmt.Errorf("load CA: %w", err)
	}

	if _, err := os.Stat(serverCertPath); os.IsNotExist(err) {
		if err := m.generateServerCert(serverCertPath, serverKeyPath); err != nil {
			return nil, fmt.Errorf("generate server cert: %w", err)
		}
	}

	cert, err := tls.LoadX509KeyPair(serverCertPath, serverKeyPath)
	if err != nil {
		return nil, fmt.Errorf("load server cert: %w", err)
	}

	m.TLSConfig = &tls.Config{
		Certificates: []tls.Certificate{cert},
		MinVersion:   tls.VersionTLS12,
	}

	return m, nil
}

func (m *Manager) generateCA(certPath, keyPath string) error {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}

	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			CommonName:   "YouTube Proxy Root CA",
			Organization: []string{"YouTube Proxy"},
		},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(10 * 365 * 24 * time.Hour),
		IsCA:                  true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
		BasicConstraintsValid: true,
	}

	certDER, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		return err
	}

	if err := writePEM(certPath, "CERTIFICATE", certDER); err != nil {
		return err
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return err
	}
	return writePEM(keyPath, "EC PRIVATE KEY", keyDER)
}

func (m *Manager) loadCA(certPath, keyPath string) error {
	certPEM, err := os.ReadFile(certPath)
	if err != nil {
		return err
	}
	keyPEM, err := os.ReadFile(keyPath)
	if err != nil {
		return err
	}

	block, _ := pem.Decode(certPEM)
	cert, err := x509.ParseCertificate(block.Bytes)
	if err != nil {
		return err
	}

	block, _ = pem.Decode(keyPEM)
	key, err := x509.ParseECPrivateKey(block.Bytes)
	if err != nil {
		return err
	}

	m.CACert = cert
	m.CAKey = key
	return nil
}

func (m *Manager) generateServerCert(certPath, keyPath string) error {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}

	template := &x509.Certificate{
		SerialNumber: big.NewInt(2),
		Subject: pkix.Name{
			CommonName: "youtubei.googleapis.com",
		},
		DNSNames: []string{
			"youtubei.googleapis.com",
			"*.googleapis.com",
			"*.youtube.com",
			"www.youtube.com",
		},
		NotBefore: time.Now().Add(-time.Hour),
		NotAfter:  time.Now().Add(5 * 365 * 24 * time.Hour),
		KeyUsage:  x509.KeyUsageDigitalSignature,
		ExtKeyUsage: []x509.ExtKeyUsage{
			x509.ExtKeyUsageServerAuth,
		},
	}

	certDER, err := x509.CreateCertificate(rand.Reader, template, m.CACert, &key.PublicKey, m.CAKey)
	if err != nil {
		return err
	}

	if err := writePEM(certPath, "CERTIFICATE", certDER); err != nil {
		return err
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		return err
	}
	return writePEM(keyPath, "EC PRIVATE KEY", keyDER)
}

func writePEM(path, pemType string, data []byte) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return pem.Encode(f, &pem.Block{Type: pemType, Bytes: data})
}
