package main

import (
	"flag"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/local/youtube-proxy/internal/certs"
	dnssrv "github.com/local/youtube-proxy/internal/dns"
	"github.com/local/youtube-proxy/internal/filter"
	"github.com/local/youtube-proxy/internal/proxy"
	"gopkg.in/yaml.v3"
)

// Config mirrors config.yaml structure.
type Config struct {
	DNS struct {
		Listen         string   `yaml:"listen"`
		Upstream       string   `yaml:"upstream"`
		InterceptHosts []string `yaml:"intercept_hosts"`
		InterceptIP    string   `yaml:"intercept_ip"`
		Blocklists     []struct {
			Path    string `yaml:"path"`
			Comment string `yaml:"comment"`
		} `yaml:"blocklists"`
		BlocklistURLs []string `yaml:"blocklist_urls"`
	} `yaml:"dns"`

	Proxy struct {
		Listen            string   `yaml:"listen"`
		CACert            string   `yaml:"ca_cert"`
		CAKey             string   `yaml:"ca_key"`
		ServerCert        string   `yaml:"server_cert"`
		ServerKey         string   `yaml:"server_key"`
		UpstreamHost      string   `yaml:"upstream_host"`
		UpstreamAllowlist []string `yaml:"upstream_allowlist"`
		ServerIPs         []string `yaml:"server_ips"`
	} `yaml:"proxy"`

	Filter struct {
		Endpoints []struct {
			Path       string   `yaml:"path"`
			RemoveKeys []string `yaml:"remove_keys"`
		} `yaml:"endpoints"`
	} `yaml:"filter"`

	CAServer struct {
		Listen   string `yaml:"listen"`
		CertPath string `yaml:"cert_path"`
	} `yaml:"ca_server"`
}

func main() {
	configPath := flag.String("config", "config.yaml", "Path to config file")
	flag.Parse()

	cfg, err := loadConfig(*configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to load config: %v\n", err)
		os.Exit(1)
	}

	// 1. Load / generate certificates
	var serverIPs []net.IP
	for _, s := range cfg.Proxy.ServerIPs {
		if ip := net.ParseIP(s); ip != nil {
			serverIPs = append(serverIPs, ip)
		}
	}
	certMgr, err := certs.Load(cfg.Proxy.CACert, cfg.Proxy.CAKey, cfg.Proxy.ServerCert, cfg.Proxy.ServerKey, serverIPs)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Certificate error: %v\n", err)
		os.Exit(1)
	}

	// 2. Build JSON filter
	var rules []filter.EndpointRule
	for _, ep := range cfg.Filter.Endpoints {
		keys := make(map[string]struct{}, len(ep.RemoveKeys))
		for _, k := range ep.RemoveKeys {
			keys[k] = struct{}{}
		}
		rules = append(rules, filter.EndpointRule{
			Path:       ep.Path,
			RemoveKeys: keys,
		})
	}
	f := filter.New(rules)

	// 3. Start DNS server
	var blocklistPaths []string
	for _, bl := range cfg.DNS.Blocklists {
		blocklistPaths = append(blocklistPaths, bl.Path)
	}

	_, err = dnssrv.New(dnssrv.Config{
		Listen:         cfg.DNS.Listen,
		Upstream:       cfg.DNS.Upstream,
		InterceptHosts: cfg.DNS.InterceptHosts,
		InterceptIP:    cfg.DNS.InterceptIP,
		BlocklistPaths: blocklistPaths,
		BlocklistURLs:  cfg.DNS.BlocklistURLs,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "DNS server error: %v\n", err)
		os.Exit(1)
	}

	// 4. Start HTTPS proxy
	_, err = proxy.New(proxy.Config{
		Listen:            cfg.Proxy.Listen,
		UpstreamHost:      cfg.Proxy.UpstreamHost,
		UpstreamAllowlist: cfg.Proxy.UpstreamAllowlist,
		TLSConfig:         certMgr.TLSConfig,
		Filter:            f,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "Proxy server error: %v\n", err)
		os.Exit(1)
	}

	// 5. Serve Root CA for easy download on devices
	go serveCA(cfg.CAServer.Listen, cfg.CAServer.CertPath)

	fmt.Println()
	fmt.Println("=== youtube-proxy started ===")
	fmt.Printf("  DNS:        %s\n", cfg.DNS.Listen)
	fmt.Printf("  HTTPS:      %s\n", cfg.Proxy.Listen)
	fmt.Printf("  CA download: http://<VPS2-IP>:%s/ca.crt\n", portFromAddr(cfg.CAServer.Listen))
	fmt.Println()
	fmt.Println("Install ca.crt on your devices:")
	fmt.Println("  iOS:     Settings → Profile Downloaded → Trust")
	fmt.Println("  Android: Settings → Security → Install certificate")
	fmt.Println("  Windows: Double-click ca.crt → Install → Trusted Root CAs")
	fmt.Println()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	fmt.Println("Shutting down...")
}

func serveCA(addr, certPath string) {
	mux := http.NewServeMux()
	mux.HandleFunc("/ca.crt", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/x-x509-ca-cert")
		w.Header().Set("Content-Disposition", "attachment; filename=youtube-proxy-ca.crt")
		http.ServeFile(w, r, certPath)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, `<html><body>
<h2>YouTube Proxy — Root CA</h2>
<p>Download and install the Root CA certificate on your devices:</p>
<a href="/ca.crt">Download ca.crt</a>
<hr>
<h3>Installation instructions:</h3>
<ul>
<li><b>iOS:</b> Open the link on your iPhone → Settings → Profile Downloaded → Install → Trust</li>
<li><b>Android:</b> Download → Settings → Security → Install certificate → CA certificate</li>
<li><b>Windows:</b> Download → double-click → Install → Place in Trusted Root CAs</li>
</ul>
</body></html>`)
	})
	fmt.Printf("[ca-server] Serving CA at http://%s/ca.crt\n", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		fmt.Printf("[ca-server] Error: %v\n", err)
	}
}

func loadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, err
	}
	return &cfg, nil
}

func portFromAddr(addr string) string {
	parts := splitLast(addr, ":")
	if len(parts) == 2 {
		return parts[1]
	}
	return addr
}

func splitLast(s, sep string) []string {
	idx := len(s) - len(sep)
	for i := len(s) - 1; i >= 0; i-- {
		if s[i:i+len(sep)] == sep {
			idx = i
			break
		}
	}
	return []string{s[:idx], s[idx+1:]}
}
