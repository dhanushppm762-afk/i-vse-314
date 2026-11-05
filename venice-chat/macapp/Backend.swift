import Foundation
import WebKit

// «Сервер» внутри приложения: страница грузится с venice://app/, а запросы /api/* обрабатываются здесь.
// Маршруты те же, что в venice-chat/server.py — при изменениях правь оба файла.
final class Backend: NSObject, WKURLSchemeHandler, URLSessionDataDelegate {
    static let shared = Backend()

    let apiBase = "https://api.venice.ai/api/v1"
    let defaultModel = "deepseek-v4-1-flash-1017-uncensored"
    let fetchLimit = 80 * 1024 * 1024

    let dataDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VeniceChat", isDirectory: true)
        for sub in ["", "chats", "projects"] {
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        return dir
    }()
    let staticDir = Bundle.main.resourceURL!.appendingPathComponent("static", isDirectory: true)

    // Все ответы Venice приходят на главную очередь — без гонок за общими словарями
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 3600
        return URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
    }()
    private lazy var fetchSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        return URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
    }()

    private final class Job {
        let task: WKURLSchemeTask
        let isFetch: Bool
        var response: HTTPURLResponse?
        var streaming = false
        var body = Data()
        init(task: WKURLSchemeTask, isFetch: Bool) { self.task = task; self.isFetch = isFetch }
    }
    private var jobs: [Int: Job] = [:]                     // URLSessionTask.taskIdentifier → запрос страницы
    private var live: [ObjectIdentifier: URLSessionTask] = [:]
    private var stopped = Set<ObjectIdentifier>()
    private var modelsCache: [String: (Date, Any)] = [:]
    private let fileLock = NSLock()

    // MARK: ключ

    private var configURL: URL { dataDir.appendingPathComponent("config.json") }

    private func readConfig() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(contentsOf: configURL))) as? [String: Any] ?? [:]
    }

    private func writeConfig(_ cfg: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted]) else { return }
        try? data.write(to: configURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }

    /// Ключ, вшитый в сборку. Обновления с GitHub приходят без ключа, поэтому при первом запуске
    /// он копируется в config.json («builtinKey») и переживает обновление.
    var builtinKey: String {
        let bundled = (try? String(contentsOf: Bundle.main.url(forResource: "key", withExtension: "txt") ?? URL(fileURLWithPath: "/nonexistent"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var cfg = readConfig()
        if !bundled.isEmpty {
            if cfg["builtinKey"] as? String != bundled { cfg["builtinKey"] = bundled; writeConfig(cfg) }
            return bundled
        }
        return cfg["builtinKey"] as? String ?? ""
    }
    var customKey: String { (readConfig()["key"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    var apiKey: String { customKey.isEmpty ? builtinKey : customKey }

    private func masked(_ k: String) -> String {
        guard k.count > 10 else { return k.isEmpty ? "" : "••••" }
        return String(k.prefix(6)) + "…" + String(k.suffix(4))
    }

    // MARK: WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let req = urlSchemeTask.request
        guard let url = req.url else { return fail(urlSchemeTask, 400, "Пустой адрес") }
        let path = url.path.isEmpty ? "/" : url.path
        let method = (req.httpMethod ?? "GET").uppercased()
        if path.hasPrefix("/api/") {
            route(urlSchemeTask, method: method, path: path, query: url.query ?? "", body: Self.body(of: req))
        } else {
            serveStatic(urlSchemeTask, path: path)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        stopped.insert(id)
        live.removeValue(forKey: id)?.cancel()
        Workspace.shared.cancel(id)
    }

    private static func body(of req: URLRequest) -> Data {
        if let b = req.httpBody { return b }
        guard let stream = req.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }

    // MARK: ответы странице

    private func isStopped(_ t: WKURLSchemeTask) -> Bool { stopped.contains(ObjectIdentifier(t)) }

    func respond(_ t: WKURLSchemeTask, _ status: Int, _ data: Data, type: String = "application/json; charset=utf-8", headers: [String: String] = [:]) {
        let send = { [self] in
            guard !isStopped(t) else { return }
            var h = headers
            h["Content-Type"] = type
            h["Content-Length"] = String(data.count)
            h["Cache-Control"] = "no-cache"
            t.didReceive(HTTPURLResponse(url: t.request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: h)!)
            t.didReceive(data)
            t.didFinish()
            finished(t)
        }
        Thread.isMainThread ? send() : DispatchQueue.main.async(execute: send)
    }

    func json(_ t: WKURLSchemeTask, _ status: Int, _ obj: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        respond(t, status, data)
    }

    func fail(_ t: WKURLSchemeTask, _ status: Int, _ message: String) { json(t, status, ["error": message]) }

    private func finished(_ t: WKURLSchemeTask) {
        let id = ObjectIdentifier(t)
        stopped.remove(id)
        live.removeValue(forKey: id)
    }

    // MARK: статика

    private func serveStatic(_ t: WKURLSchemeTask, path: String) {
        let rel = path == "/" ? "index.html" : String(path.dropFirst()).removingPercentEncoding ?? ""
        let file = staticDir.appendingPathComponent(rel).standardizedFileURL
        guard file.path.hasPrefix(staticDir.standardizedFileURL.path + "/"), let data = try? Data(contentsOf: file) else {
            return fail(t, 404, "not found")
        }
        let types = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8", "css": "text/css; charset=utf-8",
                     "svg": "image/svg+xml", "png": "image/png", "json": "application/json", "wav": "audio/wav"]
        respond(t, 200, data, type: types[file.pathExtension.lowercased()] ?? "application/octet-stream")
    }

    // MARK: маршруты

    private func route(_ t: WKURLSchemeTask, method: String, path: String, query: String, body: Data) {
        let parts = path.split(separator: "/").map(String.init)   // ["api", ...]
        switch (method, parts.dropFirst().first ?? "") {
        case ("GET", "config"):
            json(t, 200, ["model": defaultModel, "app": true, "version": Updater.currentVersion])
        case ("GET", "models"):
            let type = URLComponents(string: "?" + query)?.queryItems?.first(where: { $0.name == "type" })?.value ?? "text"
            models(t, type: type)
        case ("POST", "chat"):
            chat(t, body: body)
        case ("POST", "image") where parts.count == 3 && ["generate", "edit", "multi-edit", "upscale"].contains(parts[2]):
            proxy(t, path: "/image/" + parts[2], body: body)
        case ("POST", "fetch"):
            fetchURL(t, body: body)
        case (_, "usage"):
            usage(t, method: method, body: body)
        case ("POST", "balance"):
            balance(t)
        case (_, "key"):
            key(t, method: method, body: body)
        case (_, "chats"), (_, "projects"):
            store(t, method: method, folder: parts[1], id: parts.count > 2 ? parts[2].removingPercentEncoding : nil, body: body)
        case ("POST", "fs") where parts.count == 3:
            Workspace.shared.handle(t, op: parts[2], body: body)
        case (_, "update"):
            Updater.shared.handleAPI(t, method: method, body: body)
        default:
            fail(t, 404, "Нет такого маршрута")
        }
    }

    // MARK: Venice

    private func veniceRequest(_ path: String, method: String = "POST", body: Data? = nil, key: String? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: apiBase + path)!)
        r.httpMethod = method
        r.httpBody = body
        r.setValue("Bearer \(key ?? apiKey)", forHTTPHeaderField: "Authorization")
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    private func start(_ t: WKURLSchemeTask, _ request: URLRequest, fetch: Bool = false) {
        guard !isStopped(t) else { return finished(t) }
        let task = (fetch ? fetchSession : session).dataTask(with: request)
        jobs[task.taskIdentifier] = Job(task: t, isFetch: fetch)
        live[ObjectIdentifier(t)] = task
        task.resume()
    }

    private func chat(_ t: WKURLSchemeTask, body: Data) {
        guard !apiKey.isEmpty else { return fail(t, 401, "Не указан API-ключ Venice. Откройте Настройки.") }
        guard var payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return fail(t, 400, "bad json") }
        if payload["model"] == nil { payload["model"] = defaultModel }
        let stream = payload["stream"] as? Bool ?? true
        payload["stream"] = stream
        if stream && payload["stream_options"] == nil { payload["stream_options"] = ["include_usage": true] }
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? body
        start(t, veniceRequest("/chat/completions", body: data))
    }

    private func proxy(_ t: WKURLSchemeTask, path: String, body: Data) {
        guard !apiKey.isEmpty else { return fail(t, 401, "Не указан API-ключ Venice. Откройте Настройки.") }
        start(t, veniceRequest(path, body: body))
    }

    private func models(_ t: WKURLSchemeTask, type: String) {
        guard ["text", "image", "inpaint", "upscale"].contains(type) else { return fail(t, 400, "Неизвестный тип моделей") }
        if let (at, list) = modelsCache[type], Date().timeIntervalSince(at) < 600 { return json(t, 200, list) }
        var req = veniceRequest("/models?type=\(type)", method: "GET")
        if apiKey.isEmpty { req.setValue(nil, forHTTPHeaderField: "Authorization") }
        URLSession.shared.dataTask(with: req) { [self] data, resp, err in
            DispatchQueue.main.async { [self] in
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let items = root["data"] as? [[String: Any]] else {
                    return fail(t, 502, err.map { "Нет связи с Venice: \($0.localizedDescription)" } ?? "Не удалось получить список моделей")
                }
                let list = items.compactMap { Self.normalize($0, type: type) }
                modelsCache[type] = (Date(), list)
                json(t, 200, list)
            }
        }.resume()
    }

    private static func usd(_ v: Any?) -> Double? { (v as? [String: Any])?["usd"] as? Double }

    private static func normalize(_ m: [String: Any], type: String) -> [String: Any]? {
        let spec = m["model_spec"] as? [String: Any] ?? [:]
        if spec["offline"] as? Bool == true { return nil }
        let caps = spec["capabilities"] as? [String: Any] ?? [:]
        let pricing = spec["pricing"] as? [String: Any] ?? [:]
        var price: Double?
        if type == "text" {
            price = usd(pricing["input"])
        } else {
            price = usd(pricing["generation"]) ?? usd(pricing["inpaint"])
            if price == nil, let res = pricing["resolutions"] as? [String: Any] { price = res.values.compactMap { usd($0) }.min() }
        }
        var out: [String: Any] = [
            "id": m["id"] ?? "",
            "name": spec["name"] ?? m["id"] ?? "",
            "vision": caps["supportsVision"] as? Bool ?? false,
            "reasoning": caps["supportsReasoning"] as? Bool ?? false,
            "web": (caps["supportsWebSearch"] as? Bool ?? false) || (spec["supportsWebSearch"] as? Bool ?? false),
            "tools": caps["supportsFunctionCalling"] as? Bool ?? false,
            "constraints": spec["constraints"] ?? [String: Any](),
            "pricing": pricing,
            "traits": spec["traits"] ?? [Any](),
        ]
        if let c = spec["availableContextTokens"] ?? m["context_length"] { out["context"] = c }
        if let price { out["price"] = price }
        return out
    }

    // Баланс прямо из Venice (GET /api_keys/rate_limits) — после пополнения не нужно ждать следующего запроса
    private func balance(_ t: WKURLSchemeTask) {
        guard !apiKey.isEmpty else { return json(t, 200, ["balance": NSNull()]) }
        URLSession.shared.dataTask(with: veniceRequest("/api_keys/rate_limits", method: "GET")) { [self] data, resp, _ in
            var bal: [String: Any]? = nil
            if let data, (resp as? HTTPURLResponse)?.statusCode == 200,
               let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let b = (root["data"] as? [String: Any])?["balances"] as? [String: Any],
               let usd = (b["USD"] as? NSNumber)?.doubleValue {
                var v: [String: Any] = ["usd": usd, "at": Int(Date().timeIntervalSince1970 * 1000)]
                if let d = (b["DIEM"] as? NSNumber)?.doubleValue, d > 0 { v["diem"] = d }
                if let c = (b["BUNDLED_CREDITS"] as? NSNumber)?.doubleValue, c > 0 { v["credits"] = c }
                bal = v
                withUsage { u in u["balance"] = v }
            }
            DispatchQueue.main.async { [self] in json(t, 200, ["balance": bal ?? NSNull()]) }
        }.resume()
    }

    private func rememberBalance(_ resp: HTTPURLResponse) {
        guard let v = resp.value(forHTTPHeaderField: "x-venice-balance-usd"), let bal = Double(v) else { return }
        withUsage { u in u["balance"] = ["usd": bal, "at": Int(Date().timeIntervalSince1970 * 1000)] }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let job = jobs[dataTask.taskIdentifier], let http = response as? HTTPURLResponse else { return completionHandler(.cancel) }
        job.response = http
        if !job.isFetch { rememberBalance(http) }
        if job.isFetch && http.expectedContentLength > Int64(fetchLimit) {
            jobs[dataTask.taskIdentifier] = nil
            fail(job.task, 413, "Файл больше 80 МБ — слишком большой")
            return completionHandler(.cancel)
        }
        let type = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if http.statusCode == 200 && type.contains("text/event-stream") && !isStopped(job.task) {
            job.streaming = true
            job.task.didReceive(HTTPURLResponse(url: job.task.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                                headerFields: ["Content-Type": "text/event-stream; charset=utf-8", "Cache-Control": "no-cache"])!)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let job = jobs[dataTask.taskIdentifier] else { return }
        if isStopped(job.task) { dataTask.cancel(); return }
        if job.streaming { job.task.didReceive(data); return }
        job.body.append(data)
        if job.isFetch && job.body.count > fetchLimit {
            jobs[dataTask.taskIdentifier] = nil
            dataTask.cancel()
            fail(job.task, 413, "Файл больше 80 МБ — слишком большой")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let job = jobs.removeValue(forKey: task.taskIdentifier) else { return }
        let t = job.task
        if isStopped(t) { return finished(t) }
        if job.streaming {
            t.didFinish()
            return finished(t)
        }
        if let error {
            let msg = job.isFetch ? "Не удалось скачать: \(error.localizedDescription)" : "Нет связи с Venice: \(error.localizedDescription)"
            return fail(t, 502, msg)
        }
        guard let http = job.response else { return fail(t, 502, "Нет ответа от Venice") }
        if job.isFetch {
            guard http.statusCode < 400 else { return fail(t, http.statusCode, "Сайт ответил ошибкой \(http.statusCode)") }
            return respond(t, 200, job.body, type: http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream",
                           headers: ["X-Final-URL": http.url?.absoluteString ?? ""])
        }
        respond(t, http.statusCode, job.body, type: http.value(forHTTPHeaderField: "Content-Type") ?? "application/json")
    }

    // Переадресации по ссылкам пользователя: не пускаем на локальные адреса
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if session === fetchSession, !Self.isPublic(request.url) { return completionHandler(nil) }
        completionHandler(request)
    }

    // MARK: /api/fetch

    static func isPublic(_ url: URL?) -> Bool {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased(), !host.isEmpty,
              host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local") else { return false }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return false }
        defer { freeaddrinfo(first) }
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            if ai.pointee.ai_family == AF_INET {
                let a = ai.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                let b0 = a >> 24, b1 = (a >> 16) & 0xff
                if b0 == 0 || b0 == 10 || b0 == 127 || b0 >= 224 || (b0 == 169 && b1 == 254) || (b0 == 172 && (16...31).contains(b1))
                    || (b0 == 192 && b1 == 168) || (b0 == 100 && (64...127).contains(b1)) { return false }
            } else if ai.pointee.ai_family == AF_INET6 {
                let bytes = ai.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { s -> [UInt8] in
                    var a = s.pointee.sin6_addr
                    return withUnsafeBytes(of: &a) { Array($0) }
                }
                let isLoop = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
                let isAny = bytes.allSatisfy { $0 == 0 }
                let isMapped = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
                if isLoop || isAny || (bytes[0] & 0xfe) == 0xfc || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) || bytes[0] == 0xff { return false }
                if isMapped {
                    let b0 = bytes[12], b1 = bytes[13]
                    if b0 == 0 || b0 == 10 || b0 == 127 || (b0 == 169 && b1 == 254) || (b0 == 172 && (16...31).contains(b1)) || (b0 == 192 && b1 == 168) { return false }
                }
            }
            p = ai.pointee.ai_next
        }
        return true
    }

    private func fetchURL(_ t: WKURLSchemeTask, body: Data) {
        let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        guard let s = obj?["url"] as? String, let url = URL(string: s), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return fail(t, 400, "Нужна обычная интернет-ссылка (http или https)")
        }
        DispatchQueue.global().async { [self] in
            let ok = Self.isPublic(url)
            DispatchQueue.main.async { [self] in
                guard ok else { return fail(t, 403, "Локальные и частные адреса запрещены") }
                var r = URLRequest(url: url)
                r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
                r.setValue("*/*", forHTTPHeaderField: "Accept")
                start(t, r, fetch: true)
            }
        }
    }

    // MARK: ключ: /api/key

    private func key(_ t: WKURLSchemeTask, method: String, body: Data) {
        if method == "GET" {
            let k = apiKey
            return json(t, 200, ["hasKey": !k.isEmpty, "masked": masked(k), "custom": !customKey.isEmpty, "hasBuiltin": !builtinKey.isEmpty])
        }
        guard method == "POST" else { return fail(t, 405, "Метод не поддерживается") }
        let newKey = (((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["key"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if newKey.isEmpty {
            var cfg = readConfig(); cfg.removeValue(forKey: "key"); writeConfig(cfg)
            modelsCache.removeAll()
            return json(t, 200, ["ok": true])
        }
        URLSession.shared.dataTask(with: veniceRequest("/api_keys/rate_limits", method: "GET", key: newKey)) { [self] _, resp, err in
            DispatchQueue.main.async { [self] in
                if let err { return fail(t, 502, "Нет связи с Venice: \(err.localizedDescription)") }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200 else { return fail(t, 400, "Venice не принял этот ключ (код \(code)). Проверьте, что он скопирован полностью.") }
                var cfg = readConfig(); cfg["key"] = newKey; writeConfig(cfg)
                modelsCache.removeAll()
                json(t, 200, ["ok": true])
            }
        }.resume()
    }

    // MARK: файлы: чаты, проекты, расходы

    private func readJSON(_ url: URL) -> Any? { (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } }

    private func withUsage(_ change: (inout [String: Any]) -> Void) {
        fileLock.lock(); defer { fileLock.unlock() }
        let url = dataDir.appendingPathComponent("usage.json")
        var u = readJSON(url) as? [String: Any] ?? ["events": [Any]()]
        change(&u)
        if let d = try? JSONSerialization.data(withJSONObject: u) { try? d.write(to: url, options: .atomic) }
    }

    private func usage(_ t: WKURLSchemeTask, method: String, body: Data) {
        switch method {
        case "GET":
            fileLock.lock()
            let u = readJSON(dataDir.appendingPathComponent("usage.json")) ?? ["events": [Any]()]
            fileLock.unlock()
            json(t, 200, u)
        case "POST":
            guard let ev = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return fail(t, 400, "bad json") }
            withUsage { u in u["events"] = (u["events"] as? [Any] ?? []) + [ev] }
            json(t, 200, ["ok": true])
        case "DELETE":
            withUsage { u in u["events"] = [Any]() }
            json(t, 200, ["ok": true])
        default:
            fail(t, 405, "Метод не поддерживается")
        }
    }

    private func store(_ t: WKURLSchemeTask, method: String, folder: String, id: String?, body: Data) {
        let dir = dataDir.appendingPathComponent(folder, isDirectory: true)
        guard let id else {
            guard method == "GET" else { return fail(t, 405, "Метод не поддерживается") }
            let fields = folder == "chats" ? ["id", "title", "created", "updated", "model", "projectId", "pinned"]
                                           : ["id", "name", "description", "created", "updated", "folder"]
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                var items: [[String: Any]] = []
                for f in files where f.pathExtension == "json" {
                    guard let d = readJSON(f) as? [String: Any] else { continue }
                    var item: [String: Any] = [:]
                    for k in fields { if let v = d[k] { item[k] = v } }
                    if folder == "projects" { item["fileCount"] = (d["files"] as? [Any])?.count ?? 0 }
                    items.append(item)
                }
                let num = { (x: [String: Any]) -> Double in (x["updated"] as? Double) ?? (x["created"] as? Double) ?? 0 }
                items.sort { num($0) > num($1) }
                json(t, 200, items)
            }
            return
        }
        guard id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else { return fail(t, 400, "bad id") }
        let file = dir.appendingPathComponent(id + ".json")
        switch method {
        case "GET":
            guard let d = try? Data(contentsOf: file) else { return fail(t, 404, "not found") }
            respond(t, 200, d)
        case "PUT":
            guard (try? JSONSerialization.jsonObject(with: body)) is [String: Any] else { return fail(t, 400, "bad json") }
            do { try body.write(to: file, options: .atomic); json(t, 200, ["ok": true]) }
            catch { fail(t, 500, "Не удалось сохранить: \(error.localizedDescription)") }
        case "DELETE":
            try? FileManager.default.removeItem(at: file)
            json(t, 200, ["ok": true])
        default:
            fail(t, 405, "Метод не поддерживается")
        }
    }
}
