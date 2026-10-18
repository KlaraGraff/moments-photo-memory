"""Read-only local demo server. Never serves source or personal input folders."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit
import argparse

ROOT = Path(__file__).resolve().parents[1] / 'dist'
ROUTES = {'/':'index.html', '/index.html':'index.html', '/map.html':'map.html',
          '/docs/design-notes.html':'docs/design-notes.html'}

def serve(port):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_GET(self):
            relative = ROUTES.get(urlsplit(self.path).path)
            target = ROOT/relative if relative else None
            if not target or not target.is_file():self.send_error(404);return
            data=target.read_bytes();self.send_response(200)
            self.send_header('Content-Type','text/html; charset=utf-8')
            self.send_header('Content-Length',str(len(data)))
            self.send_header('Cache-Control','no-store')
            self.send_header('Referrer-Policy','strict-origin-when-cross-origin')
            self.send_header('X-Content-Type-Options','nosniff')
            self.end_headers();self.wfile.write(data)
    server=ThreadingHTTPServer(('127.0.0.1',port),Handler)
    print(f'Local preview: http://127.0.0.1:{port}',flush=True)
    try:server.serve_forever()
    except KeyboardInterrupt:pass
    finally:server.server_close()

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--port',type=int,default=8767)
    serve(parser.parse_args().port)
