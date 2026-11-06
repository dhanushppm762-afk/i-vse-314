"""Папка проекта для браузерной версии: те же операции /api/fs/*, что Workspace.swift в приложении.

Модель видит только папки, которые пользователь сам выбрал. При изменениях правь оба файла.
"""
import base64
import errno
import fnmatch
import json
import os
import re
import shutil
import signal
import subprocess
import threading
import time
import uuid
from pathlib import Path

SKIP_DIRS = {"node_modules", ".git", ".svn", ".hg", "vendor", ".venv", "venv", "__pycache__", ".pytest_cache",
             ".mypy_cache", ".parcel-cache", ".turbo", ".cache", ".idea", ".vscode", ".gradle", "Pods", "DerivedData",
             ".next", ".nuxt", ".pnpm-store", ".worktrees", "dist", "build", "out", "coverage", ".build", "target"}
# Рабочие копии архивов: <данные>/work/<чат>/<метка>/<имя>
WORK_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
WORK_SKIP = {"node_modules", ".git", "__pycache__", ".venv", "venv", "Pods", ".gradle", "DerivedData", "jspm_packages"}   # должно быть подмножеством UNPACK_SKIP в archive-work.js
WORK_MAX_FILES = 100_000
NOT_WORK = "Это можно только в рабочей копии архива"
MEMORY_FILES = ["AGENTS.md", "CLAUDE.md", ".cursorrules", "README.md"]
MAX_FILE_BYTES = 2 * 1024 * 1024
# Карта кода: шаблоны объявлений (имя — в группе n); те же, что в Workspace.swift
SYMBOL_PATTERNS = [re.compile(p) for p in [
    r"^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\*?\s+(?P<n>[\w$]+)",
    r"^\s*(?:export\s+)?(?:default\s+)?(?:abstract\s+)?class\s+(?P<n>[\w$]+)",
    r"^\s*(?:export\s+)?(?:const|let|var)\s+(?P<n>[\w$]+)\s*=\s*(?:async\s+)?(?:function|\([^)]*\)\s*=>|[\w$]+\s*=>)",
    r"^\s*(?:export\s+)?(?:declare\s+)?(?:interface|type|enum)\s+(?P<n>[\w$]+)",
    r"^\s*(?:async\s+)?def\s+(?P<n>[\w?!]+)",
    r"^\s*(?:class|module)\s+(?P<n>[\w:]+)",
    r"^\s*(?:(?:public|private|fileprivate|internal|open|static|final|override|mutating|nonisolated|@\w+)\s+)*(?:func|struct|enum|protocol|extension|actor)\s+(?P<n>\w+)",
    r"^func\s+(?:\([^)]*\)\s*)?(?P<n>\w+)",
    r"^type\s+(?P<n>\w+)",
    r"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:fn|struct|enum|trait|impl|mod)\s+(?P<n>\w+)",
    r"^\s*(?:(?:public|private|protected|static|final|abstract|internal|open|data|sealed|override)\s+)*(?:interface|object|fun|record)\s+(?P<n>\w+)",
    r"^\s*(?:(?:public|private|protected|static|final|abstract)\s+)*function\s+(?P<n>\w+)",
    r"^\s{2,4}(?:static\s+)?(?:async\s+)?(?:get\s+|set\s+)?(?P<n>[A-Za-z_$][\w$]*)\s*\([^)]*\)\s*\{\s*$",
]]
CODE_EXT = {"js", "mjs", "cjs", "jsx", "ts", "tsx", "vue", "svelte", "py", "rb", "go", "rs", "swift", "kt", "kts", "java", "cs", "php", "scala", "dart", "lua", "m", "mm"}
SKIP_NAMES = {"if", "for", "while", "switch", "catch", "function", "return", "else", "do", "try", "with", "elif", "super", "await", "new", "typeof"}
MAX_OUTPUT = 60_000
STALE = ("Файл {path} изменился после того, как ты его прочитал (его поменял пользователь, команда или форматировщик). "
         "Правка НЕ применена. Перечитай нужное место через read_file и повтори правку по свежему тексту.")


