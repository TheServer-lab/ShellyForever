#!/usr/bin/env python3
"""Find a lan_http / Pydroid3 server on the LAN and probe it.

Usage:
  python scan_lan_http.py                 # scan 192.168.x.0/24 for :8000
  python scan_lan_http.py 192.168.29.0/24 # scan a specific subnet
  python scan_lan_http.py --ip 192.168.1.50  # just probe one host

Finds hosts with TCP :8000 open, then does a real HTTP/1.0 GET / request
to confirm it is lan_http (Pydroid3) rather than something else.
"""
import socket
import sys
import ipaddress
import threading
from concurrent.futures import ThreadPoolExecutor

PORT = 8000
TIMEOUT = 0.6


def probe_open(ip, port=PORT, timeout=TIMEOUT):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect((str(ip), port))
        return True
    except Exception:
        return False
    finally:
        s.close()


def http_probe(ip, port=PORT, timeout=3):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect((str(ip), port))
        s.sendall(b"GET / HTTP/1.0\r\nHost: test\r\n\r\n")
        data = b""
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
            if len(data) > 4096:
                break
        head = data.split(b"\r\n\r\n", 1)[0]
        status = head.split(b"\r\n", 1)[0].decode(errors="replace")
        server = "unknown"
        for line in head.split(b"\r\n"):
            if line.lower().startswith(b"server:"):
                server = line.split(b":", 1)[1].strip().decode(errors="replace")
        body = data.split(b"\r\n\r\n", 1)[1] if b"\r\n\r\n" in data else b""
        return status, server, len(data), body[:80]
    except Exception as e:
        return None, str(e), 0, b""
    finally:
        s.close()


def scan_network(network):
    hits = []
    lock = threading.Lock()
    hosts = [str(ip) for ip in ipaddress.ip_network(network, strict=False).hosts()]
    print("checking %d hosts..." % len(hosts), flush=True)
    with ThreadPoolExecutor(max_workers=128) as ex:
        for i, (ip, ok) in enumerate(ex.map(lambda h: (h, probe_open(h)), hosts)):
            if ok:
                with lock:
                    hits.append(ip)
            if i % 32 == 0:
                print("  %d/%d..." % (i, len(hosts)), flush=True)
    return hits


def main():
    args = [a for a in sys.argv[1:]]
    if "--ip" in args:
        idx = args.index("--ip")
        target = args[idx + 1]
        ips = [ipaddress.ip_address(target)]
    else:
        net = args[0] if args else guess_subnet()
        print("scanning %s for port %d..." % (net, PORT))
        ips = scan_network(net)

    print("open hosts on :%d:" % PORT)
    if not ips:
        print("  none found")
        return
    for ip in ips:
        status, server, total, body = http_probe(ip)
        if status is None:
            print("  %s  port open but HTTP probe failed: %s" % (ip, server))
        else:
            print("  %s  %s  server=%s  got %d bytes" % (ip, status, server, total))
            print("      body head: %r" % body)
    print("done")


def guess_subnet():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
    finally:
        s.close()
    parts = ip.split(".")
    return "%s.%s.%s.0/24" % (parts[0], parts[1], parts[2])


if __name__ == "__main__":
    main()
