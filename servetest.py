"""
servetest.py - minimal HTTP test server for ShellyForever's `take`/`give`
commands. Written to run as-is in Pydroid3 on Android - just open this
file in Pydroid3 and hit the Run (play) button.

GET  /anything   -> replies with a small text body (for `take`)
POST /anything   -> reads and prints whatever body was sent (for `give`)

No third-party packages needed - only the Python standard library, which
Pydroid3 ships with by default.
"""

import socket
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 8000


def local_ip():
    """Best-effort guess at this phone's LAN IP address, so you don't have
    to go dig it out of Android's WiFi settings by hand."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        # doesn't actually send anything - just makes the OS pick a route,
        # which tells us which local interface/IP it would use
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
    except OSError:
        ip = "127.0.0.1"
    finally:
        s.close()
    return ip


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"hello from the phone\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        data = self.rfile.read(length)
        print(f"--- got POST {self.path}, {length} bytes ---")
        print(data.decode(errors="replace"))
        print("---")
        body = b"thanks, got it\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        # the default logging is fine, this just keeps it on one line
        print("[request] " + (fmt % args))


if __name__ == "__main__":
    ip = local_ip()
    print("=" * 50)
    print(f"  Point ShellyForever at:  http://{ip}:{PORT}/")
    print(f"  e.g.  take http://{ip}:{PORT}/notes.txt got.txt")
    print(f"        give http://{ip}:{PORT}/upload got.txt")
    print("=" * 50)
    print("Make sure the phone is on the SAME WiFi network as the machine")
    print("running ShellyForever (not on mobile data), or the IP above")
    print("won't be reachable from it.")
    print()
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
