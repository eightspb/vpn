import sys, os, json, subprocess, threading, re, platform
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

os.chdir(sys.argv[2] if len(sys.argv) > 2 else os.getcwd())

IS_WIN = platform.system() == 'Windows'

class VPNHandler(SimpleHTTPRequestHandler):
    def log_message(self, *a): pass

    def end_headers(self):
        if hasattr(self, '_no_cache') and self._no_cache:
            self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate')
            self.send_header('Pragma', 'no-cache')
        super().end_headers()

    def do_GET(self):
        p = urlparse(self.path)
        self._no_cache = p.path.endswith('/data.json') or p.path == '/data.json'
        if p.path == '/api/ping':
            self._handle_ping(parse_qs(p.query))
        else:
            super().do_GET()

    def _handle_ping(self, params):
        hosts = [h.strip() for h in params.get('hosts', [''])[0].split(',') if h.strip()]
        results = {}
        lock = threading.Lock()

        def do_ping(host):
            try:
                if IS_WIN:
                    cmd = ['ping', '-n', '3', '-w', '2000', host]
                else:
                    cmd = ['ping', '-c', '3', '-W', '2', host]
                pr = subprocess.run(cmd, capture_output=True, text=True, timeout=12)
                if IS_WIN:
                    ma = re.search(r'Average\s*=\s*(\d+)ms', pr.stdout)
                    ml = re.search(r'\((\d+)%\s+loss\)', pr.stdout)
                    if ma:
                        r = {'status': 'ok',
                             'avg_ms': round(float(ma.group(1)), 1),
                             'loss': int(ml.group(1)) if ml else 0}
                    else:
                        r = {'status': 'fail', 'avg_ms': None, 'loss': 100}
                else:
                    ma = re.search(r'rtt[^=]+=\s*[\d.]+/([\d.]+)/', pr.stdout)
                    ml = re.search(r'(\d+)%\s+packet loss', pr.stdout)
                    if ma:
                        r = {'status': 'ok',
                             'avg_ms': round(float(ma.group(1)), 1),
                             'loss': int(ml.group(1)) if ml else 0}
                    else:
                        r = {'status': 'fail', 'avg_ms': None, 'loss': 100}
            except subprocess.TimeoutExpired:
                r = {'status': 'timeout'}
            except Exception as e:
                r = {'status': 'error', 'msg': str(e)}
            with lock:
                results[host] = r

        threads = [threading.Thread(target=do_ping, args=(h,)) for h in hosts]
        for t in threads: t.start()
        for t in threads: t.join(timeout=15)

        body = json.dumps(results).encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
ThreadingHTTPServer(('127.0.0.1', port), VPNHandler).serve_forever()
