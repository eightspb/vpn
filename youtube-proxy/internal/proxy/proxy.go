package proxy

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/local/youtube-proxy/internal/filter"
	"golang.org/x/net/http2"
)

// Server is a TLS-terminating reverse proxy for youtubei.googleapis.com.
type Server struct {
	listenAddr   string
	upstreamHost string
	upstreamAL   map[string]struct{}
	tlsConfig    *tls.Config
	filter       *filter.Filter
	upstream     *http.Client
}

// Config holds proxy server configuration.
type Config struct {
	Listen            string
	UpstreamHost      string
	UpstreamAllowlist []string
	TLSConfig         *tls.Config
	Filter            *filter.Filter
}

// New creates and starts the HTTPS proxy server.
func New(cfg Config) (*Server, error) {
	dialer := &net.Dialer{
		Timeout:   10 * time.Second,
		KeepAlive: 30 * time.Second,
	}
	resolver := &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			d := net.Dialer{Timeout: 5 * time.Second}
			return d.DialContext(ctx, "udp", "8.8.8.8:53")
		},
	}
	dialer.Resolver = resolver

	transport := &http.Transport{
		DialContext:           dialer.DialContext,
		TLSHandshakeTimeout:   5 * time.Second,
		ResponseHeaderTimeout: 15 * time.Second,
		IdleConnTimeout:       120 * time.Second,
		MaxIdleConns:          200,
		MaxIdleConnsPerHost:   50,
		DisableCompression:    false,
	}
	if err := http2.ConfigureTransport(transport); err != nil {
		fmt.Printf("[proxy] Warning: failed to enable HTTP/2 for upstream: %v\n", err)
	}
	upstreamAL := make(map[string]struct{})
	if normalized := normalizeHost(cfg.UpstreamHost); normalized != "" {
		upstreamAL[normalized] = struct{}{}
	}
	for _, host := range cfg.UpstreamAllowlist {
		if normalized := normalizeHost(host); normalized != "" {
			upstreamAL[normalized] = struct{}{}
		}
	}
	s := &Server{
		listenAddr:   cfg.Listen,
		upstreamHost: cfg.UpstreamHost,
		upstreamAL:   upstreamAL,
		tlsConfig:    cfg.TLSConfig,
		filter:       cfg.Filter,
		upstream: &http.Client{
			Transport: transport,
			// Don't follow redirects automatically
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}

	ln, err := tls.Listen("tcp", cfg.Listen, cfg.TLSConfig)
	if err != nil {
		return nil, fmt.Errorf("listen %s: %w", cfg.Listen, err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handle)

	srv := &http.Server{
		Handler:           mux,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    1 << 20,
		ReadHeaderTimeout: 5 * time.Second,
		// TLSNextProto empty — disable HTTP/2, not needed for proxy
		TLSNextProto: make(map[string]func(*http.Server, *tls.Conn, http.Handler)),
		ConnState: func(conn net.Conn, state http.ConnState) {
			if state == http.StateNew {
				conn.SetDeadline(time.Now().Add(15 * time.Second))
			} else if state == http.StateActive {
				conn.SetDeadline(time.Time{})
			}
		},
	}

	go func() {
		fmt.Printf("[proxy] Listening on %s (upstream: %s)\n", cfg.Listen, cfg.UpstreamHost)
		if err := srv.Serve(ln); err != nil {
			fmt.Printf("[proxy] Server error: %v\n", err)
		}
	}()

	return s, nil
}

func (s *Server) handle(w http.ResponseWriter, r *http.Request) {
	targetHost := s.upstreamHost
	requestedHost := normalizeHost(r.Host)
	if requestedHost != "" {
		if _, ok := s.upstreamAL[requestedHost]; ok {
			targetHost = requestedHost
		} else {
			fmt.Printf("[proxy] Blocked upstream host from request Host=%q, fallback to %s\n", r.Host, s.upstreamHost)
		}
	}

	upstreamURL := fmt.Sprintf("https://%s%s", targetHost, r.RequestURI)

	upReq, err := http.NewRequestWithContext(r.Context(), r.Method, upstreamURL, r.Body)
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	// Copy headers, fix Host
	copyHeaders(upReq.Header, r.Header)
	upstreamHostHeader := normalizeHost(targetHost)
	if upstreamHostHeader == "" {
		upstreamHostHeader = normalizeHost(s.upstreamHost)
	}
	upReq.Host = upstreamHostHeader
	upReq.Header.Set("Host", upstreamHostHeader)

	// Don't ask for compressed response if we need to filter — simplifies decompression
	if s.filter.ShouldFilter(r.URL.Path) {
		upReq.Header.Del("Accept-Encoding")
	}

	resp, err := s.upstream.Do(upReq)
	if err != nil {
		errStr := err.Error()
		if strings.Contains(errStr, "tls") || strings.Contains(errStr, "certificate") || strings.Contains(errStr, "x509") {
			fmt.Printf("[proxy] TLS/cert error for %s %s: %v\n", r.Method, r.URL.Path, err)
		} else {
			fmt.Printf("[proxy] Upstream error for %s %s: %v\n", r.Method, r.URL.Path, err)
		}
		http.Error(w, "upstream error", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	// Non-filtered path: stream response without reading into memory
	if !s.filter.ShouldFilter(r.URL.Path) {
		copyHeaders(w.Header(), resp.Header)
		w.WriteHeader(resp.StatusCode)
		if _, err := io.Copy(w, resp.Body); err != nil {
			fmt.Printf("[proxy] Stream write error for %s: %v\n", r.URL.Path, err)
		}
		return
	}

	// Filtered path: read full body for filtering
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, "read error", http.StatusBadGateway)
		return
	}

	// Decompress gzip if needed before filtering
	contentEncoding := resp.Header.Get("Content-Encoding")
	if contentEncoding == "gzip" {
		gr, err := gzip.NewReader(bytes.NewReader(body))
		if err == nil {
			decompressed, err := io.ReadAll(gr)
			gr.Close()
			if err == nil {
				body = decompressed
				resp.Header.Del("Content-Encoding")
			}
		}
	}

	// Apply ad filter
	originalLen := len(body)
	body = s.filter.Apply(r.URL.Path, body)
	if len(body) != originalLen {
		fmt.Printf("[proxy] Filtered %s: %d → %d bytes\n", r.URL.Path, originalLen, len(body))
	}

	// Write response
	copyHeaders(w.Header(), resp.Header)
	w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
	w.WriteHeader(resp.StatusCode)
	w.Write(body)
}

func copyHeaders(dst, src http.Header) {
	for k, vv := range src {
		// Skip hop-by-hop headers
		switch strings.ToLower(k) {
		case "connection", "keep-alive", "proxy-authenticate",
			"proxy-authorization", "te", "trailers", "transfer-encoding", "upgrade":
			continue
		}
		for _, v := range vv {
			dst.Add(k, v)
		}
	}
}

func normalizeHost(host string) string {
	host = strings.TrimSpace(strings.ToLower(host))
	if host == "" {
		return ""
	}
	if parsedHost, _, err := net.SplitHostPort(host); err == nil {
		host = parsedHost
	} else if strings.Count(host, ":") == 1 {
		if idx := strings.LastIndex(host, ":"); idx > 0 {
			host = host[:idx]
		}
	}
	return strings.TrimSuffix(host, ".")
}
