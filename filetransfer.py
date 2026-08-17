from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import os
import socket

HOST = "0.0.0.0"
PORT = 8080
UPLOAD_DIR = "files"

os.makedirs(UPLOAD_DIR, exist_ok=True)

class Handler(BaseHTTPRequestHandler):

    def do_GET(self):
        filename = self.path.lstrip("/")

        if not filename:
            self.send_response(400)
            self.end_headers()
            return

        filepath = os.path.join(UPLOAD_DIR, filename)

        if not os.path.isfile(filepath):
            self.send_response(404)
            self.end_headers()
            return

        with open(filepath, "rb") as f:
            data = f.read()

        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        filename = self.path.lstrip("/")

        if not filename:
            self.send_response(400)
            self.end_headers()
            return

        length = int(self.headers.get("Content-Length", 0))
        data = self.rfile.read(length)

        filepath = os.path.join(UPLOAD_DIR, filename)

        with open(filepath, "wb") as f:
            f.write(data)

        print(f"Received {filename} ({len(data)} bytes)")

        self.send_response(200)
        self.end_headers()

print(f"Server running on port {PORT}")
ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()