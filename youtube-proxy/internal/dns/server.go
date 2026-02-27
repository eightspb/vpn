package dns

import (
	"bufio"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/miekg/dns"
)

// Cache entry for DNS responses with TTL-based expiry.
type cacheEntry struct {
	msg   *dns.Msg
	until time.Time
}

// Server is a DNS server that blocks ad/tracking domains and
// intercepts configured hostnames (redirecting them to 127.0.0.1).
type Server struct {
	upstream       string
	interceptHosts map[string]struct{}
	interceptIP    string
	blockedDomains map[string]struct{}
	mu             sync.RWMutex
	blocklistPaths []string
	blocklistURLs  []string
	// TTL-based cache for upstream responses
	cache      map[string]*cacheEntry
	cacheMu    sync.RWMutex
	maxCacheTTL time.Duration
	minCacheTTL time.Duration
}

// Config holds DNS server configuration.
type Config struct {
	Listen         string
	Upstream       string
	InterceptHosts []string
	InterceptIP    string
	BlocklistPaths []string
	BlocklistURLs  []string
	// MaxCacheTTL is the maximum time to cache upstream responses (default 15m).
	MaxCacheTTL time.Duration
	// MinCacheTTL is the minimum TTL used when upstream doesn't provide one (default 120s).
	MinCacheTTL time.Duration
}

// New creates and starts a DNS server.
func New(cfg Config) (*Server, error) {
	ip := cfg.InterceptIP
	if ip == "" {
		ip = "127.0.0.1"
	}

	maxTTL := cfg.MaxCacheTTL
	if maxTTL <= 0 {
		maxTTL = 15 * time.Minute
	}
	minTTL := cfg.MinCacheTTL
	if minTTL <= 0 {
		minTTL = 120 * time.Second
	}
	s := &Server{
		upstream:       cfg.Upstream,
		interceptHosts: make(map[string]struct{}),
		interceptIP:    ip,
		blockedDomains: make(map[string]struct{}),
		blocklistPaths: cfg.BlocklistPaths,
		blocklistURLs:  cfg.BlocklistURLs,
		cache:          make(map[string]*cacheEntry),
		maxCacheTTL:    maxTTL,
		minCacheTTL:    minTTL,
	}

	for _, h := range cfg.InterceptHosts {
		s.interceptHosts[dns.Fqdn(h)] = struct{}{}
	}

	if err := s.loadBlocklists(); err != nil {
		fmt.Printf("[dns] Warning: failed to load some blocklists: %v\n", err)
	}

	go s.scheduleBlocklistUpdate()

	mux := dns.NewServeMux()
	mux.HandleFunc(".", s.handle)

	udpServer := &dns.Server{Addr: cfg.Listen, Net: "udp", Handler: mux}
	tcpServer := &dns.Server{Addr: cfg.Listen, Net: "tcp", Handler: mux}

	go func() {
		if err := udpServer.ListenAndServe(); err != nil {
			fmt.Printf("[dns] UDP server error: %v\n", err)
		}
	}()
	go func() {
		if err := tcpServer.ListenAndServe(); err != nil {
			fmt.Printf("[dns] TCP server error: %v\n", err)
		}
	}()

	fmt.Printf("[dns] Listening on %s (upstream: %s)\n", cfg.Listen, cfg.Upstream)
	fmt.Printf("[dns] Intercepting: %v\n", cfg.InterceptHosts)
	fmt.Printf("[dns] Blocked domains loaded: %d\n", len(s.blockedDomains))

	return s, nil
}

