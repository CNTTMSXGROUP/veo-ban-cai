import json
import ssl
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


root = Path(sys.argv[1])
installer = root / "Veo-Windows-Signed-Flow-QA_0.3.24_x64-setup.exe"
signature = installer.with_suffix(".exe.sig").read_text(encoding="ascii").strip()
origin = "https://127.0.0.1:49324"


class UpdateFeed(BaseHTTPRequestHandler):
    def respond(self, status, body=b"", content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_GET(self):
        path = urlsplit(self.path)
        if path.path == "/health":
            return self.respond(200, b'{"ready":true}')
        if path.path == "/latest.json":
            phase = (root / "cap-nhat.mode").read_text(encoding="ascii").strip()
            if phase == "off":
                return self.respond(204)
            if phase not in ("bad-bytes", "wrong-version", "valid"):
                return self.respond(503)
            version = "0.3.25" if phase == "wrong-version" else "0.3.24"
            entry = {"signature": signature, "url": f"{origin}/installer.exe?{phase}"}
            manifest = {"version": version, "platforms": {"windows-x86_64": entry}}
            return self.respond(200, json.dumps(manifest).encode())
        if path.path == "/installer.exe" and path.query in ("bad-bytes", "wrong-version", "valid"):
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(installer.stat().st_size))
            self.end_headers()
            with installer.open("rb") as file:
                chunk = file.read(1024 * 1024)
                if path.query == "bad-bytes":
                    chunk = bytes([chunk[0] ^ 1]) + chunk[1:]
                while chunk:
                    self.wfile.write(chunk)
                    chunk = file.read(1024 * 1024)
            print(f"Da gui het goi {path.query}, {installer.stat().st_size} byte", flush=True)
            return
        return self.respond(404)


if __name__ == "__main__":
    with ThreadingHTTPServer(("127.0.0.1", 49324), UpdateFeed) as server:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(root / "loopback.pem", root / "loopback.key")
        server.socket = context.wrap_socket(server.socket, server_side=True)
        server.serve_forever()
