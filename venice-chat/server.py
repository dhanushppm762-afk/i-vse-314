#!/usr/bin/env python3
"""Браузерная версия «И ВСЕ 3,14здец»: отдаёт интерфейс из static/ и проксирует /api/* в Venice.

Только стандартная библиотека. Запуск: python3 venice-chat/server.py → http://localhost:8765
Маршруты те же, что в macapp/Backend.swift — при изменениях правь оба файла.
"""
import ipaddress
import json
import os
import re
import socket
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from workspace import FsError, Workspace

HERE = Path(__file__).resolve().parent
STATIC = HERE / "static"
DATA = Path.home() / "Library" / "Application Support" / "VeniceChat"
FETCH_LIMIT = 80 * 1024 * 1024
MODELS_TTL = 600


def load_env():
    env = {}
    path = HERE / ".env"
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    for k in ("VENICE_API_KEY", "VENICE_BASE_URL", "VENICE_MODEL", "PORT"):
        if os.environ.get(k):
            env[k] = os.environ[k]
    return env


ENV = load_env()
KEY = ENV.get("VENICE_API_KEY", "")
BASE = ENV.get("VENICE_BASE_URL", "https://api.venice.ai/api/v1").rstrip("/")
DEFAULT_MODEL = ENV.get("VENICE_MODEL", "deepseek-v4-1-flash-1017-uncensored")
PORT = int(ENV.get("PORT", "8765"))

_models_cache = {}
_lock = threading.Lock()

MIME = {".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8",
        ".js": "text/javascript; charset=utf-8", ".svg": "image/svg+xml", ".png": "image/png",
        ".json": "application/json", ".ico": "image/x-icon", ".wav": "audio/wav"}


# ---------- модели ----------
def usd(p, *path):
    for k in path:
        if not isinstance(p, dict):
            return None
        p = p.get(k)
    return p if isinstance(p, (int, float)) else None


def normalize_model(m, kind):
    spec = m.get("model_spec") or {}
    caps = spec.get("capabilities") or {}
    pricing = spec.get("pricing") or {}
    out = {
        "id": m.get("id"),
        "name": spec.get("name") or m.get("id"),
        "vision": bool(caps.get("supportsVision")),
        "reasoning": bool(caps.get("supportsReasoning")),
        "web": bool(caps.get("supportsWebSearch") or spec.get("supportsWebSearch")),
        "tools": bool(caps.get("supportsFunctionCalling")),
        "context": spec.get("availableContextTokens") or m.get("context_length"),
        "constraints": spec.get("constraints") or {},
        "pricing": pricing,
        "traits": spec.get("traits") or [],
    }
    if kind == "text":
        price = usd(pricing, "input", "usd")
    else:
        price = usd(pricing, "generation", "usd") or usd(pricing, "inpaint", "usd")
        if price is None and isinstance(pricing.get("resolutions"), dict):
            vals = [usd(v, "usd") for v in pricing["resolutions"].values()]
            vals = [v for v in vals if v is not None]
            price = min(vals) if vals else None
    out["price"] = price
    return out


def get_models(kind):
    with _lock:
        hit = _models_cache.get(kind)
        if hit and time.time() - hit[0] < MODELS_TTL:
            return hit[1]
    status, _, body = venice("GET", f"/models?type={urllib.parse.quote(kind)}")
    if status != 200:
        raise RuntimeError(body.decode("utf-8", "replace"))
    data = json.loads(body).get("data") or []
    models = [normalize_model(m, kind) for m in data if not (m.get("model_spec") or {}).get("offline")]
    with _lock:
        _models_cache[kind] = (time.time(), models)
    return models


# ---------- запросы к Venice ----------
def venice(method, path, body=None, stream=False):
    req = urllib.request.Request(BASE + path, data=body, method=method)
    req.add_header("Authorization", f"Bearer {KEY}")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        resp = urllib.request.urlopen(req, timeout=600)
    except urllib.error.HTTPError as e:
        remember_balance(e.headers)
        return e.code, e.headers, e.read()
    except urllib.error.URLError as e:
        return 502, {}, json.dumps({"error": f"Нет связи с Venice: {e.reason}"}).encode()
    remember_balance(resp.headers)
    if stream:
        return resp.status, resp.headers, resp
    return resp.status, resp.headers, resp.read()


def remember_balance(headers):
    try:
        val = headers.get("x-venice-balance-usd") if headers else None
    except Exception:
        val = None
    if val is None:
        return
    try:
        bal = float(val)
    except ValueError:
        return
    with _lock:
        u = read_json(DATA / "usage.json", {"events": []})
        u["balance"] = {"usd": bal, "at": int(time.time() * 1000)}
        write_json(DATA / "usage.json", u)


