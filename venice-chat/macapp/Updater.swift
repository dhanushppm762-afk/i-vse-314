import AppKit
import WebKit

// Обновления с GitHub: смотрим последний релиз репозитория, и если версия новее — интерфейс
// показывает уведомление снизу слева. По кнопке «Обновить» скачиваем .zip с приложением из релиза,
// подменяем приложение на месте и перезапускаем. Чаты и настройки лежат отдельно и не трогаются.
final class Updater {
    static let shared = Updater()

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    var repo: String { Bundle.main.object(forInfoDictionaryKey: "VCUpdateRepo") as? String ?? "dhanushppm762-afk/i-vse-314" }

    private var latest: [String: Any]?
    private var checkedAt = Date.distantPast
    private var installing = false

    /// "v3.10.1" → [3, 10, 1]
    static func parts(_ v: String) -> [Int] {
        v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: /api/update

    func handleAPI(_ t: WKURLSchemeTask, method: String, body: Data) {
        let b = Backend.shared
        if method == "GET" {
            let force = t.request.url?.query?.contains("force=1") ?? false
            return check(force: force) { info in b.json(t, 200, info) }
        }
        guard method == "POST" else { return b.fail(t, 405, "Метод не поддерживается") }
        check(force: false) { [self] info in
            guard info["available"] as? Bool == true, let zip = info["zip"] as? String, let url = URL(string: zip) else {
                return b.fail(t, 400, "Обновлений нет")
            }
            install(from: url) { err in
                if let err { b.fail(t, 500, err) } else { b.json(t, 200, ["ok": true, "restarting": true]) }
            }
        }
    }

    // MARK: проверка

    func check(force: Bool, _ done: @escaping ([String: Any]) -> Void) {
        let current = Self.currentVersion
        if !force, let latest, Date().timeIntervalSince(checkedAt) < 1800 { return done(summary(latest, current)) }
        var r = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("VeniceChat/\(current)", forHTTPHeaderField: "User-Agent")
        r.timeoutInterval = 20
        URLSession.shared.dataTask(with: r) { [self] data, resp, err in
            DispatchQueue.main.async { [self] in
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard code == 200, let data, let rel = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    let why = err?.localizedDescription ?? (code == 404 ? "релизов пока нет" : "GitHub ответил \(code)")
                    return done(["current": current, "available": false, "error": why])
                }
                latest = rel
                checkedAt = Date()
                done(summary(rel, current))
            }
        }.resume()
    }

    private func summary(_ rel: [String: Any], _ current: String) -> [String: Any] {
        let tag = rel["tag_name"] as? String ?? ""
        let assets = rel["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { ($0["name"] as? String ?? "").lowercased().hasSuffix(".zip") }?["browser_download_url"] as? String
        let available = !tag.isEmpty && Self.isNewer(tag, than: current) && zip != nil && rel["draft"] as? Bool != true
        var out: [String: Any] = ["current": current, "latest": tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                                  "available": available, "notes": rel["body"] as? String ?? "", "page": rel["html_url"] as? String ?? ""]
        if let zip { out["zip"] = zip }
        return out
    }

    // MARK: установка

    private func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func install(from url: URL, _ done: @escaping (String?) -> Void) {
        guard !installing else { return done("Обновление уже скачивается") }
        installing = true
        let fail: (String) -> Void = { [self] msg in DispatchQueue.main.async { [self] in installing = false; done(msg) } }
        URLSession.shared.downloadTask(with: url) { [self] tmp, resp, err in
            guard let tmp, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                return fail("Не удалось скачать обновление: \(err?.localizedDescription ?? "ошибка сервера")")
            }
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("vc-update-\(UUID().uuidString)")
            try? fm.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("update.zip")
            do { try fm.moveItem(at: tmp, to: zip) } catch { return fail("Не удалось сохранить обновление") }
            guard run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) else { return fail("Архив обновления повреждён") }
            let found = (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil))?.first { $0.pathExtension == "app" }
            guard let newApp = found, let newBundle = Bundle(url: newApp),
                  newBundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
                return fail("В архиве нет подходящего приложения")
            }
            _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

            let current = Bundle.main.bundleURL
            let old = work.appendingPathComponent("old.app")
            do {
                try fm.moveItem(at: current, to: old)
                do { try fm.moveItem(at: newApp, to: current) }
                catch { try? fm.moveItem(at: old, to: current); throw error }
            } catch {
                return fail("Не удалось заменить приложение (\(error.localizedDescription)). Скачайте новую версию со страницы релиза.")
            }
            DispatchQueue.main.async {
                done(nil)
                // запускаем новую версию, когда эта закроется
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.3; done; open \"$0\"", current.path]
                try? p.run()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { NSApp.terminate(nil) }
            }
        }.resume()
    }
}
