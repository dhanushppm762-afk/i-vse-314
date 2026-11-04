import AppKit
import WebKit

// «И ВСЕ 3,14здец»: окно с чатом (интерфейс из static/, грузится с venice://app/) и панелью браузера справа.
// ⚠️ Не переименовывать: bundle id local.venice.chat, файл VeniceChat, папку данных VeniceChat,
// автосохранение окна VeniceChatMain — иначе у людей «пропадут» чаты и настройки.
let appName = "И ВСЕ 3,14здец"

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, WKScriptMessageHandlerWithReply, NSSplitViewDelegate {
    var window: NSWindow!
    var chatView: WKWebView!
    let browser = BrowserPanel(frame: .zero)
    let split = NSSplitView()
    let env = ProcessInfo.processInfo.environment
    var selfTest: Bool { env["VENICE_SELFTEST"] == "1" }
    private var testStarted = false

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(Backend.shared, forURLScheme: "venice")
        cfg.websiteDataStore = .default()   // localStorage с настройками привязан к bundle id
        cfg.mediaTypesRequiringUserActionForPlayback = []   // звук нового обновления играет без нажатия
        let ucc = cfg.userContentController
        ucc.add(self, name: "saveImage")
        ucc.add(self, name: "setTheme")
        ucc.addScriptMessageHandler(self, contentWorld: .page, name: "browser")
        chatView = WKWebView(frame: .zero, configuration: cfg)
        chatView.navigationDelegate = self
        chatView.uiDelegate = self
        chatView.setValue(false, forKey: "drawsBackground")   // без белой вспышки в тёмной теме

        browser.onHide = { [weak self] in self?.setBrowser(visible: false) }
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(chatView)
        split.addArrangedSubview(browser)
        browser.isHidden = true

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = appName
        window.minSize = NSSize(width: 640, height: 480)
        window.contentView = split
        window.center()
        window.setFrameAutosaveName("VeniceChatMain")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        chatView.load(URLRequest(url: URL(string: "venice://app/")!))
        if selfTest {
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard self?.testStarted == false else { return }
                print("SELFTEST load failed: timeout"); exit(1)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) { Workspace.shared.stopAllJobs() }

    // MARK: меню

    private func item(_ title: String, _ action: Selector?, _ key: String, _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = target
        return i
    }

    private func buildMenu() {
        let main = NSMenu()
        let appMenu = NSMenu()
        appMenu.addItem(item("О программе \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""))
        appMenu.addItem(item("Проверить обновления…", #selector(checkUpdates), "", target: self))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Выйти из \(appName)", #selector(NSApplication.terminate(_:)), "q"))
        let edit = NSMenu(title: "Правка")
        edit.addItem(item("Отменить", Selector(("undo:")), "z"))
        edit.addItem(item("Повторить", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Вырезать", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Копировать", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Вставить", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Выбрать всё", #selector(NSText.selectAll(_:)), "a"))
        let view = NSMenu(title: "Вид")
        view.addItem(item("Обновить", #selector(reloadChat), "r", target: self))
        view.addItem(item("Показать или скрыть браузер", #selector(toggleBrowser), "b", target: self))
        view.addItem(item("Адрес в браузере", #selector(focusBrowserAddress), "l", target: self))
        let win = NSMenu(title: "Окно")
        win.addItem(item("Свернуть", #selector(NSWindow.miniaturize(_:)), "m"))
        win.addItem(item("Закрыть", #selector(NSWindow.performClose(_:)), "w"))
        for m in [appMenu, edit, view, win] {
            let holder = NSMenuItem(); holder.submenu = m; main.addItem(holder)
        }
        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }

    @objc func reloadChat() { chatView.reload() }
    @objc func toggleBrowser() { setBrowser(visible: browser.isHidden) }
    @objc func focusBrowserAddress() { setBrowser(visible: true); browser.focusAddress() }
    @objc func checkUpdates() { chatView.evaluateJavaScript("window.checkForUpdates && window.checkForUpdates(true)") }

    func setBrowser(visible: Bool) {
        guard browser.isHidden == visible else { return }
        browser.isHidden = !visible
        split.adjustSubviews()
        if visible {
            let w = split.bounds.width
            split.setPosition(max(420, w * 0.5), ofDividerAt: 0)
        }
        chatView.evaluateJavaScript("window.onBrowserPanel && window.onBrowserPanel(\(visible))")
    }

    func splitView(_ s: NSSplitView, constrainMinCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { 380 }
    func splitView(_ s: NSSplitView, constrainMaxCoordinate p: CGFloat, ofSubviewAt i: Int) -> CGFloat { s.bounds.width - 320 }

    // MARK: мосты JS → Swift

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        switch message.name {
        case "setTheme":
            let t = message.body as? String ?? "system"
            window.appearance = t == "dark" ? NSAppearance(named: .darkAqua) : t == "light" ? NSAppearance(named: .aqua) : nil
        case "saveImage":
            guard let d = message.body as? [String: Any], let url = d["dataUrl"] as? String,
                  let comma = url.firstIndex(of: ","), let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = d["name"] as? String ?? "image.png"
            panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            panel.beginSheetModal(for: window) { r in if r == .OK, let u = panel.url { try? data.write(to: u) } }
        default: break
        }
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard let d = message.body as? [String: Any], let cmd = d["cmd"] as? String else { return replyHandler(nil, "bad command") }
        let args = d["args"] as? [String: Any] ?? [:]
        switch cmd {
        case "show": setBrowser(visible: true); replyHandler(["ok": true], nil)
        case "hide": setBrowser(visible: false); replyHandler(["ok": true], nil)
        case "toggle": toggleBrowser(); replyHandler(["visible": !browser.isHidden], nil)
        default:
            if ["open", "click", "type", "back"].contains(cmd) { setBrowser(visible: true) }
            browser.run(cmd, args) { replyHandler($0, nil) }
        }
    }

    // MARK: навигация окна чата

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = action.request.url, u.scheme != "venice", u.scheme != "about", u.scheme != "blob", u.scheme != "data" {
            NSWorkspace.shared.open(u)   // внешние ссылки — в браузере по умолчанию
            return decisionHandler(.cancel)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = action.request.url { NSWorkspace.shared.open(u) }
        return nil
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = parameters.allowsMultipleSelection
        p.canChooseDirectories = parameters.allowsDirectories
        p.beginSheetModal(for: window) { completionHandler($0 == .OK ? p.urls : nil) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = message; a.addButton(withTitle: "OK")
        a.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = message; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Отменить")
        a.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = NSAlert(); a.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); field.stringValue = defaultText ?? ""
        a.accessoryView = field
        a.addButton(withTitle: "OK"); a.addButton(withTitle: "Отменить")
        a.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard selfTest, !testStarted else { return }
        testStarted = true
        print("SELFTEST page loaded")
        if let task = env["VENICE_AGENTTEST"], !task.isEmpty { runAgentTest(task) } else { runSelfTest() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if selfTest { print("SELFTEST load failed: \(error.localizedDescription)"); exit(1) }
    }

    // MARK: самотесты (VENICE_SELFTEST=1)

    private func finish(_ result: Result<Any, Error>) {
        switch result {
        case .success(let v): print(v as? String ?? "\(v)"); exit(0)
        case .failure(let e): print("SELFTEST error: \(e)"); exit(1)
        }
    }

    private func runSelfTest() {
        // временная папка-проект для проверки /api/fs/*
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("venice-selftest-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try? "function hello() {\n  return 1;\n}\n".write(to: dir.appendingPathComponent("src/app.js"), atomically: true, encoding: .utf8)
        try? "# Проект для самотеста\n".write(to: dir.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        Workspace.shared.allow(dir.path)
        let root = dir.resolvingSymlinksInPath().path
        chatView.callAsyncJavaScript(SelfTest.script, arguments: ["fsRoot": root], in: nil, in: .page) { [weak self] result in
            Workspace.shared.forget(root)
            try? FileManager.default.removeItem(at: dir)
            self?.finish(result)
        }
    }

    private func runAgentTest(_ task: String) {
        // VENICE_AGENTTEST_FOLDER=путь — модель работает с этой папкой (правки и команды разрешаются автоматически)
        var folder = env["VENICE_AGENTTEST_FOLDER"] ?? ""
        if !folder.isEmpty { folder = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path; Workspace.shared.allow(folder) }
        chatView.callAsyncJavaScript(SelfTest.agentScript, arguments: ["task": task, "deny": env["VENICE_AGENTTEST_DENY"] == "1", "folder": folder],
                                     in: nil, in: .page) { [weak self] in
            if !folder.isEmpty { Workspace.shared.forget(folder) }
            self?.finish($0)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