func (s *Server) handle(w dns.ResponseWriter, r *dns.Msg) {
	m := new(dns.Msg)
	m.SetReply(r)
	m.Authoritative = false

	for _, q := range r.Question {
		if q.Qtype != dns.TypeA && q.Qtype != dns.TypeAAAA {
			continue
		}

		name := strings.ToLower(q.Name)

		// Intercept: redirect to our proxy IP so our HTTPS proxy handles it
		if _, ok := s.interceptHosts[name]; ok {
			if q.Qtype == dns.TypeA {
				m.Answer = append(m.Answer, &dns.A{
					Hdr: dns.RR_Header{
						Name:   q.Name,
						Rrtype: dns.TypeA,
						Class:  dns.ClassINET,
						Ttl:    60,
					},
					A: net.ParseIP(s.interceptIP),
				})
			}
			w.WriteMsg(m)
			return
		}

		// Block: return NXDOMAIN
		if s.isBlocked(name) {
			m.SetRcode(r, dns.RcodeNameError)
			w.WriteMsg(m)
			return
		}
	}

	// Cache key: question name + type
	cacheKey := ""
	for _, q := range r.Question {
		cacheKey += q.Name + " " + dns.TypeToString[q.Qtype] + " "
	}
	if cacheKey != "" {
		s.cacheMu.RLock()
		ent := s.cache[cacheKey]
		s.cacheMu.RUnlock()
		if ent != nil && time.Now().Before(ent.until) {
			out := ent.msg.Copy()
			out.Id = r.Id
			w.WriteMsg(out)
			return
		}
	}

	// Forward to upstream
	c := new(dns.Client)
	c.Timeout = 3 * time.Second
	resp, _, err := c.Exchange(r, s.upstream)
	if err != nil {
		m.SetRcode(r, dns.RcodeServerFailure)
		w.WriteMsg(m)
		return
	}

	// Store in cache with TTL from response (min of RR TTLs), clamped to [minCacheTTL, maxCacheTTL]
	if cacheKey != "" && len(resp.Answer) > 0 {
		ttl := s.maxCacheTTL
		for _, rr := range resp.Answer {
			if h := rr.Header(); h.Ttl > 0 {
				rttl := time.Duration(h.Ttl) * time.Second
				if rttl < ttl {
					ttl = rttl
				}
			}
		}
		if ttl < s.minCacheTTL {
			ttl = s.minCacheTTL
		}
		if ttl > s.maxCacheTTL {
			ttl = s.maxCacheTTL
		}
		s.cacheMu.Lock()
		if len(s.cache) >= 50000 {
			now := time.Now()
			for k, v := range s.cache {
				if now.After(v.until) {
					delete(s.cache, k)
				}
			}
			if len(s.cache) >= 50000 {
				s.cache = make(map[string]*cacheEntry)
			}
		}
		s.cache[cacheKey] = &cacheEntry{msg: resp.Copy(), until: time.Now().Add(ttl)}
		s.cacheMu.Unlock()
	}

	w.WriteMsg(resp)
}

func (s *Server) isBlocked(name string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()

	// Check exact match and parent domains
	parts := strings.Split(strings.TrimSuffix(name, "."), ".")
	for i := range parts {
		candidate := strings.Join(parts[i:], ".") + "."
		if _, ok := s.blockedDomains[candidate]; ok {
			return true
		}
	}
	return false
}

func (s *Server) loadBlocklists() error {
	domains := make(map[string]struct{})

	for _, path := range s.blocklistPaths {
		if err := loadFromFile(path, domains); err != nil {
			fmt.Printf("[dns] Skipping blocklist %s: %v\n", path, err)
		}
	}

	for _, url := range s.blocklistURLs {
		if err := loadFromURL(url, domains); err != nil {
			fmt.Printf("[dns] Skipping blocklist URL %s: %v\n", url, err)
		}
	}

	s.mu.Lock()
	s.blockedDomains = domains
	s.mu.Unlock()

	fmt.Printf("[dns] Blocklists reloaded: %d domains\n", len(domains))
	return nil
}

func (s *Server) scheduleBlocklistUpdate() {
	ticker := time.NewTicker(24 * time.Hour)
	for range ticker.C {
		if err := s.loadBlocklists(); err != nil {
			fmt.Printf("[dns] Blocklist update failed: %v\n", err)
		}
	}
}

func loadFromFile(path string, out map[string]struct{}) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return parseHostsFormat(f, out)
}

func loadFromURL(url string, out map[string]struct{}) error {
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return parseHostsFormat(resp.Body, out)
}

// parseHostsFormat parses hosts-file and AdGuard filter list formats.
// Supports:
//   - "0.0.0.0 domain.com" (hosts format)
//   - "127.0.0.1 domain.com" (hosts format)
//   - "||domain.com^" (AdGuard/uBlock format)
//   - "domain.com" (plain list)
func parseHostsFormat(r io.Reader, out map[string]struct{}) error {
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, "!") {
			continue
		}

		var domain string

		switch {
		case strings.HasPrefix(line, "||") && strings.HasSuffix(line, "^"):
			// AdGuard format: ||domain.com^
			domain = line[2 : len(line)-1]
		case strings.HasPrefix(line, "0.0.0.0 ") || strings.HasPrefix(line, "127.0.0.1 "):
			// Hosts format
			parts := strings.Fields(line)
			if len(parts) >= 2 {
				domain = parts[1]
			}
		default:
			// Plain domain
			if !strings.Contains(line, " ") && strings.Contains(line, ".") {
				domain = line
			}
		}

		if domain != "" && !strings.Contains(domain, "/") {
			out[dns.Fqdn(strings.ToLower(domain))] = struct{}{}
		}
	}
	return scanner.Err()
}
