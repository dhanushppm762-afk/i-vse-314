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

    // MARK: разрешённые папки

    var allowed: [String] {
        get { ((try? JSONSerialization.jsonObject(with: Data(contentsOf: foldersURL))) as? [String]) ?? [] }
        set {
            if let d = try? JSONSerialization.data(withJSONObject: Array(Set(newValue)).sorted()) { try? d.write(to: foldersURL, options: .atomic) }
        }
    }

    func allow(_ path: String) {
        let p = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if !allowed.contains(p) { allowed += [p] }
    }

    // для самотестов: убрать временную папку из разрешённых и стереть заметки о ней
    func forget(_ path: String) {
        allowed = allowed.filter { $0 != path }
        try? FileManager.default.removeItem(at: memoryURL(URL(fileURLWithPath: path)))
    }

    struct FsError: Error { let message: String; init(_ m: String) { message = m } }

    /// Корень проекта: только из списка выбранных пользователем папок
    private func root(_ body: [String: Any]) throws -> URL {
        guard let r = body["root"] as? String, !r.isEmpty else { throw FsError("Папка проекта не выбрана") }
        let url = URL(fileURLWithPath: r).resolvingSymlinksInPath()
        guard allowed.contains(url.path) else { throw FsError("Нет доступа к папке \(r): выберите её кнопкой «Папка»") }
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
                let r = try root(body)
                let out: [String: Any]
                switch op {
                case "info": out = info(r)
                case "list": out = try list(r, body)
                case "grep": out = try grep(r, body)
                case "read": out = try read(r, body)
                case "write": out = try write(r, body)
                case "edit": out = try edit(r, body)
                case "undo": out = try undo(r, body)
                case "run": out = try run(r, body, id: id)
                case "memory": out = memory(r, body)
                case "symbols": out = try symbols(r, body)
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
        if let p = p, p.isRunning { p.terminate() }
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
        return ["path": rel(r, url), "text": out.joined(separator: "\n"), "from": from, "to": last, "total": lines.count]
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
        let old = FileManager.default.fileExists(atPath: url.path) ? (try? readText(url)) : nil
        let id = try backup(r, url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return ["backup": id, "created": old == nil, "old": old ?? "", "path": rel(r, url)]
    }

    private func edit(_ r: URL, _ body: [String: Any]) throws -> [String: Any] {
        let url = try resolve(r, body["path"])
        guard FileManager.default.fileExists(atPath: url.path) else { throw FsError("Файла \(body["path"] as? String ?? "") нет — для нового файла используй write_file") }
        let oldText = body["old"] as? String ?? "", newText = body["new"] as? String ?? ""
        guard !oldText.isEmpty else { throw FsError("Пустой old — укажи точный кусок текста, который нужно заменить") }
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
        return ["backup": id, "replaced": all ? n : 1, "line": line, "path": rel(r, url)]
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
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", command]
        p.currentDirectoryURL = r
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        env["TERM"] = "dumb"; env["NO_COLOR"] = "1"; env["CI"] = "1"
        p.environment = env
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
        let killer = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        p.waitUntilExit()
        killer.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        outLock.lock(); if output.count < cap { output.append(rest) }; let all = output; outLock.unlock()
        lock.lock(); running.removeValue(forKey: id); lock.unlock()
        var text = String(decoding: all, as: UTF8.self)
        if text.count > maxOutput {
            text = String(text.prefix(maxOutput / 3)) + "\n…[вывод сокращён: \(text.count) символов]…\n" + String(text.suffix(maxOutput * 2 / 3))
        }
        return ["code": p.terminationStatus, "output": text, "timedOut": timedOut]
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
