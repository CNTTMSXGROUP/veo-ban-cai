import json
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock


root = Path(sys.argv[1])
resources = Path(sys.argv[2])
core = {g["tep"]: g for g in json.loads((resources / "phan-chay.json").read_text())["items"]}
pack, = json.loads((resources / "phan-do-hoa.json").read_text())["items"]
public = "https://github.com/CNTTMSXGROUP/veo-ban-cai/releases/download/phan-chay/"
lock = Lock()
downloads = 0


class Mirror(BaseHTTPRequestHandler):
    def respond(self, code, value):
        data = json.dumps(value, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        global downloads
        if self.path == "/qa/state":
            warm = (root / "warm.flag").exists()
            value = {"warm": warm, "coreBytes": sum(g["size"] for g in core.values())}
            if warm:
                value["cold"] = json.loads((root / "cold.json").read_text())
            return self.respond(200, value)
        prefix = "/runtime/"
        if not self.path.startswith(prefix):
            return self.respond(404, {})
        name = self.path[len(prefix):]
        if (root / "warm.flag").exists():
            (root / "unexpected-download").touch()
            return self.respond(503, {})
        if name in core:
            self.send_response(307)
            self.send_header("Location", public + name)
            self.end_headers()
            return
        if name != pack["tep"]:
            return self.respond(404, {})
        file = root / pack["tep"]
        asked = re.fullmatch(r"bytes=(\d+)-", self.headers.get("Range", ""))
        start = int(asked[1]) if asked else 0
        if start >= pack["size"]:
            return self.respond(416, {})
        with lock:
            downloads += 1
            corrupt = downloads == 1
        self.send_response(206 if asked else 200)
        self.send_header("Content-Type", "application/gzip")
        self.send_header("Content-Length", str(pack["size"] - start))
        if asked:
            self.send_header("Content-Range", f"bytes {start}-{pack['size'] - 1}/{pack['size']}")
        self.end_headers()
        with file.open("rb") as source:
            source.seek(start)
            chunk = source.read(1 << 20)
            if corrupt:
                chunk = bytes([chunk[0] ^ 1]) + chunk[1:]
            while chunk:
                self.wfile.write(chunk)
                chunk = source.read(1 << 20)
        print(f"HyperFrames {pack['size']} byte · {'sai một byte' if corrupt else 'đúng nội dung'}", flush=True)

    def do_POST(self):
        kind = self.path.removeprefix("/qa/")
        if kind not in ("cold", "warm", "failure"):
            return self.respond(404, {})
        body = json.loads(self.rfile.read(min(16384, int(self.headers["Content-Length"]))))
        temporary = root / (kind + ".tmp")
        temporary.write_text(json.dumps(body, ensure_ascii=False))
        temporary.replace(root / (kind + ".json"))
        return self.respond(200, {"ok": True})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 49325), Mirror).serve_forever()