def file_version(p: Path):
    """Отметка версии файла: время изменения (мкс) и размер. Если она другая — файл меняли."""
    st = p.stat()
    return f"{st.st_mtime_ns // 1000}-{st.st_size}"


class FsError(Exception):
    pass


class Workspace:
    def __init__(self, data_dir: Path):
        self.data = data_dir
        self.folders = data_dir / "folders.json"
        self.backups = data_dir / "backups"
        self.memory_dir = data_dir / "memory"
        self.work_dir = data_dir / "work"
        self.folders_lock = threading.Lock()
        self.running = {}
        self.jobs = {}
        self.job_count = 0

    # ---- разрешённые папки ----
    def allowed(self):
        try:
            return json.loads(self.folders.read_text())
        except Exception:
            return []

    def save_folders(self, items):
        self.data.mkdir(parents=True, exist_ok=True)
        tmp = self.folders.with_name(f".folders-{uuid.uuid4().hex}.tmp")
        tmp.write_text(json.dumps(sorted(set(items))))
        os.replace(tmp, self.folders)

    def allow(self, path):
        p = str(Path(path).expanduser().resolve())
        with self.folders_lock:
            items = self.allowed()
            if p not in items:
                self.save_folders(items + [p])
        return p

    def forget_tree(self, base):
        """Копия архива больше не нужна: остановить запущенное в ней, убрать её папки из разрешённых и стереть с диска."""
        inside = lambda p: p == base or p.startswith(base + "/")
        procs = []
        for job in list(self.jobs.values()):
            if inside(job["root"]) and job["proc"].poll() is None:
                job["stopped"] = True
                procs.append(job["proc"])
        # команда в списке, пока не вернулась; poll() не зовём — он «забрал» бы уже вышедшую оболочку
        procs += [proc for root, proc in list(self.running.values()) if inside(root) and proc.returncode is None]
        for proc in procs:   # иначе команда (сборка, сервер) пересоздаст файлы в стёртой папке
            self.stop_tree(proc)
        self.stop_left(base)
        with self.folders_lock:
            items = self.allowed()
            keep = [p for p in items if p != base and not p.startswith(base + "/")]
            if len(keep) != len(items):
                self.save_folders(keep)
        shutil.rmtree(base, ignore_errors=True)

    # ---- рабочие копии архивов ----
    def work_base(self, r):
        work = self.work_dir.resolve()
        try:
            parts = r.relative_to(work).parts
        except ValueError:
            parts = ()
        if len(parts) < 2:
            raise FsError(NOT_WORK)
        return work / parts[0] / parts[1]

    def work_new(self, body):
        chat = str(body.get("chat") or "")
        if not WORK_ID.fullmatch(chat):
            raise FsError("Неверный id чата")
        name = re.sub(r"[^A-Za-z0-9._-]+", "-", str(body.get("name") or "")).strip(".-")[:60] or "archive"
        base = self.work_dir / chat / f"{int(time.time() * 1000)}-{uuid.uuid4().hex[:6]}"
        (base / name).mkdir(parents=True)
        return {"base": self.allow(base), "root": self.allow(base / name)}

    def put_files(self, r, body):
        self.work_base(r)
        files = body.get("files") or []
        for f in files:
            rel = str(f.get("path") or "")
            p = self.resolve(r, rel)
            if p == r or p.is_symlink() or p.is_dir():
                raise FsError(f"Нельзя записать {rel}")
            try:
                data = base64.b64decode(str(f.get("data") or ""), validate=True)
            except ValueError:
                raise FsError("Повреждённые данные файла")
            try:
                p.parent.mkdir(parents=True, exist_ok=True)
                with open(p, "ab" if f.get("append") else "wb") as out:
                    out.write(data)
                os.chmod(p, 0o755 if f.get("x") else 0o644)
            except OSError as e:
                raise FsError(f"Не удалось записать {rel}: {e.strerror}")
        return {"written": len(files)}

    def list_all(self, r, body):
        self.work_base(r)
        out = []
        for dirpath, dirnames, filenames in os.walk(r):
            dirnames[:] = [n for n in dirnames if n not in WORK_SKIP]
            for n in filenames:
                p = Path(dirpath) / n
                if p.is_symlink() or not p.is_file():
                    continue
                st = p.stat()
                out.append({"path": str(p.relative_to(r)), "size": st.st_size, "version": file_version(p), "x": bool(st.st_mode & 0o111)})
                if len(out) > WORK_MAX_FILES:
                    raise FsError("В рабочей папке больше 100 000 файлов — собрать архив нельзя")
        return {"files": out}

    def get_file(self, r, body):
        self.work_base(r)
        p = self.resolve(r, body.get("path"))
        if p.is_symlink() or not p.is_file():
            raise FsError(f"Файла {body.get('path')} нет")
        return p.read_bytes()

    def drop(self, r, body):
        self.forget_tree(str(self.work_base(r)))
        return {"ok": True}

    def drop_work(self, chat_id):
        """Чат удалён — стираем его рабочие копии архивов."""
        if not WORK_ID.fullmatch(str(chat_id or "")):
            return
        d = self.work_dir / chat_id
        if d.is_symlink():   # ссылку убираем, а не то, куда она ведёт
            d.unlink()
            return
        if d.is_dir():
            self.forget_tree(str(d.resolve()))

    def root(self, body):
        r = str(body.get("root") or "")
        if not r:
            raise FsError("Папка проекта не выбрана")
        p = Path(r).resolve()
        if str(p) not in self.allowed():
            raise FsError(f"Нет доступа к папке {r}: подключите её к проекту заново")
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
        if op == "work":
            return self.work_new(body)
        r = self.root(body)
        fn = {"put": self.put_files, "files": self.list_all, "get": self.get_file, "drop": self.drop, "info": self.info, "list": self.list, "grep": self.grep, "read": self.read, "write": self.write,
              "edit": self.edit, "undo": self.undo, "run": self.run, "memory": self.memory,
              "symbols": self.symbols, "job": self.job}.get(op)
        if op == "run" and body.get("background"):
            fn = self.start_job
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
        return {"path": self.rel(r, p), "text": "\n".join(out), "from": start, "to": last, "total": len(lines),
                "version": file_version(p)}

    def check_fresh(self, r, p, body):
        """Не даём править файл по устаревшей копии: expect — версия, которую модель видела при чтении."""
        if not p.exists():
            return
        exp = str(body.get("expect") or "")
        if exp and file_version(p) != exp:
            raise FsError(STALE.format(path=self.rel(r, p)))
        if body.get("mustBeNew"):
            raise FsError(f"Файл {self.rel(r, p)} уже есть, а ты его не читал. Прочитай его через read_file "
                          "и правь через edit_file — иначе можно затереть чужие изменения.")

    @staticmethod
    def snippet(text, line, new):
        """Как выглядит место правки теперь: несколько строк вокруг, с номерами."""
        lines = text.split("\n")
        lo = max(1, line - 3)
        hi = min(len(lines), line + new.count("\n") + 3, lo + 39)
        return "\n".join(f"{i}\t{lines[i - 1][:300]}" for i in range(lo, hi + 1))

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
        self.check_fresh(r, p, body)
        old = None
        if p.exists():
            try:
                old = self.read_text(p)
            except Exception:
                old = ""
        bid = self.backup(r, p)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(str(body.get("content") or ""), encoding="utf-8")
        return {"backup": bid, "created": old is None, "old": old or "", "path": self.rel(r, p), "version": file_version(p)}

    def edit(self, r, body):
        p = self.resolve(r, body.get("path"))
        if not p.exists():
            raise FsError(f"Файла {body.get('path')} нет — для нового файла используй write_file")
        old, new = str(body.get("old") or ""), str(body.get("new") or "")
        if not old:
            raise FsError("Пустой old — укажи точный кусок текста, который нужно заменить")
        self.check_fresh(r, p, body)
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
        return {"backup": bid, "replaced": n if allm else 1, "line": line, "path": self.rel(r, p),
                "version": file_version(p), "snippet": self.snippet(updated, line, new)}

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
        if meta.get("existed") and not (d / "file").is_file():
            raise FsError("Копия для отмены не найдена")
        if p.is_dir():
            raise FsError(f"На месте файла {meta['path']} теперь папка")
        try:
            if meta.get("existed"):
                p.parent.mkdir(parents=True, exist_ok=True)   # папку файла могла переместить или стереть команда
                shutil.copy2(d / "file", p)
            elif p.exists() or p.is_symlink():
                p.unlink()
        except OSError as e:
            why = {errno.ENOSPC: "на диске нет места", errno.EACCES: "нет прав на запись", errno.EPERM: "нет прав на запись",
                   errno.ENOTDIR: "на месте его папки теперь файл", errno.EEXIST: "на месте его папки теперь файл"}.get(e.errno, "ошибка записи")
            raise FsError(f"Не удалось вернуть {meta['path']}: {why}")
        return {"ok": True, "path": meta["path"]}

    @staticmethod
    def shell_env():
        env = dict(os.environ, TERM="dumb", NO_COLOR="1", CI="1")
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + env.get("PATH", "/usr/bin:/bin")
        return ("/bin/zsh" if Path("/bin/zsh").exists() else "/bin/bash"), env

    @staticmethod
    def clip(text):
        if len(text) > MAX_OUTPUT:
            return text[:MAX_OUTPUT // 3] + f"\n…[вывод сокращён: {len(text)} символов]…\n" + text[-MAX_OUTPUT * 2 // 3:]
        return text

    # ---- фоновые команды: долгая установка или сборка идёт, а модель тем временем читает код ----
    def start_job(self, r, body):
        cmd = str(body.get("command") or "").strip()
        if not cmd:
            raise FsError("Пустая команда")
        shell, env = self.shell_env()
        proc = subprocess.Popen([shell, "-lc", cmd], cwd=r, env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        job = {"proc": proc, "root": str(r), "command": cmd, "out": bytearray(), "seen": 0, "stopped": False,
               "lock": threading.Lock()}

        def pump():
            for chunk in iter(lambda: proc.stdout.read1(65536), b""):
                with job["lock"]:
                    if len(job["out"]) < 4_000_000:
                        job["out"] += chunk
        threading.Thread(target=pump, daemon=True).start()
        self.job_count += 1
        jid = f"job{self.job_count}"
        self.jobs[jid] = job
        end = time.time() + 3
        while proc.poll() is None and time.time() < end:
            time.sleep(0.1)
        return self.job(r, {"job": jid})

    def job(self, r, body):
        jid = str(body.get("job") or "")
        job = self.jobs.get(jid)
        if not job or job["root"] != str(r):
            raise FsError(f"Фоновой команды {jid} нет")
        proc = job["proc"]
        if body.get("stop") and proc.poll() is None:
            job["stopped"] = True
            self.stop_tree(proc)
        end = time.time() + max(0, min(int(body.get("wait") or 0), 60))
        while proc.poll() is None and time.time() < end:
            time.sleep(0.2)
        if proc.poll() is not None:
            time.sleep(0.15)
        with job["lock"]:
            fresh = bytes(job["out"][job["seen"]:])
            job["seen"] = len(job["out"])
        out = {"job": jid, "command": job["command"], "running": proc.poll() is None, "stopped": job["stopped"],
               "output": self.clip(fresh.decode("utf-8", errors="replace"))}
        if proc.poll() is not None:
            out["code"] = proc.returncode
        return out

    @staticmethod
    def stop_tree(proc):
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except Exception:
            proc.terminate()
        try:
            proc.wait(timeout=3)
        except Exception:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except Exception:
                proc.kill()

    @staticmethod
    def pids_in(base):
        """pid процессов, чья рабочая папка внутри base (кроме самого сервера)."""
        inside = lambda p: p == base or p.startswith(base + "/")
        me, out = os.getpid(), []
        if Path("/proc/self/cwd").exists():   # Linux
            for d in os.listdir("/proc"):
                if d.isdigit() and int(d) != me:
                    try:
                        if inside(os.readlink(f"/proc/{d}/cwd")):
                            out.append(int(d))
                    except OSError:
                        pass
            return out
        try:   # Mac
            lsof = "/usr/sbin/lsof" if Path("/usr/sbin/lsof").exists() else "lsof"
            res = subprocess.run([lsof, "-n", "-d", "cwd", "-F", "pn"], capture_output=True, timeout=15)
        except Exception:
            return out
        pid = 0
        for line in res.stdout.decode("utf-8", errors="replace").splitlines():
            if line[:1] == "p":
                pid = int(line[1:]) if line[1:].isdigit() else 0
            elif line[:1] == "n" and pid and pid != me and inside(line[1:]):
                out.append(pid)
        return out

    def stop_left(self, base):
        """То, что пережило свою оболочку (cmd &, setsid, вывод в файл) и ещё работает в папке: SIGTERM, через 3 с — SIGKILL."""
        def send(sig):
            for pid in self.pids_in(base):
                try:
                    os.kill(pid, sig)
                except Exception:
                    pass
        if not self.pids_in(base):
            return
        send(signal.SIGTERM)
        end = time.time() + 3
        while time.time() < end and self.pids_in(base):
            time.sleep(0.2)
        send(signal.SIGKILL)

    def stop_all_jobs(self):
        for job in self.jobs.values():
            if job["proc"].poll() is None:
                self.stop_tree(job["proc"])

    def run(self, r, body):
        cmd = str(body.get("command") or "").strip()
        if not cmd:
            raise FsError("Пустая команда")
        timeout = max(5, min(int(body.get("timeout") or 120), 900))
        shell, env = self.shell_env()
        timed_out = False
        # своя группа процессов: по таймауту останавливаем и всё, что команда запустила
        proc = subprocess.Popen([shell, "-lc", cmd], cwd=r, env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
        self.running[id(proc)] = (str(r), proc)   # чтобы удаление копии архива могло её остановить
        try:
            data, _ = proc.communicate(timeout=timeout)
            code = proc.returncode
        except subprocess.TimeoutExpired:
            timed_out, code = True, -1
            self.stop_tree(proc)
            try:
                data, _ = proc.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                data = b""
        finally:
            self.running.pop(id(proc), None)
        text = (data or b"").decode("utf-8", errors="replace")
        if len(text) > MAX_OUTPUT:
            text = text[:MAX_OUTPUT // 3] + f"\n…[вывод сокращён: {len(text)} символов]…\n" + text[-MAX_OUTPUT * 2 // 3:]
        return {"code": code, "output": text, "timedOut": timed_out}

    @staticmethod
    def file_symbols(text):
        out = []
        for i, line in enumerate(text.split("\n")):
            if len(line) >= 400:
                continue
            for rx in SYMBOL_PATTERNS:
                m = rx.match(line)
                if m:
                    if m.group("n") not in SKIP_NAMES:
                        out.append(f"{m.group('n')}:{i + 1}")
                    break
            if len(out) >= 80:
                break
        return out

    def symbols(self, r, body):
        d = self.resolve(r, body.get("dir"))
        glob = str(body.get("glob") or "").strip()
        grx = self.glob_re(glob) if glob else None
        max_chars = max(2000, min(int(body.get("maxChars") or 30000), 120000))
        lines, chars, files, truncated = [], 0, 0, False
        for p, s in self.walk(d):
            if s > 600_000 or p.suffix.lower().lstrip(".") not in CODE_EXT:
                continue
            rp = self.rel(r, p)
            if not self.matches(grx, glob, rp):
                continue
            try:
                text = self.read_text(p)
            except Exception:
                continue
            files += 1
            syms = self.file_symbols(text)
            row = f"{rp} ({text.count(chr(10)) + 1} стр.)" + (": " + ", ".join(syms) if syms else "")
            if chars + len(row) > max_chars:
                truncated = True
                break
            chars += len(row) + 1
            lines.append(row)
        return {"map": "\n".join(lines), "files": files, "truncated": truncated}

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
