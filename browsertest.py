#!/usr/bin/env python3

from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = 8080

PAGE = """<!DOCTYPE html>
<html>
<head>
<title>ShellyForever Browser Test</title>
</head>

<body>

<h1>ShellyForever Browser Test</h1>

<p>If you can read this, your browser works!</p>

<hr>

<h2>Paragraph Test</h2>

<p>
This is a normal paragraph containing
<b>bold</b>,
<i>italic</i>,
<u>underlined</u>,
and plain text.
</p>

<hr>

<h2>Lists</h2>

<ul>
<li>Apple</li>
<li>Banana</li>
<li>Cherry</li>
</ul>

<ol>
<li>First</li>
<li>Second</li>
<li>Third</li>
</ol>

<hr>

<h2>Links</h2>

<p><a href="/">Home</a></p>
<p><a href="/about">About</a></p>
<p><a href="/numbers">Numbers</a></p>

<hr>

<h2>Preformatted Text</h2>

<pre>
+----------------------+
| ShellyForever Rocks! |
+----------------------+
</pre>

<hr>

<h2>Table</h2>

<table border="1">
<tr>
<th>Name</th>
<th>Age</th>
</tr>

<tr>
<td>Alice</td>
<td>22</td>
</tr>

<tr>
<td>Bob</td>
<td>35</td>
</tr>

</table>

<hr>

<p>End of page.</p>

</body>
</html>
"""


ABOUT = """<!DOCTYPE html>
<html>
<head><title>About</title></head>

<body>

<h1>About</h1>

<p>
This page exists so you can test hyperlinks.
</p>

<p><a href="/">Back</a></p>

</body>
</html>
"""


NUMBERS = """<!DOCTYPE html>
<html>
<head><title>Numbers</title></head>

<body>

<h1>Numbers</h1>

<ul>
"""

for i in range(1, 101):
    NUMBERS += f"<li>{i}</li>\n"

NUMBERS += """
</ul>

<p><a href="/">Back</a></p>

</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):

    def send_html(self, html):
        data = html.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):

        if self.path == "/":
            self.send_html(PAGE)

        elif self.path == "/about":
            self.send_html(ABOUT)

        elif self.path == "/numbers":
            self.send_html(NUMBERS)

        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"404 Not Found")


print(f"Serving on http://0.0.0.0:{PORT}")

HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()