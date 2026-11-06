import AppKit
import WebKit

// Папка проекта, с которой работает модель: /api/fs/*.
// Модель видит только папки, которые пользователь сам выбрал через «Открыть папку».
// Те же маршруты есть в venice-chat/server.py — при изменениях правь оба файла.
final class Workspace {
    static let shared = Workspace()

    static let skipDirs: Set<String> = ["node_modules", ".git", ".svn", ".hg", "vendor", ".venv", "venv", "__pycache__",
        ".pytest_cache", ".mypy_cache", ".parcel-cache", ".turbo", ".cache", ".idea", ".vscode", ".gradle", "Pods",
        "DerivedData", ".next", ".nuxt", ".pnpm-store", ".worktrees", "dist", "build", "out", "coverage", ".build", "target"]
    static let memoryFiles = ["AGENTS.md", "CLAUDE.md", ".cursorrules", "README.md"]
    let maxFileBytes = 2 * 1024 * 1024
    let maxOutput = 60_000

    private let queue = DispatchQueue(label: "workspace", qos: .userInitiated, attributes: .concurrent)
    private let lock = NSLock()
    private var running: [ObjectIdentifier: Process] = [:]

    private var dataDir: URL { Backend.shared.dataDir }
    private var foldersURL: URL { dataDir.appendingPathComponent("folders.json") }
    private var backupsDir: URL { dataDir.appendingPathComponent("backups", isDirectory: true) }
    private var memoryDir: URL { dataDir.appendingPathComponent("memory", isDirectory: true) }
    private var workDir: URL { dataDir.appendingPathComponent("work", isDirectory: true) }
    private let foldersLock = NSLock()
    static let workSkip: Set<String> = ["node_modules", ".git", "__pycache__", ".venv", "venv", "Pods", ".gradle", "DerivedData", "jspm_packages"]   // ⊆ UNPACK_SKIP в archive-work.js
    private static let notWork = "Это можно только в рабочей копии архива"

    // MARK: разрешённые папки

    var allowed: [String] {
        get { ((try? JSONSerialization.jsonObject(with: Data(contentsOf: foldersURL))) as? [String]) ?? [] }
        set {
            if let d = try? JSONSerialization.data(withJSONObject: Array(Set(newValue)).sorted()) { try? d.write(to: foldersURL, options: .atomic) }
        }
    }

    func allow(_ path: String) {
        let p = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        foldersLock.lock(); defer { foldersLock.unlock() }
        if !allowed.contains(p) { allowed += [p] }
    }

    // для самотестов: убрать временную папку из разрешённых и стереть заметки о ней
    func forget(_ path: String) {
        foldersLock.lock()
        allowed = allowed.filter { $0 != path }
        foldersLock.unlock()
        try? FileManager.default.removeItem(at: memoryURL(URL(fileURLWithPath: path)))
    }

    struct FsError: Error { let message: String; init(_ m: String) { message = m } }

    /// Корень проекта: только из списка выбранных пользователем папок
    private func root(_ body: [String: Any]) throws -> URL {
        guard let r = body["root"] as? String, !r.isEmpty else { throw FsError("Папка проекта не выбрана") }
        let url = URL(fileURLWithPath: r).resolvingSymlinksInPath()
        guard allowed.contains(url.path) else { throw FsError("Нет доступа к папке \(r): подключите её к проекту заново") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { throw FsError("Папки \(r) больше нет") }
        return url
    }

    /// Путь внутри проекта; выйти за его пределы (../, ссылки) нельзя
    private func resolve(_ root: URL, _ rel: Any?) throws -> URL {
        var s = (rel as? String ?? "").trimmingCharacters(in: .whitespaces)
        if s.hasPrefix(root.path + "/") { s = String(s.dropFirst(root.path.count + 1)) }
        while s.hasPrefix("./") { s = String(s.dropFirst(2)) }
        if s.hasPrefix("/") { s = String(s.dropFirst()) }
        let url = (s.isEmpty || s == ".") ? root : root.appendingPathComponent(s).standardizedFileURL
        // ссылки внутри проекта разворачиваем, если файл есть; для нового файла проверяем папку
        let check = FileManager.default.fileExists(atPath: url.path) ? url.resolvingSymlinksInPath()
            : url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent)
        guard check.path == root.path || check.path.hasPrefix(root.path + "/") else { throw FsError("Путь \(s) ведёт за пределы папки проекта") }
        return url
    }

    private func rel(_ root: URL, _ url: URL) -> String {
        let p = url.standardizedFileURL.path
        return p == root.path ? "." : String(p.dropFirst(root.path.count + 1))
    }

    // MARK: маршруты