def fetch_balance():
    """Баланс прямо из Venice (GET /api_keys/rate_limits), без ожидания следующего запроса к модели."""
    if not KEY:
        return None
    status, _, raw = venice("GET", "/api_keys/rate_limits")
    if status != 200:
        return None
    try:
        b = (json.loads(raw).get("data") or {}).get("balances") or {}
    except Exception:
        return None
    if b.get("USD") is None:
        return None
    bal = {"usd": float(b["USD"]), "at": int(time.time() * 1000)}
    if b.get("DIEM"):
        bal["diem"] = float(b["DIEM"])
    if b.get("BUNDLED_CREDITS"):
        bal["credits"] = float(b["BUNDLED_CREDITS"])
    with _lock:
        u = read_json(DATA / "usage.json", {"events": []})
        u["balance"] = bal
        write_json(DATA / "usage.json", u)
    return bal


# ---------- файлы ----------
def read_json(path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return default


def write_json(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(obj, ensure_ascii=False), encoding="utf-8")
    tmp.replace(path)


SAFE_ID = re.compile(r"^[\w.-]{1,120}$")


def list_items(folder, fields):
    items = []
    for f in (DATA / folder).glob("*.json"):
        d = read_json(f, None)
        if isinstance(d, dict):
            item = {k: d.get(k) for k in fields if k in d}
            if folder == "projects":
                item["fileCount"] = len(d.get("files") or [])
            items.append(item)
    items.sort(key=lambda x: x.get("updated") or x.get("created") or 0, reverse=True)
    return items


CHAT_FIELDS = ("id", "title", "created", "updated", "model", "projectId", "pinned")
PROJECT_FIELDS = ("id", "name", "description", "created", "updated", "folder")


# ---------- /api/fetch ----------
def is_public_host(host):
    if not host or host.lower() in ("localhost",) or host.lower().endswith(".localhost"):
        return False
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror:
        return False
    for info in infos:
        ip = ipaddress.ip_address(info[4][0].split("%")[0])
        if ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_reserved or ip.is_multicast or ip.is_unspecified:
            return False
    return True


class NoPrivateRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        host = urllib.parse.urlparse(newurl).hostname
        if not is_public_host(host):
            raise urllib.error.URLError("переадресация на локальный адрес запрещена")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


FETCH_OPENER = urllib.request.build_opener(NoPrivateRedirect)
WORKSPACE = Workspace(DATA)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    # --- ответы ---
    def send(self, status, body=b"", ctype="application/json; charset=utf-8", headers=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def error(self, status, message):
        self.send(status, {"error": message})

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def json_body(self):
        try:
            return json.loads(self.body() or b"{}")
        except json.JSONDecodeError:
            return None

    # --- маршрутизация ---
    def do_GET(self):
        self.route("GET")

    def do_POST(self):
        self.route("POST")

    def do_PUT(self):
        self.route("PUT")

    def do_DELETE(self):
        self.route("DELETE")

    def route(self, method):
        url = urllib.parse.urlparse(self.path)
        path = url.path
        query = urllib.parse.parse_qs(url.query)
        try:
            if not path.startswith("/api/"):
                return self.static(path) if method == "GET" else self.error(405, "Метод не поддерживается")
            if path == "/api/config" and method == "GET":
                return self.send(200, {"model": DEFAULT_MODEL, "app": False})
            if path == "/api/models" and method == "GET":
                kind = (query.get("type") or ["text"])[0]
                if kind not in ("text", "image", "inpaint", "upscale"):
                    return self.error(400, "Неизвестный тип моделей")
                return self.send(200, get_models(kind))
            if path == "/api/chat" and method == "POST":
                return self.chat()
            m = re.fullmatch(r"/api/image/(generate|edit|multi-edit|upscale)", path)
            if m and method == "POST":
                return self.image(m.group(1))
            if path == "/api/fetch" and method == "POST":
                return self.fetch_url()
            if path == "/api/usage":
                return self.usage(method)
            if path == "/api/balance" and method == "POST":
                return self.send(200, {"balance": fetch_balance()})
            if path == "/api/key":
                return self.error(404, "Смена ключа есть только в приложении для Mac")
            m = re.fullmatch(r"/api/fs/(\w+)", path)
            if m and method == "POST":
                return self.fs(m.group(1))
            m = re.fullmatch(r"/api/(chats|projects)(?:/([^/]+))?", path)
            if m:
                return self.store(method, m.group(1), m.group(2) and urllib.parse.unquote(m.group(2)))
            return self.error(404, "Нет такого маршрута")
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as e:  # ответ интерфейсу вместо обрыва соединения
            try:
                self.error(500, str(e))
            except Exception:
                pass

    def static(self, path):
        rel = "index.html" if path in ("", "/") else urllib.parse.unquote(path.lstrip("/"))
        f = (STATIC / rel).resolve()
        if STATIC not in f.parents and f != STATIC or not f.is_file():
            return self.error(404, "Файл не найден")
        self.send(200, f.read_bytes(), MIME.get(f.suffix, "application/octet-stream"))

    # --- чат: поток SSE как есть ---
    def chat(self):
        payload = self.json_body()
        if payload is None:
            return self.error(400, "Неверный JSON")
        stream = payload.get("stream", True)
        payload["stream"] = stream
        if stream:
            payload.setdefault("stream_options", {"include_usage": True})
        status, headers, resp = venice("POST", "/chat/completions", json.dumps(payload).encode(), stream=stream)
        if not stream or status != 200:
            body = resp if isinstance(resp, bytes) else resp.read()
            return self.send(status, body, headers.get("Content-Type", "application/json") if headers else "application/json")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            while True:
                chunk = resp.read1(65536) if hasattr(resp, "read1") else resp.read(4096)
                if not chunk:
                    break
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
        finally:
            resp.close()

    def image(self, op):
        body = self.body()
        status, headers, data = venice("POST", f"/image/{op}", body)
        ctype = headers.get("Content-Type", "application/octet-stream") if headers else "application/json"
        self.send(status, data, ctype)

    def fetch_url(self):
        p = self.json_body() or {}
        url = str(p.get("url") or "")
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme not in ("http", "https"):
            return self.error(400, "Нужна ссылка http или https")
        if not is_public_host(parsed.hostname):
            return self.error(403, "Локальные и частные адреса запрещены")
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (Macintosh) VeniceChat/1.0", "Accept": "*/*"})
        try:
            resp = FETCH_OPENER.open(req, timeout=60)
        except urllib.error.HTTPError as e:
            return self.error(e.code, f"Сайт ответил ошибкой {e.code}")
        except urllib.error.URLError as e:
            return self.error(502, f"Не удалось открыть ссылку: {e.reason}")
        with resp:
            data = resp.read(FETCH_LIMIT + 1)
            if len(data) > FETCH_LIMIT:
                return self.error(413, "Файл больше 80 МБ")
            self.send(200, data, resp.headers.get("Content-Type", "application/octet-stream"),
                      {"X-Final-URL": urllib.parse.quote(resp.geturl(), safe=":/?&=%#")})

    def fs(self, op):
        # Папка на диске и команды: только со своей страницы (защита от чужих сайтов, стучащихся на localhost)
        origin = self.headers.get("Origin")
        host = (self.headers.get("Host") or "").split(":")[0]
        if host not in ("localhost", "127.0.0.1") or (origin and urllib.parse.urlparse(origin).hostname not in ("localhost", "127.0.0.1")) \
                or "application/json" not in (self.headers.get("Content-Type") or ""):
            return self.error(403, "Запрещено")
        try:
            res = WORKSPACE.handle(op, self.json_body() or {})
            return self.send(200, res, "application/octet-stream") if isinstance(res, bytes) else self.send(200, res)
        except FsError as e:
            return self.error(400, str(e))

    def usage(self, method):
        path = DATA / "usage.json"
        with _lock:
            u = read_json(path, {"events": []})
            if method == "GET":
                return self.send(200, u)
            if method == "POST":
                ev = self.json_body()
                if not isinstance(ev, dict):
                    return self.error(400, "Неверный JSON")
                u.setdefault("events", []).append(ev)
                write_json(path, u)
                return self.send(200, {"ok": True})
            if method == "DELETE":
                write_json(path, {"events": [], "balance": u.get("balance")})
                return self.send(200, {"ok": True})
        self.error(405, "Метод не поддерживается")

    def store(self, method, folder, item_id):
        fields = CHAT_FIELDS if folder == "chats" else PROJECT_FIELDS
        if item_id is None:
            if method == "GET":
                return self.send(200, list_items(folder, fields))
            return self.error(405, "Метод не поддерживается")
        if not SAFE_ID.match(item_id):
            return self.error(400, "Неверный id")
        f = DATA / folder / f"{item_id}.json"
        if method == "GET":
            return self.send(200, f.read_bytes()) if f.exists() else self.error(404, "Не найдено")
        if method == "PUT":
            obj = self.json_body()
            if not isinstance(obj, dict):
                return self.error(400, "Неверный JSON")
            write_json(f, obj)
            return self.send(200, {"ok": True})
        if method == "DELETE":
            f.unlink(missing_ok=True)
            if folder == "chats":
                WORKSPACE.drop_work(item_id)
            return self.send(200, {"ok": True})
        self.error(405, "Метод не поддерживается")


def main():
    if not KEY:
        print("⚠️  В venice-chat/.env нет VENICE_API_KEY — запросы к Venice не пройдут.")
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"И ВСЕ 3,14здец: http://localhost:{PORT}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        WORKSPACE.stop_all_jobs()


if __name__ == "__main__":
    main()
