#!/usr/bin/env python3
"""Loopback-only fixture server; never uploads files or serves production keys."""
from functools import partial
from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
import json
import sys

root = Path(sys.argv[1]).resolve()
assert '/.cache/update-acceptance/' in str(root)
root.mkdir(parents=True, exist_ok=True)
server = ThreadingHTTPServer(('127.0.0.1', 0), partial(SimpleHTTPRequestHandler, directory=str(root)))
(root / 'server.json').write_text(json.dumps({'port': server.server_port}))
print(f'Update fixture server on 127.0.0.1:{server.server_port}', flush=True)
try:
    server.serve_forever()
except KeyboardInterrupt:
    pass
finally:
    server.server_close()