    func handle(_ t: WKURLSchemeTask, op: String, body data: Data) {
        let b = Backend.shared
        let body = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        if op == "pick" { return pick(t) }
        let id = ObjectIdentifier(t)
        queue.async { [self] in
            do {
                if op == "work" { let made = try makeWork(body); b.json(t, 200, made); return }
                let r = try root(body)
                if op == "get" { let data = try getFile(r, body); b.respond(t, 200, data, type: "application/octet-stream"); return }
                let out: [String: Any]
                switch op {
                case "info": out = info(r)
                case "list": out = try list(r, body)
                case "grep": out = try grep(r, body)
                case "read": out = try read(r, body)
                case "write": out = try write(r, body)
                case "edit": out = try edit(r, body)
                case "undo": out = try undo(r, body)
                case "run": out = body["background"] as? Bool == true ? try startJob(r, body) : try run(r, body, id: id)
                case "job": out = try jobStatus(r, body)
                case "memory": out = memory(r, body)
                case "symbols": out = try symbols(r, body)
                case "put": out = try putFiles(r, body)
                case "files": out = try listAll(r)
                case "drop": out = try dropWork(r)
                default: throw FsError("Нет такой операции: \(op)")
                }
                b.json(t, 200, out)
            } catch let e as FsError {
                b.json(t, 400, ["error": e.message])
            } catch {
                b.json(t, 400, ["error": error.localizedDescription])
            }
        }
    }

    /// Страница закрыла запрос («Стоп») — останавливаем запущенную команду
    func cancel(_ id: ObjectIdentifier) {
        lock.lock(); let p = running[id]; lock.unlock()
        if let p = p, p.isRunning { stopTree(p) }
    }

