package proxy

import (
	"bytes"
	"compress/gzip"
	"crypto/tls"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/local/youtube-proxy/internal/filter"
)

// Server is a TLS-terminating reverse proxy for youtubei.googleapis.com.
type Server struct {
	listenAddr   string
	upstreamHost string
	tlsConfig    *tls.Config
	filter       *filter.Filter
	upstream     *http.Client
}

// Config holds proxy server configuration.
type Config struct {
	Listen       string
	UpstreamHost string
	TLSConfig    *tls.Config
	Filter       *filter.Filter
}

// New creates and starts the HTTPS proxy server.
func New(cfg Config) (*Server, error) {
	s := &Server{
		listenAddr:   cfg.Listen,
		upstreamHost: cfg.UpstreamHost,
		tlsConfig:    cfg.TLSConfig,
		filter:       cfg.Filter,
		upstream: &http.Client{
			Transport: &http.Transport{
				TLSClientConfig: &tls.Config{
					ServerName: strings.Split(cfg.UpstreamHost, ":")[0],
				},
				DialContext: (&net.Dialer{
					Timeout:   10 * time.Second,
					KeepAlive: 30 * time.Second,
				}).DialContext,
				TLSHandshakeTimeout:   10 * time.Second,
				ResponseHeaderTimeout: 30 * time.Second,
				IdleConnTimeout:       90 * time.Second,
			},
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
		Handler:      mux,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 60 * time.Second,
		IdleTimeout:  120 * time.Second,
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
	upstreamURL := fmt.Sprintf("https://%s%s", s.upstreamHost, r.RequestURI)

	upReq, err := http.NewRequestWithContext(r.Context(), r.Method, upstreamURL, r.Body)
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}

	// Copy headers, fix Host
	copyHeaders(upReq.Header, r.Header)
	upReq.Header.Set("Host", strings.Split(s.upstreamHost, ":")[0])

	// Don't ask for compressed response if we need to filter — simplifies decompression
	if s.filter.ShouldFilter(r.URL.Path) {
		upReq.Header.Del("Accept-Encoding")
	}

	resp, err := s.upstream.Do(upReq)
	if err != nil {
		http.Error(w, "upstream error", http.StatusBadGateway)
		fmt.Printf("[proxy] Upstream error for %s: %v\n", r.URL.Path, err)
		return
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, "read error", http.StatusBadGateway)
		return
	}

	// Decompress gzip if needed before filtering
	contentEncoding := resp.Header.Get("Content-Encoding")
	if contentEncoding == "gzip" && s.filter.ShouldFilter(r.URL.Path) {
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
	if s.filter.ShouldFilter(r.URL.Path) {
		originalLen := len(body)
		body = s.filter.Apply(r.URL.Path, body)
		if len(body) != originalLen {
			fmt.Printf("[proxy] Filtered %s: %d → %d bytes\n", r.URL.Path, originalLen, len(body))
		}
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
