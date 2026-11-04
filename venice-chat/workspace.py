"""Папка проекта для браузерной версии: те же операции /api/fs/*, что Workspace.swift в приложении.

Модель видит только папки, которые пользователь сам выбрал. При изменениях правь оба файла.
"""
import fnmatch
import json
import os
import re
import shutil
import subprocess
import time
import uuid
from pathlib import Path

SKIP_DIRS = {"node_modules", ".git", ".svn", ".hg", "vendor", ".venv", "venv", "__pycache__", ".pytest_cache",
             ".mypy_cache", ".parcel-cache", ".turbo", ".cache", ".idea", ".vscode", ".gradle", "Pods", "DerivedData",
             ".next", ".nuxt", ".pnpm-store", ".worktrees", "dist", "build", "out", "coverage", ".build", "target"}
MEMORY_FILES = ["AGENTS.md", "CLAUDE.md", ".cursorrules", "README.md"]
MAX_FILE_BYTES = 2 * 1024 * 1024
MAX_OUTPUT = 60_000


class FsError(Exception):
    pass


class Workspace:
    def __init__(self, data_dir: Path):
        self.data = data_dir
        self.folders = data_dir / "folders.json"
        self.backups = data_dir / "backups"
        self.memory_dir = data_dir / "memory"
        self.running = {}

    # ---- разрешённые папки ----
    def allowed(self):
        try:
            return json.loads(self.folders.read_text())
        except Exception:
            return []

    def allow(self, path):
        p = str(Path(path).expanduser().resolve())
        items = self.allowed()
        self.data.mkdir(parents=True, exist_ok=True)
        if p not in items:
            self.folders.write_text(json.dumps(sorted(set(items + [p]))))
        return p

    def root(self, body):
        r = str(body.get("root") or "")
        if not r:
            raise FsError("Папка проекта не выбрана")
        p = Path(r).resolve()
        if str(p) not in self.allowed():
            raise FsError(f"Нет доступа к папке {r}: выберите её кнопкой «Папка»")
        if not p.is_dir():
            raise FsError(f"Папки {r} больше нет")
        return p

    def resolve(self, root: Path, rel):
        s = str(rel or "").strip()
        if s.startswith(str(root) + "/"):
            s = s[len(str(root)) + 1:]
        while s.startswith("./"):
            s = s[2:]
        s = s.lstrip("/")
        url = root if s in ("", ".") else Path(os.path.normpath(root / s))
        check = url.resolve() if url.exists() else url.parent.resolve() / url.name
        if check != root and root not in check.parents:
            raise FsError(f"Путь {s} ведёт за пределы папки проекта")
        return url

    @staticmethod
    def rel(root: Path, p: Path):
        return "." if p == root else str(p.relative_to(root))

    # ---- обход ----
    def walk(self, under: Path):
        for dirpath, dirnames, filenames in os.walk(under):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS and (not d.startswith(".") or d == ".github"))
            for name in sorted(filenames):
                if name == ".DS_Store":
                    continue
                p = Path(dirpath) / name
                if p.is_symlink():
                    continue
                try:
                    yield p, p.stat().st_size
                except OSError:
                    continue

    @staticmethod
    def glob_re(glob):
        out, i, brace = "", 0, False
        while i < len(glob):
            c = glob[i]
            if c == "*":
                if glob[i + 1:i + 2] == "*":
                    if glob[i + 2:i + 3] == "/":
                        out += "(?:.*/)?"; i += 3; continue
                    out += ".*"; i += 2; continue
                out += "[^/]*"
            elif c == "?":
                out += "[^/]"
            elif c == "{":
                out += "(?:"; brace = True
            elif c == "}":
                out += ")"; brace = False
            elif c == ",":
                out += "|" if brace else ","
            else:
                out += re.escape(c)
            i += 1
        return re.compile("^" + out + "$", re.I)

    @staticmethod
    def matches(rx, glob, path):
        if rx is None:
            return True
        return bool(rx.match(path if "/" in glob else path.rsplit("/", 1)[-1]))

    @staticmethod
    def read_text(p: Path):
        data = p.read_bytes()
        if b"\0" in data[:8000]:
            raise FsError("Это двоичный файл, прочитать его как текст нельзя")
        try:
            return data.decode("utf-8")
        except UnicodeDecodeError:
            return data.decode("cp1251", errors="replace")

    # ---- операции ----
    def handle(self, op, body, pick_path=None):
        if op == "pick":
            path = str(body.get("path") or "").strip()
            if not path:
                return {"cancelled": True}
            p = Path(path).expanduser()
            if not p.is_dir():
                raise FsError(f"Папки {path} нет")
            full = self.allow(p)
            return {"path": full, "name": Path(full).name}
        r = self.root(body)
        fn = {"info": self.info, "list": self.list, "grep": self.grep, "read": self.read, "write": self.write,
              "edit": self.edit, "undo": self.undo, "run": self.run, "memory": self.memory}.get(op)
        if not fn:
            raise FsError(f"Нет такой операции: {op}")
        return fn(r, body)

    def info(self, r, body):
        files = size = 0
        top = {}
        for p, s in self.walk(r):
            files += 1; size += s
            first = self.rel(r, p).split("/")[0]
            top[first] = top.get(first, 0) + 1
            if files >= 200_000:
                break
        docs = []
        for name in MEMORY_FILES:
            f = r / name
            if f.is_file():
                try:
                    docs.append({"name": name, "text": self.read_text(f)[:6000 if name == "README.md" else 30000]})
                except Exception:
                    pass
        return {"name": r.name, "path": str(r), "files": files, "bytes": size, "top": top,
                "entries": sorted(os.listdir(r)), "docs": docs, "notes": self.memory(r, {})["notes"],
                "git": (r / ".git").exists()}

    def list(self, r, body):
        d = self.resolve(r, body.get("dir"))
        glob = str(body.get("pattern") or "").strip()
        rx = self.glob_re(glob) if glob else None
        limit = min(int(body.get("limit") or 400), 2000)
        rows, total = [], 0
        for p, s in self.walk(d):
            rp = self.rel(r, p)
            local = self.rel(d, p) if d != r else rp
            if not (self.matches(rx, glob, local) or self.matches(rx, glob, rp)):
                continue
            total += 1
            if len(rows) < limit:
                rows.append(f"{rp}\t{s}")
        return {"files": rows, "total": total}

    def grep(self, r, body):
        q = str(body.get("query") or "")
        if not q:
            raise FsError("Пустой запрос")
        is_re = bool(body.get("regex"))
        ic = body.get("ignore_case")
        ic = (not is_re) if ic is None else bool(ic)
        try:
            rx = re.compile(q if is_re else re.escape(q), re.I if ic else 0)
        except re.error as e:
            raise FsError(f"Ошибка в регулярном выражении: {e}")
        d = self.resolve(r, body.get("path"))
        glob = str(body.get("glob") or "").strip()
        grx = self.glob_re(glob) if glob else None
        ctx = max(0, min(int(body.get("context") or 0), 10))
        limit = max(1, min(int(body.get("limit") or 150), 500))
        out, total, files = [], 0, 0

        def one(p):
            nonlocal total, files
            try:
                lines = self.read_text(p).split("\n")
            except Exception:
                return
            rp, hit, last = self.rel(r, p), False, -1
            for i, line in enumerate(lines):
                if not rx.search(line):
                    continue
                total += 1; hit = True
                if len(out) >= limit:
                    continue
                if ctx:
                    lo, hi = max(0, i - ctx), min(len(lines) - 1, i + ctx)
                    if last >= 0 and lo > last + 1:
                        out.append("--")
                    for j in range(max(lo, last + 1), hi + 1):
                        out.append(f"{rp}:{j + 1}{':' if j == i else '-'} {lines[j][:300]}")
                    last = hi
                else:
                    out.append(f"{rp}:{i + 1}: {line.strip()[:300]}")
            if hit:
                files += 1

        if d.is_file():
            one(d)
        else:
            for p, s in self.walk(d):
                if s <= MAX_FILE_BYTES and self.matches(grx, glob, self.rel(r, p)):
                    one(p)
        return {"lines": out, "total": total, "files": files}

    def read(self, r, body):
        p = self.resolve(r, body.get("path"))
        if not p.exists():
            raise FsError(f"Файла {body.get('path')} нет")
        if p.is_dir():
            raise FsError("Это папка — посмотри её через list_files")
        lines = self.read_text(p).split("\n")
        start = max(1, int(body.get("offset") or 1))
        count = max(1, min(int(body.get("limit") or 800), 3000))
        out, chars, last = [], 0, start - 1
        for i in range(start - 1, min(len(lines), start - 1 + count)):
            ln = lines[i]
            row = f"{i + 1}\t{ln[:2000] + '…' if len(ln) > 2000 else ln}"
            chars += len(row)
            if chars > 120_000 and out:
                break
            out.append(row); last = i + 1
        return {"path": self.rel(r, p), "text": "\n".join(out), "from": start, "to": last, "total": len(lines)}

    def backup(self, r, p):
        bid = f"{int(time.time() * 1000)}-{uuid.uuid4().hex[:6]}"
        d = self.backups / bid
        d.mkdir(parents=True)
        existed = p.exists()
        if existed:
            shutil.copy2(p, d / "file")
        (d / "meta.json").write_text(json.dumps({"root": str(r), "path": self.rel(r, p), "existed": existed}))
        return bid

    def write(self, r, body):
        p = self.resolve(r, body.get("path"))
        if p == r:
            raise FsError("Укажи путь к файлу")
        old = None
        if p.exists():
            try:
                old = self.read_text(p)
            except Exception:
                old = ""
        bid = self.backup(r, p)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(str(body.get("content") or ""), encoding="utf-8")
        return {"backup": bid, "created": old is None, "old": old or "", "path": self.rel(r, p)}

    def edit(self, r, body):
        p = self.resolve(r, body.get("path"))
        if not p.exists():
            raise FsError(f"Файла {body.get('path')} нет — для нового файла используй write_file")
        old, new = str(body.get("old") or ""), str(body.get("new") or "")
        if not old:
            raise FsError("Пустой old — укажи точный кусок текста, который нужно заменить")
        text = self.read_text(p)
        n = text.count(old)
        if n == 0:
            raise FsError("Такого куска в файле нет. Перечитай файл через read_file и скопируй текст точно, с отступами")
        allm = bool(body.get("all"))
        if n > 1 and not allm:
            raise FsError(f"Кусок встречается {n} раз. Добавь соседние строки, чтобы он стал уникальным, или передай all=true")
        line = text[:text.index(old)].count("\n") + 1
        if body.get("dry"):
            return {"line": line, "count": n, "path": self.rel(r, p)}
        updated = text.replace(old, new) if allm else text.replace(old, new, 1)
        bid = self.backup(r, p)
        p.write_text(updated, encoding="utf-8")
        return {"backup": bid, "replaced": n if allm else 1, "line": line, "path": self.rel(r, p)}

    def undo(self, r, body):
        bid = str(body.get("backup") or "").replace("/", "")
        d = self.backups / bid
        try:
            meta = json.loads((d / "meta.json").read_text())
        except Exception:
            raise FsError("Копия для отмены не найдена")
        if not bid or meta.get("root") != str(r):
            raise FsError("Копия для отмены не найдена")
        p = self.resolve(r, meta["path"])
        if meta.get("existed"):
            shutil.copy2(d / "file", p)
        elif p.exists():
            p.unlink()
        return {"ok": True, "path": meta["path"]}

    def run(self, r, body):
        cmd = str(body.get("command") or "").strip()
        if not cmd:
            raise FsError("Пустая команда")
        timeout = max(5, min(int(body.get("timeout") or 120), 900))
        env = dict(os.environ, TERM="dumb", NO_COLOR="1", CI="1")
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + env.get("PATH", "/usr/bin:/bin")
        shell = "/bin/zsh" if Path("/bin/zsh").exists() else "/bin/bash"
        timed_out = False
        try:
            proc = subprocess.run([shell, "-lc", cmd], cwd=r, env=env, stdin=subprocess.DEVNULL,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
            data, code = proc.stdout, proc.returncode
        except subprocess.TimeoutExpired as e:
            data, code, timed_out = e.stdout or b"", -1, True
        text = data.decode("utf-8", errors="replace")
        if len(text) > MAX_OUTPUT:
            text = text[:MAX_OUTPUT // 3] + f"\n…[вывод сокращён: {len(text)} символов]…\n" + text[-MAX_OUTPUT * 2 // 3:]
        return {"code": code, "output": text, "timedOut": timed_out}

    def memory(self, r, body):
        self.memory_dir.mkdir(parents=True, exist_ok=True)
        safe = str(r).replace("/", "_").replace(":", "_")[-150:]
        f = self.memory_dir / f"{safe}.md"
        text = f.read_text(encoding="utf-8") if f.exists() else ""
        if "replace" in body:
            text = str(body["replace"] or "")
        add = str(body.get("add") or "").strip()
        if add:
            text += ("" if not text or text.endswith("\n") else "\n") + "- " + add + "\n"
        if "replace" in body or add:
            f.write_text(text[-40000:], encoding="utf-8")
        return {"notes": text}