    private func pick(_ t: WKURLSchemeTask) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Открыть"
        panel.message = "Выберите папку проекта — модель сможет читать и (с вашего разрешения) менять файлы в ней"
        let finish: (NSApplication.ModalResponse) -> Void = { [self] resp in
            guard resp == .OK, let url = panel.url else { return Backend.shared.json(t, 200, ["cancelled": true]) }
            let path = url.resolvingSymlinksInPath().path
            allow(path)
            Backend.shared.json(t, 200, ["path": path, "name": url.lastPathComponent])
        }
        if let w = NSApp.mainWindow ?? NSApp.windows.first { panel.beginSheetModal(for: w, completionHandler: finish) }
        else { finish(panel.runModal()) }
    }

    // MARK: обход файлов

    private func walk(_ root: URL, under dir: URL, _ visit: (URL, Int) -> Bool) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]) else { return }
        for case let url as URL in en {
            let name = url.lastPathComponent
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                if Self.skipDirs.contains(name) || (name.hasPrefix(".") && name != ".github") { en.skipDescendants() }
                continue
            }
            if name == ".DS_Store" || v?.isSymbolicLink == true { continue }
            if !visit(url, v?.fileSize ?? 0) { break }
        }
    }

    /// Шаблон вроде src/**/*.ts или *.{js,css} → регулярное выражение
    static func globRegex(_ glob: String) -> NSRegularExpression? {
        var re = "", i = glob.startIndex, inBrace = false
        while i < glob.endIndex {
            let c = glob[i]
            let next = glob.index(after: i)
            switch c {
            case "*":
                if next < glob.endIndex && glob[next] == "*" {
                    let after = glob.index(after: next)
                    if after < glob.endIndex && glob[after] == "/" { re += "(?:.*/)?"; i = glob.index(after: after); continue }
                    re += ".*"; i = after; continue
                }
                re += "[^/]*"
            case "?": re += "[^/]"
            case "{": re += "(?:"; inBrace = true
            case "}": re += ")"; inBrace = false
            case ",": re += inBrace ? "|" : ","
            default: re += NSRegularExpression.escapedPattern(for: String(c))
            }
            i = next
        }
        return try? NSRegularExpression(pattern: "^" + re + "$", options: [.caseInsensitive])
    }

    private func matches(_ re: NSRegularExpression?, _ glob: String, _ path: String) -> Bool {
        guard let re = re else { return true }
        let target = glob.contains("/") ? path : (path as NSString).lastPathComponent
        return re.firstMatch(in: target, range: NSRange(target.startIndex..., in: target)) != nil
    }

    private func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        if data.prefix(8000).contains(0) { throw FsError("Это двоичный файл, прочитать его как текст нельзя") }
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .windowsCP1251) { return s }
        throw FsError("Не удалось распознать кодировку файла")
    }

    // MARK: операции

    private func info(_ r: URL) -> [String: Any] {
        var files = 0, bytes = 0
        var top: [String: Int] = [:]
        walk(r, under: r) { url, size in
            files += 1; bytes += size
            let first = rel(r, url).split(separator: "/").first.map(String.init) ?? ""
            top[first, default: 0] += 1
            return files < 200_000
        }
        var docs: [[String: String]] = []
        for name in Self.memoryFiles {
            let u = r.appendingPathComponent(name)
            if let s = try? readText(u) { docs.append(["name": name, "text": String(s.prefix(name == "README.md" ? 6_000 : 30_000))]) }
        }
        let entries = ((try? FileManager.default.contentsOfDirectory(atPath: r.path)) ?? []).sorted()
        return ["name": r.lastPathComponent, "path": r.path, "files": files, "bytes": bytes, "top": top, "entries": entries,
                "docs": docs, "notes": (try? String(contentsOf: memoryURL(r), encoding: .utf8)) ?? "",
                "git": FileManager.default.fileExists(atPath: r.appendingPathComponent(".git").path)]
    }

    private func list(_ r: URL, _ body: [String: Any]) throws -> [String: Any] {
        let dir = try resolve(r, body["dir"])
        let glob = (body["pattern"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let re = glob.isEmpty ? nil : Self.globRegex(glob)
        let limit = min(body["limit"] as? Int ?? 400, 2000)
        var rows: [String] = [], total = 0
        walk(r, under: dir) { url, size in
            let p = rel(r, url)
            let local = dir == r ? p : rel(dir, url)
            guard matches(re, glob, local) || matches(re, glob, p) else { return true }
            total += 1
            if rows.count < limit { rows.append("\(p)\t\(size)") }
            return true
        }
        return ["files": rows, "total": total]
    }

    private func grep(_ r: URL, _ body: [String: Any]) throws -> [String: Any] {
        let query = body["query"] as? String ?? ""
        guard !query.isEmpty else { throw FsError("Пустой запрос") }
        let isRegex = body["regex"] as? Bool ?? false
        let ignoreCase = body["ignore_case"] as? Bool ?? !isRegex
        let re: NSRegularExpression
        do { re = try NSRegularExpression(pattern: isRegex ? query : NSRegularExpression.escapedPattern(for: query), options: ignoreCase ? [.caseInsensitive] : []) }
        catch { throw FsError("Ошибка в регулярном выражении: \(error.localizedDescription)") }
        let dir = try resolve(r, body["path"])
        let glob = (body["glob"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let gre = glob.isEmpty ? nil : Self.globRegex(glob)
        let context = max(0, min(body["context"] as? Int ?? 0, 10))
        let limit = max(1, min(body["limit"] as? Int ?? 150, 500))
        var out: [String] = [], total = 0, filesHit = 0
        func visitOne(_ url: URL) {
            let p = rel(r, url)
            guard let text = try? readText(url) else { return }
            let lines = text.components(separatedBy: "\n")
            var hit = false
            var lastShown = -1
            for (i, line) in lines.enumerated() {
                guard re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil else { continue }
                total += 1; hit = true
                guard out.count < limit else { continue }
                if context > 0 {
                    let lo = max(0, i - context), hi = min(lines.count - 1, i + context)
                    if lastShown >= 0 && lo > lastShown + 1 { out.append("--") }
                    for j in max(lo, lastShown + 1)...hi { out.append("\(p):\(j + 1)\(j == i ? ":" : "-") \(String(lines[j].prefix(300)))") }
                    lastShown = hi
                } else {
                    out.append("\(p):\(i + 1): \(String(line.trimmingCharacters(in: .whitespaces).prefix(300)))")
                }
            }
            if hit { filesHit += 1 }
        }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
        if !isDir.boolValue { visitOne(dir) }
        else {
            walk(r, under: dir) { url, size in
                guard size <= maxFileBytes, matches(gre, glob, rel(r, url)) else { return true }
                visitOne(url)
                return true
            }
        }
        return ["lines": out, "total": total, "files": filesHit]
    }

    private func read(_ r: URL, _ body: [String: Any]) throws -> [String: Any] {
        let url = try resolve(r, body["path"])
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw FsError("Файла \(body["path"] as? String ?? "") нет") }
        if isDir.boolValue { throw FsError("Это папка — посмотри её через list_files") }
        let text = try readText(url)
        let lines = text.components(separatedBy: "\n")
        let from = max(1, body["offset"] as? Int ?? 1)
        let count = max(1, min(body["limit"] as? Int ?? 800, 3000))
        var out: [String] = [], chars = 0, last = from - 1
        if from <= lines.count {
            for i in (from - 1)..<min(lines.count, from - 1 + count) {
                let l = "\(i + 1)\t\(lines[i].count > 2000 ? String(lines[i].prefix(2000)) + "…" : lines[i])"
                chars += l.count
                if chars > 120_000 && !out.isEmpty { break }
                out.append(l); last = i + 1
            }
        }
        return ["path": rel(r, url), "text": out.joined(separator: "\n"), "from": from, "to": last, "total": lines.count, "version": version(url) ?? ""]
    }

    /// Отметка версии файла: время изменения (мкс) и размер. Другая — значит файл меняли
    private func version(_ url: URL) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path), let d = a[.modificationDate] as? Date else { return nil }
        return "\(Int64(d.timeIntervalSince1970 * 1_000_000))-\((a[.size] as? NSNumber)?.intValue ?? 0)"
    }

    /// Не даём править файл по устаревшей копии: expect — версия, которую модель видела при чтении
    private func checkFresh(_ r: URL, _ url: URL, _ body: [String: Any]) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if let exp = body["expect"] as? String, !exp.isEmpty, version(url) != exp {
            throw FsError("Файл \(rel(r, url)) изменился после того, как ты его прочитал (его поменял пользователь, команда или форматировщик). Правка НЕ применена. Перечитай нужное место через read_file и повтори правку по свежему тексту.")
        }
        if body["mustBeNew"] as? Bool == true {
            throw FsError("Файл \(rel(r, url)) уже есть, а ты его не читал. Прочитай его через read_file и правь через edit_file — иначе можно затереть чужие изменения.")
        }
    }

    /// Как выглядит место правки теперь: несколько строк вокруг, с номерами
    static func snippet(_ text: String, line: Int, new: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let lo = max(1, line - 3)
        let hi = min(lines.count, line + new.components(separatedBy: "\n").count - 1 + 3, lo + 39)
        guard lo <= hi else { return "" }
        return (lo...hi).map { "\($0)\t\(String(lines[$0 - 1].prefix(300)))" }.joined(separator: "\n")
    }

    /// Копия файла до правки — для кнопки «Отменить»
    private func backup(_ r: URL, _ url: URL) throws -> String {
        let id = "\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6))"
        let dir = backupsDir.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let existed = FileManager.default.fileExists(atPath: url.path)
        if existed { try FileManager.default.copyItem(at: url, to: dir.appendingPathComponent("file")) }
        let meta: [String: Any] = ["root": r.path, "path": rel(r, url), "existed": existed]
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
        return id
    }

    private func write(_ r: URL, _ body: [String: Any]) throws -> [String: Any] {
        let url = try resolve(r, body["path"])
        guard url.path != r.path else { throw FsError("Укажи путь к файлу") }
        let content = body["content"] as? String ?? ""
        try checkFresh(r, url, body)
        let old = FileManager.default.fileExists(atPath: url.path) ? (try? readText(url)) : nil
        let id = try backup(r, url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return ["backup": id, "created": old == nil, "old": old ?? "", "path": rel(r, url), "version": version(url) ?? ""]
    }

    private func edit(_ r: URL, _ body: [String: Any]) throws -> [String: Any] {
        let url = try resolve(r, body["path"])
        guard FileManager.default.fileExists(atPath: url.path) else { throw FsError("Файла \(body["path"] as? String ?? "") нет — для нового файла используй write_file") }
        let oldText = body["old"] as? String ?? "", newText = body["new"] as? String ?? ""
        guard !oldText.isEmpty else { throw FsError("Пустой old — укажи точный кусок текста, который нужно заменить") }
        try checkFresh(r, url, body)
        let text = try readText(url)
        let n = text.components(separatedBy: oldText).count - 1
        if n == 0 { throw FsError("Такого куска в файле нет. Перечитай файл через read_file и скопируй текст точно, с отступами") }
        let all = body["all"] as? Bool ?? false
        if n > 1 && !all { throw FsError("Кусок встречается \(n) раз. Добавь соседние строки, чтобы он стал уникальным, или передай all=true") }
        let line = text[..<text.range(of: oldText)!.lowerBound].components(separatedBy: "\n").count
        if body["dry"] as? Bool == true { return ["line": line, "count": n, "path": rel(r, url)] }
        let updated: String
        if all { updated = text.replacingOccurrences(of: oldText, with: newText) }
        else { let range = text.range(of: oldText)!; updated = text.replacingCharacters(in: range, with: newText) }
        let id = try backup(r, url)
        try updated.write(to: url, atomically: true, encoding: .utf8)
        return ["backup": id, "replaced": all ? n : 1, "line": line, "path": rel(r, url), "version": version(url) ?? "",
                "snippet": Self.snippet(updated, line: line, new: newText)]
    }

    private func undo(_ r: URL, _ body: [String: Any]) throws -> [String: Any] {
        let id = (body["backup"] as? String ?? "").replacingOccurrences(of: "/", with: "")
        let dir = backupsDir.appendingPathComponent(id, isDirectory: true)
        guard !id.isEmpty, let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("meta.json")))) as? [String: Any],
              meta["root"] as? String == r.path else { throw FsError("Копия для отмены не найдена") }
        let url = try resolve(r, meta["path"])
        if meta["existed"] as? Bool == true {
            let data = try Data(contentsOf: dir.appendingPathComponent("file"))
            try data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        return ["ok": true, "path": meta["path"] as? String ?? ""]
    }

    private func run(_ r: URL, _ body: [String: Any], id: ObjectIdentifier) throws -> [String: Any] {
        let command = body["command"] as? String ?? ""
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { throw FsError("Пустая команда") }
        let timeout = Double(max(5, min(body["timeout"] as? Int ?? 120, 900)))
        let p = shellProcess(r, command)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        var output = Data()
        let outLock = NSLock()
        let cap = 400_000
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            outLock.lock(); if output.count < cap { output.append(d) }; outLock.unlock()
        }
        try p.run()
        lock.lock(); running[id] = p; lock.unlock()
        var timedOut = false
        let killer = DispatchWorkItem { [self] in if p.isRunning { timedOut = true; stopTree(p) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        p.waitUntilExit()
        killer.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        // дочитываем вывод, но не дольше секунды: если команда оставила что-то работать (cmd &), оно держит канал открытым
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let rest = pipe.fileHandleForReading.readDataToEndOfFile()
            outLock.lock(); if output.count < cap { output.append(rest) }; outLock.unlock()
            drained.signal()
        }
        _ = drained.wait(timeout: .now() + 1)
        outLock.lock(); let all = output; outLock.unlock()
        lock.lock(); running.removeValue(forKey: id); lock.unlock()
        var text = String(decoding: all, as: UTF8.self)
        if text.count > maxOutput {
            text = String(text.prefix(maxOutput / 3)) + "\n…[вывод сокращён: \(text.count) символов]…\n" + String(text.suffix(maxOutput * 2 / 3))
        }
        return ["code": p.terminationStatus, "output": text, "timedOut": timedOut]
    }

    private func shellProcess(_ r: URL, _ command: String) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        p.currentDirectoryURL = r
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        env["TERM"] = "dumb"; env["NO_COLOR"] = "1"; env["CI"] = "1"
        p.environment = env
        return p
    }

    private func clip(_ text: String) -> String {
        text.count > maxOutput ? String(text.prefix(maxOutput / 3)) + "\n…[вывод сокращён: \(text.count) символов]…\n" + String(text.suffix(maxOutput * 2 / 3)) : text
    }

    // MARK: фоновые команды — долгая установка или сборка идёт, а модель тем временем читает код

    private final class Job {
        let p: Process, root: String, command: String
        let lock = NSLock()
        var out = Data(), seen = 0, stopped = false
        init(_ p: Process, root: String, command: String) { self.p = p; self.root = root; self.command = command }
    }
    private var jobs: [String: Job] = [:]
    private var jobCount = 0

    private func startJob(_ r: URL, _ body: [String: Any]) throws -> [String: Any] {
        let command = body["command"] as? String ?? ""
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { throw FsError("Пустая команда") }
        let p = shellProcess(r, command)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        let job = Job(p, root: r.path, command: command)
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            job.lock.lock(); if job.out.count < 4_000_000 { job.out.append(d) }; job.lock.unlock()
        }
        try p.run()
        lock.lock(); jobCount += 1; let id = "job\(jobCount)"; jobs[id] = job; lock.unlock()
        // пару секунд ждём: короткая команда успеет закончиться, у долгой будет видно начало
        let until = Date().addingTimeInterval(3)
        while p.isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.1) }
        return try jobStatus(r, ["job": id])
    }

    private func jobStatus(_ r: URL, _ body: [String: Any]) throws -> [String: Any] {
        let id = body["job"] as? String ?? ""
        lock.lock(); let found = jobs[id]; lock.unlock()
        guard let job = found, job.root == r.path else { throw FsError("Фоновой команды \(id) нет") }
        if body["stop"] as? Bool == true && job.p.isRunning {
            job.stopped = true
            stopTree(job.p)
            let until = Date().addingTimeInterval(3)
            while job.p.isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.1) }
        }
        let until = Date().addingTimeInterval(Double(max(0, min(body["wait"] as? Int ?? 0, 60))))
        while job.p.isRunning && Date() < until { Thread.sleep(forTimeInterval: 0.2) }
        if !job.p.isRunning { Thread.sleep(forTimeInterval: 0.15) }   // дочитать последние строки
        job.lock.lock(); let fresh = job.out.subdata(in: job.seen..<job.out.count); job.seen = job.out.count; job.lock.unlock()
        var out: [String: Any] = ["job": id, "command": job.command, "running": job.p.isRunning, "stopped": job.stopped,
                                  "output": clip(String(decoding: fresh, as: UTF8.self))]
        if !job.p.isRunning { out["code"] = job.p.terminationStatus }
        return out
    }

    /// Останавливает команду вместе с запущенными ею процессами (npm, сервер и т. п.); возвращает pid найденных потомков
    @discardableResult
    private func stopTree(_ p: Process, _ sig: Int32 = SIGTERM) -> [Int32] {
        func kids(_ pid: Int32) -> [Int32] {
            let q = Process(); q.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); q.arguments = ["-P", String(pid)]
            let pipe = Pipe(); q.standardOutput = pipe; q.standardError = FileHandle.nullDevice
            guard (try? q.run()) != nil else { return [] }
            q.waitUntilExit()
            return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").compactMap { Int32($0) }
        }
        var all: [Int32] = [], queue = [p.processIdentifier]
        while let pid = queue.popLast(), all.count < 500 { let k = kids(pid); all += k; queue += k }
        for pid in all.reversed() { kill(pid, sig) }
        if sig == SIGTERM { p.terminate() } else if p.isRunning { kill(p.processIdentifier, sig) }
        if sig == SIGTERM {   // не остановилось за 3 секунды (не слушает SIGTERM) — жёстко, как в Python-версии
            let pids = all
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
        }
        return all
    }

    /// pid процессов, чья рабочая папка внутри base (по lsof, кроме самого приложения): так находится и то,
    /// что пережило свою оболочку (cmd &, вывод в файл) — его уже не видно через pgrep -P
    private func pidsIn(_ base: String) -> [Int32] {
        let q = Process(); q.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof"); q.arguments = ["-n", "-d", "cwd", "-F", "pn"]
        let pipe = Pipe(); q.standardOutput = pipe; q.standardError = FileHandle.nullDevice
        guard (try? q.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()   // до waitUntilExit: вывод больше буфера канала
        q.waitUntilExit()
        let me = getpid()
        var out: [Int32] = [], pid: Int32 = 0
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) ?? 0 }
            else if line.hasPrefix("n"), pid > 0, pid != me {
                let path = String(line.dropFirst())
                if path == base || path.hasPrefix(base + "/") { out.append(pid) }
            }
        }
        return out
    }

    /// Выход из приложения — фоновые команды не оставляем
    func stopAllJobs() {
        lock.lock(); let list = jobs.values.filter { $0.p.isRunning }; lock.unlock()
        for job in list { stopTree(job.p) }
    }

    // MARK: карта кода — функции, классы и типы по файлам (как repo map у помощников для кода)

    static let symbolPatterns: [NSRegularExpression] = [
        #"^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\*?\s+(?<n>[\w$]+)"#,
        #"^\s*(?:export\s+)?(?:default\s+)?(?:abstract\s+)?class\s+(?<n>[\w$]+)"#,
        #"^\s*(?:export\s+)?(?:const|let|var)\s+(?<n>[\w$]+)\s*=\s*(?:async\s+)?(?:function|\([^)]*\)\s*=>|[\w$]+\s*=>)"#,
        #"^\s*(?:export\s+)?(?:declare\s+)?(?:interface|type|enum)\s+(?<n>[\w$]+)"#,
        #"^\s*(?:async\s+)?def\s+(?<n>[\w?!]+)"#,
        #"^\s*(?:class|module)\s+(?<n>[\w:]+)"#,
        #"^\s*(?:(?:public|private|fileprivate|internal|open|static|final|override|mutating|nonisolated|@\w+)\s+)*(?:func|struct|enum|protocol|extension|actor)\s+(?<n>\w+)"#,
        #"^func\s+(?:\([^)]*\)\s*)?(?<n>\w+)"#,
        #"^type\s+(?<n>\w+)"#,
        #"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:fn|struct|enum|trait|impl|mod)\s+(?<n>\w+)"#,
        #"^\s*(?:(?:public|private|protected|static|final|abstract|internal|open|data|sealed|override)\s+)*(?:interface|object|fun|record)\s+(?<n>\w+)"#,
        #"^\s*(?:(?:public|private|protected|static|final|abstract)\s+)*function\s+(?<n>\w+)"#,
        #"^\s{2,4}(?:static\s+)?(?:async\s+)?(?:get\s+|set\s+)?(?<n>[A-Za-z_$][\w$]*)\s*\([^)]*\)\s*\{\s*$"#
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.anchorsMatchLines]) }
    static let codeExt: Set<String> = ["js", "mjs", "cjs", "jsx", "ts", "tsx", "vue", "svelte", "py", "rb", "go", "rs", "swift", "kt", "kts", "java", "cs", "php", "scala", "dart", "lua", "m", "mm"]
    static let skipNames: Set<String> = ["if", "for", "while", "switch", "catch", "function", "return", "else", "do", "try", "with", "elif", "super", "await", "new", "typeof"]

    static func fileSymbols(_ text: String) -> [String] {
        var out: [String] = []
        for (i, line) in text.components(separatedBy: "\n").enumerated() where line.count < 400 {
            let range = NSRange(line.startIndex..., in: line)
            for re in symbolPatterns {
                guard let m = re.firstMatch(in: line, range: range), let r = Range(m.range(withName: "n"), in: line) else { continue }
                let name = String(line[r])
                if !skipNames.contains(name) { out.append("\(name):\(i + 1)") }
                break
            }
            if out.count >= 80 { break }
        }
        return out
    }

    private func symbols(_ r: URL, _ body: [String: Any]) throws -> [String: Any] {
        let dir = try resolve(r, body["dir"])
        let glob = (body["glob"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let gre = glob.isEmpty ? nil : Self.globRegex(glob)
        let maxChars = max(2000, min(body["maxChars"] as? Int ?? 30_000, 120_000))
        var lines: [String] = [], chars = 0, files = 0, truncated = false
        walk(r, under: dir) { url, size in
            guard size <= 600_000, Self.codeExt.contains(url.pathExtension.lowercased()) else { return true }
            let p = rel(r, url)
            guard matches(gre, glob, p), let text = try? readText(url) else { return true }
            files += 1
            let syms = Self.fileSymbols(text)
            let row = "\(p) (\(text.components(separatedBy: "\n").count) стр.)" + (syms.isEmpty ? "" : ": " + syms.joined(separator: ", "))
            if chars + row.count > maxChars { truncated = true; return false }
            chars += row.count + 1
            lines.append(row)
            return true
        }
        return ["map": lines.joined(separator: "\n"), "files": files, "truncated": truncated]
    }

    // MARK: рабочие копии архивов (/api/fs/work|put|files|get|drop) — те же операции в workspace.py

    /// Папка одной копии: <данные>/work/<чат>/<метка>. Новые операции работают только внутри неё
    private func workBase(_ r: URL) throws -> String {
        let work = workDir.resolvingSymlinksInPath().path + "/"
        guard r.path.hasPrefix(work) else { throw FsError(Self.notWork) }
        let rest = r.path.dropFirst(work.count).split(separator: "/")
        guard rest.count >= 2 else { throw FsError(Self.notWork) }
        return work + String(rest[0]) + "/" + String(rest[1])
    }

    /// Новая рабочая копия: <данные>/work/<чат>/<время-случайное>/<имя латиницей>
    private func makeWork(_ body: [String: Any]) throws -> [String: Any] {
        let chat = body["chat"] as? String ?? ""
        guard chat.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else { throw FsError("Неверный id чата") }
        var name = (body["name"] as? String ?? "").replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
        name = String(name.trimmingCharacters(in: CharacterSet(charactersIn: ".-")).prefix(60))
        if name.isEmpty { name = "archive" }
        let stamp = "\(Int64(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(6).lowercased())"
        let base = workDir.appendingPathComponent(chat, isDirectory: true).appendingPathComponent(stamp, isDirectory: true)
        let root = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        allow(base.path)
        allow(root.path)
        return ["base": base.resolvingSymlinksInPath().path, "root": root.resolvingSymlinksInPath().path]
    }

    /// Запись файлов в копию: data — base64; append — дописать в конец (большие файлы идут частями)
    private func putFiles(_ r: URL, _ body: [String: Any]) throws -> [String: Any] {
        _ = try workBase(r)
        let files = body["files"] as? [[String: Any]] ?? []
        for f in files {
            let path = f["path"] as? String ?? ""
            let url = try resolve(r, path)
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard url.path != r.path, v?.isDirectory != true, v?.isSymbolicLink != true else { throw FsError("Нельзя записать \(path)") }
            guard let data = Data(base64Encoded: f["data"] as? String ?? "") else { throw FsError("Повреждённые данные файла") }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if f["append"] as? Bool == true, FileManager.default.fileExists(atPath: url.path) {
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                _ = try h.seekToEnd()
                try h.write(contentsOf: data)
            } else {
                try data.write(to: url)
            }
            let mode = f["x"] as? Bool == true ? 0o755 : 0o644
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        return ["written": files.count]
    }

    /// Все файлы копии с версиями — по ним приложение понимает, что изменилось. Без папок зависимостей и ссылок
    private func listAll(_ r: URL) throws -> [String: Any] {
        _ = try workBase(r)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        // без .skipsPackageDescendants и со скрытыми файлами: иначе файлы из App.xcodeproj или .htaccess сочтутся удалёнными
        guard let en = FileManager.default.enumerator(at: r, includingPropertiesForKeys: keys, options: []) else { return ["files": [[String: Any]]()] }
        var out: [[String: Any]] = []
        for case let url as URL in en {
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isSymbolicLink == true { continue }
            if v?.isDirectory == true {
                if Self.workSkip.contains(url.lastPathComponent) { en.skipDescendants() }
                continue
            }
            guard v?.isRegularFile == true, let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { continue }
            let perm = (a[.posixPermissions] as? NSNumber)?.intValue ?? 0
            out.append(["path": rel(r, url), "size": (a[.size] as? NSNumber)?.intValue ?? 0, "version": version(url) ?? "", "x": (perm & 0o111) != 0])
            if out.count > 100_000 { throw FsError("В рабочей папке больше 100 000 файлов — собрать архив нельзя") }
        }
        return ["files": out]
    }

    private func getFile(_ r: URL, _ body: [String: Any]) throws -> Data {
        _ = try workBase(r)
        let path = body["path"] as? String ?? ""
        let url = try resolve(r, path)
        let v = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard v?.isRegularFile == true, v?.isSymbolicLink != true else { throw FsError("Файла \(path) нет") }
        return try Data(contentsOf: url)
    }

    private func dropWork(_ r: URL) throws -> [String: Any] {
        let base = try workBase(r)
        forgetTree(base)
        return ["ok": true]
    }

    /// Чат удалён — стираем его рабочие копии (вызывает Backend при DELETE /api/chats/<id>)
    func dropChatWork(_ chat: String) {
        guard chat.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else { return }
        let dir = workDir.appendingPathComponent(chat, isDirectory: true)
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: dir.path)) != nil {
            try? FileManager.default.removeItem(atPath: dir.path)   // ссылку убираем, а не то, куда она ведёт
            return
        }
        guard FileManager.default.fileExists(atPath: dir.path) else { return }
        forgetTree(dir.resolvingSymlinksInPath().path)
    }

    /// Остановить запущенное в копии, убрать её (и всё внутри) из разрешённых и стереть с диска
    private func forgetTree(_ base: String) {
        let inside = { (p: String) -> Bool in p == base || p.hasPrefix(base + "/") }
        var procs: [Process] = []
        lock.lock()
        for job in jobs.values where job.p.isRunning && inside(job.root) { job.stopped = true; procs.append(job.p) }
        for p in running.values where p.isRunning && inside(p.currentDirectoryURL?.path ?? "") { procs.append(p) }
        lock.unlock()
        var pids: [Int32] = []
        for p in procs { pids += stopTree(p) }   // иначе команда (сборка, сервер) пересоздаст файлы в стёртой папке
        // и то, что пережило свою оболочку и ещё работает в копии
        let left = pidsIn(base).filter { !pids.contains($0) }
        for pid in left { kill(pid, SIGTERM) }
        pids += left
        let alive = { (pid: Int32) -> Bool in kill(pid, 0) == 0 }
        let until = Date().addingTimeInterval(3)
        while (procs.contains(where: { $0.isRunning }) || pids.contains(where: alive)) && Date() < until { Thread.sleep(forTimeInterval: 0.1) }
        // не остановилось за 3 секунды (не слушает SIGTERM) — жёстко; и то, что появилось за это время
        for p in procs where p.isRunning { stopTree(p, SIGKILL) }
        for pid in pids where alive(pid) { kill(pid, SIGKILL) }
        for pid in pidsIn(base) { kill(pid, SIGKILL) }
        foldersLock.lock()
        allowed = allowed.filter { $0 != base && !$0.hasPrefix(base + "/") }
        foldersLock.unlock()
        try? FileManager.default.removeItem(atPath: base)
    }

    // Заметки модели о проекте — хранятся у приложения, в папку пользователя не пишутся
    private func memoryURL(_ r: URL) -> URL {
        let safe = r.path.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return memoryDir.appendingPathComponent(String(safe.suffix(150)) + ".md")
    }

    private func memory(_ r: URL, _ body: [String: Any]) -> [String: Any] {
        let url = memoryURL(r)
        try? FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if let replace = body["replace"] as? String { text = replace }
        if let add = body["add"] as? String, !add.isEmpty { text += (text.isEmpty || text.hasSuffix("\n") ? "" : "\n") + "- " + add.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" }
        if body["add"] != nil || body["replace"] != nil { try? String(text.suffix(40_000)).write(to: url, atomically: true, encoding: .utf8) }
        return ["notes": text]
    }
}
