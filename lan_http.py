#!/usr/bin/env python3
"""Minimal plain-HTTP server for testing ShellyForever's tcp / take / give.

Runs on all interfaces (0.0.0.0) so the OS can reach it over your LAN.

Routes:
  GET  /            -> small directory listing
  GET  /big.txt     -> a ~8 KB payload (tests multi-segment TCP receive)
  GET  /100k.bin    -> a ~100 KB binary payload (tests take + chaining)
  GET  /<file>      -> serves any file that exists in this folder
  POST /upload      -> accepts an HTTP/1.0 body and reports its size/checksum

No TLS, HTTP/1.0 semantics (Connection: close) - matches what the kernel
implements. Windows firewall may prompt; allow it on private networks.
"""
import hashlib
import os
import socket

ROOT = os.path.dirname(os.path.abspath(__file__))
BIG_TEXT = ("ShellyForever test payload line. " * 300) + "\n"


def send_resp(conn, status, content, ctype="text/plain; charset=utf-8"):
    body = content if isinstance(content, bytes) else content.encode()
    head = (
        "HTTP/1.0 %s\r\n"
        "Server: lan_http/1.0\r\n"
        "Content-Type: %s\r\n"
        "Content-Length: %d\r\n"
        "Connection: close\r\n"
        "\r\n"
    ) % (status, ctype, len(body))
    conn.sendall(head.encode() + body)


def recv_request(conn):
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = conn.recv(4096)
        if not chunk:
            break
        data += chunk
    head, _, rest = data.partition(b"\r\n\r\n")
    lines = head.split(b"\r\n")
    request_line = lines[0].decode(errors="replace").split()
    method, path = request_line[0], request_line[1]
    clen = 0
    for line in lines[1:]:
        if line.lower().startswith(b"content-length:"):
            clen = int(line.split(b":", 1)[1].strip())
    body = rest
    while len(body) < clen:
        chunk = conn.recv(4096)
        if not chunk:
            break
        body += chunk
    return method, path, body[:clen]


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", 8000))
    srv.listen(4)
    print("lan_http listening on http://0.0.0.0:8000 (Ctrl+C to stop)")
    try:
        while True:
            conn, addr = srv.accept()
            try:
                method, path, body = recv_request(conn)
                print("req %s %s from %s" % (method, path, addr[0]))
                if method == "POST" and path.rstrip("/").endswith("/upload"):
                    digest = hashlib.md5(body).hexdigest()
                    send_resp(conn, "200 OK",
                              "received %d bytes, md5=%s\n" % (len(body), digest))
                elif path == "/big.txt":
                    send_resp(conn, "200 OK", BIG_TEXT)
                elif path == "/100k.bin":
                    payload = bytes(range(256)) * 400  # 102400 bytes
                    send_resp(conn, "200 OK", payload, "application/octet-stream")
                elif path == "/":
                    items = sorted(os.listdir(ROOT))
                    listing = "<!DOCTYPE html><title>lan_http</title><ul>"
                    listing += "".join("<li>%s</li>" % i for i in items)
                    listing += "</ul>\n"
                    send_resp(conn, "200 OK", listing, "text/html; charset=utf-8")
                else:
                    fp = os.path.join(ROOT, path.lstrip("/"))
                    if os.path.isfile(fp):
                        with open(fp, "rb") as f:
                            send_resp(conn, "200 OK", f.read())
                    else:
                        send_resp(conn, "404 Not Found", "no such file\n")
            except Exception as e:
                print("error: %s" % e)
            finally:
                conn.close()
    except KeyboardInterrupt:
        print("\nstopped")
    finally:
        srv.close()


if __name__ == "__main__":
    main()
