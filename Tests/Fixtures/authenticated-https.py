#!/usr/bin/env python3
"""Disposable TLS + Basic-auth smart Git server. Never use with real credentials."""
import base64
import http.server
import os
from pathlib import Path
import ssl
import subprocess
import sys
import urllib.parse


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def serve(self):
        expected = "Basic " + base64.b64encode(b"alice:gitpier-synthetic-token").decode()
        if self.headers.get("Authorization") != expected:
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Basic realm="GitPier synthetic fixture"')
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        url = urllib.parse.urlsplit(self.path)
        env = dict(os.environ, GIT_PROJECT_ROOT=sys.argv[1], GIT_HTTP_EXPORT_ALL="1",
                   REQUEST_METHOD=self.command, PATH_INFO=url.path, QUERY_STRING=url.query,
                   CONTENT_TYPE=self.headers.get("Content-Type", ""), REMOTE_USER="alice")
        data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        result = subprocess.run(["/usr/bin/git", "http-backend"], env=env, input=data,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=20)
        headers, _, body = result.stdout.partition(b"\r\n\r\n")
        if not body and b"\r\n\r\n" not in result.stdout:
            headers, _, body = result.stdout.partition(b"\n\n")
        status = 200
        parsed = []
        for line in headers.decode().splitlines():
            name, value = line.split(":", 1)
            if name.lower() == "status":
                status = int(value.split()[0])
            else:
                parsed.append((name, value.strip()))
        self.send_response(status)
        for name, value in parsed:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    do_GET = serve
    do_POST = serve


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[2], sys.argv[3])
server.socket = context.wrap_socket(server.socket, server_side=True)
Path(sys.argv[4]).write_text(str(server.server_port))
server.serve_forever()
