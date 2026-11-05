import AppKit
import WebKit

// Панель браузера справа: ею пользуется модель (инструменты browser_*), и человек может в ней работать сам.
// Скрипты для чтения страницы выполняются в отдельном content world — сайт их не видит и не может подменить.
final class BrowserPanel: NSView, WKNavigationDelegate, WKUIDelegate, NSTextFieldDelegate {
    let webView: WKWebView
    private let address = NSTextField()
    private let backBtn = NSButton(), forwardBtn = NSButton(), reloadBtn = NSButton(), hideBtn = NSButton()
    private let busyLabel = NSTextField(labelWithString: "Модель работает…")
    private let world = WKContentWorld.world(name: "agent")
    private var loadWaiters: [(String?) -> Void] = []
    private var lastLoadError: String?
    private(set) var navigationStarted = false
    var onHide: (() -> Void)?

    override init(frame: NSRect) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()   // входы на сайты сохраняются между запусками
        // ошибки JS и незагрузившиеся файлы страницы — чтобы ИИ видел, что сайт сломан, даже без снимка
        cfg.userContentController.addUserScript(WKUserScript(source: Self.errorsJS, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
        webView.allowsBackForwardNavigationGestures = true
        super.init(frame: frame)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: вид

    private func button(_ b: NSButton, _ symbol: String, _ tip: String, _ action: Selector) {
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.target = self
        b.action = action
        b.toolTip = tip
        b.setContentHuggingPriority(.required, for: .horizontal)
    }

    private func build() {
        button(backBtn, "chevron.left", "Назад", #selector(goBack))
        button(forwardBtn, "chevron.right", "Вперёд", #selector(goForward))
        button(reloadBtn, "arrow.clockwise", "Обновить", #selector(reload))
        button(hideBtn, "sidebar.right", "Скрыть браузер", #selector(hidePanel))
        address.placeholderString = "Адрес сайта или поиск"
        address.bezelStyle = .roundedBezel
        address.lineBreakMode = .byTruncatingTail
        address.delegate = self
        address.target = self
        address.action = #selector(addressEntered)
        busyLabel.font = .systemFont(ofSize: 11, weight: .medium)
        busyLabel.textColor = .controlAccentColor
        busyLabel.isHidden = true

        let bar = NSStackView(views: [backBtn, forwardBtn, reloadBtn, address, busyLabel, hideBtn])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        let line = NSBox(); line.boxType = .separator
        for v in [bar, line, webView] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),   // ниже заголовка окна, иначе кнопки не нажимаются bar.leadingAnchor.constraint(equalTo: leadingAnchor), bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: bar.bottomAnchor), line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: line.bottomAnchor), webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor), webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        syncButtons()
    }

    private func syncButtons() {
        backBtn.isEnabled = webView.canGoBack
        forwardBtn.isEnabled = webView.canGoForward
        if window?.firstResponder != address.currentEditor() { address.stringValue = webView.url?.absoluteString ?? "" }
    }

    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }
    @objc private func reload() { webView.reload() }
    @objc private func hidePanel() { onHide?() }
    @objc private func addressEntered() {
        let s = address.stringValue.trimmingCharacters(in: .whitespaces)
        if !s.isEmpty { load(s) }
    }
    func focusAddress() { window?.makeFirstResponder(address) }

    static func url(from input: String) -> URL? {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let u = URL(string: s), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme) { return u }
        if !s.contains(" "), s.contains("."), let u = URL(string: "https://" + s), u.host != nil { return u }
        var c = URLComponents(string: "https://duckduckgo.com/")!
        c.queryItems = [URLQueryItem(name: "q", value: s)]
        return c.url
    }

    @discardableResult
    func load(_ input: String) -> Bool {
        guard let u = Self.url(from: input) else { return false }
        lastLoadError = nil
        webView.load(URLRequest(url: u))
        return true
    }

    // MARK: навигация

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationStarted = true
        lastLoadError = nil
        syncButtons()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { syncButtons() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { syncButtons(); fireWaiters(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loadFailed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loadFailed(error) }

    private func loadFailed(_ error: Error) {
        syncButtons()
        let ns = error as NSError
        if ns.code == NSURLErrorCancelled { return }   // новая загрузка прервала старую — ждём её
        lastLoadError = error.localizedDescription
        fireWaiters(lastLoadError)
    }

    private func fireWaiters(_ err: String?) {
        let w = loadWaiters; loadWaiters = []
        w.forEach { $0(err) }
    }

    /// Ждёт окончания загрузки (или таймаута). Если загрузка уже закончилась — сразу.
    private func waitLoad(timeout: TimeInterval = 20, _ done: @escaping (String?) -> Void) {
        if !webView.isLoading { return done(lastLoadError) }
        var fired = false
        let once: (String?) -> Void = { e in if !fired { fired = true; done(e) } }
        loadWaiters.append(once)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once(nil) }
    }

    // Ссылки «в новом окне» открываем здесь же
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let u = navigationAction.request.url { webView.load(URLRequest(url: u)) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert(); a.messageText = message; a.addButton(withTitle: "OK")
        if let w = window { a.beginSheetModal(for: w) { _ in completionHandler() } } else { completionHandler() }
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert(); a.messageText = message; a.addButton(withTitle: "OK"); a.addButton(withTitle: "Отменить")
        if let w = window { a.beginSheetModal(for: w) { completionHandler($0 == .alertFirstButtonReturn) } } else { completionHandler(false) }
    }
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let p = NSOpenPanel(); p.allowsMultipleSelection = parameters.allowsMultipleSelection; p.canChooseDirectories = parameters.allowsDirectories
        p.begin { completionHandler($0 == .OK ? p.urls : nil) }
    }

    // MARK: команды модели

    private static let helpers = """
    const labelOf = el => (el.getAttribute("aria-label") || el.innerText || el.value || el.getAttribute("placeholder") ||
      el.getAttribute("title") || el.getAttribute("alt") || el.querySelector?.("img")?.alt || "").replace(/\\s+/g, " ").trim().slice(0, 80);
    const byRef = ref => document.querySelector(`[data-agent-ref="${ref}"]`);
    """

    private static let errorsJS = """
    window.__vcErrors = [];
    const __vcPush = s => { if (window.__vcErrors.length < 30) window.__vcErrors.push(String(s).slice(0, 300)); };
    addEventListener("error", e => {
      const t = e.target;
      if (t && t !== window && (t.src || t.href)) __vcPush("Не загрузилось: " + (t.src || t.href));
      else __vcPush("JS: " + e.message + (e.filename ? " (" + e.filename.split("/").pop() + ":" + e.lineno + ")" : ""));
    }, true);
    addEventListener("unhandledrejection", e => __vcPush("JS (promise): " + ((e.reason && e.reason.message) || e.reason)));
    """

    private static let readJS = helpers + """
    const MAX_TEXT = 15000;
    document.querySelectorAll("[data-agent-ref]").forEach(e => e.removeAttribute("data-agent-ref"));
    const sel = "a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[role=radio],[role=option],[role=switch],[role=combobox],[role=searchbox],[contenteditable=''],[contenteditable=true]";
    const visible = el => {
      const r = el.getBoundingClientRect();
      if (r.width < 2 || r.height < 2) return false;
      const s = getComputedStyle(el);
      return s.visibility !== "hidden" && s.display !== "none" && s.opacity !== "0";
    };
    const vh = innerHeight;
    const onScreen = el => { const r = el.getBoundingClientRect(); return r.bottom > 0 && r.top < vh; };
    const els = [...document.querySelectorAll(sel)].filter(visible);
    els.sort((a, b) => (onScreen(b) - onScreen(a)) || (a.getBoundingClientRect().top - b.getBoundingClientRect().top));
    const lines = [];
    els.slice(0, 200).forEach((el, i) => {
      const n = i + 1;
      el.setAttribute("data-agent-ref", n);
      const tag = el.tagName.toLowerCase(), type = (el.getAttribute("type") || "").toLowerCase();
      const kind = el.getAttribute("role") || (tag === "a" ? "link" : tag === "input" ? `input:${type || "text"}` : tag);
      let extra = "";
      if (tag === "input" || tag === "textarea") {
        if (type === "password") extra += " (поле пароля — заполняет только пользователь)";
        else if (el.value) extra += ` value="${el.value.slice(0, 60)}"`;
        if (el.placeholder) extra += ` placeholder="${el.placeholder.slice(0, 60)}"`;
        if (type === "checkbox" || type === "radio") extra += el.checked ? " [отмечено]" : " [не отмечено]";
      }
      if (tag === "select") extra += ` выбрано="${el.selectedOptions[0]?.text?.trim() || ""}" варианты=${[...el.options].slice(0, 15).map(o => o.text.trim()).join(" | ")}`;
      if (tag === "a") {
        const h = el.getAttribute("href");
        if (h && !h.startsWith("javascript")) { try { extra += ` → ${new URL(h, location.href).href.slice(0, 120)}`; } catch {} }
      }
      lines.push(`[${n}] ${kind} "${labelOf(el)}"${extra}${onScreen(el) ? "" : " (ниже/выше экрана)"}`);
    });
    const text = (document.body?.innerText || "").replace(/\\n{3,}/g, "\\n\\n").trim();
    const from = Math.max(0, Math.min(offset || 0, text.length));
    return {
      url: location.href, title: document.title,
      scroll: `${Math.round(scrollY)} из ${Math.max(0, document.documentElement.scrollHeight - innerHeight)} px`,
      text: text.slice(from, from + MAX_TEXT), textFrom: from, textTotal: text.length,
      elements: lines.join("\\n"), elementCount: els.length,
      errors: (window.__vcErrors || []).slice(-10),
    };
    """

    private static let describeJS = helpers + """
    const el = byRef(ref);
    if (!el) return { error: "Элемент не найден — вызовите browser_read заново" };
    const type = (el.getAttribute("type") || "").toLowerCase(), tag = el.tagName.toLowerCase();
    const isSubmit = type === "submit" || (tag === "button" && !!el.form && (!el.getAttribute("type") || type === "submit"));
    return { tag, type, text: labelOf(el), href: el.href || "", isSubmit, inForm: !!el.form, password: type === "password", host: location.host };
    """

    private static let clickJS = helpers + """
    const el = byRef(ref);
    if (!el) return { error: "Элемент не найден — страница изменилась, вызовите browser_read заново" };
    el.scrollIntoView({ block: "center", inline: "center" });
    if (el.tagName === "A") el.removeAttribute("target");
    const label = labelOf(el);
    el.focus?.();
    el.click();
    return { clicked: label || el.tagName.toLowerCase() };
    """

    private static let typeJS = helpers + """
    const el = byRef(ref);
    if (!el) return { error: "Элемент не найден — вызовите browser_read заново" };
    if ((el.getAttribute("type") || "").toLowerCase() === "password") return { error: "Вводить пароли нельзя — попросите пользователя ввести его самому в панели браузера" };
    el.scrollIntoView({ block: "center" });
    el.focus();
    if (el.isContentEditable) {
      document.execCommand("selectAll", false);
      document.execCommand("insertText", false, text);
    } else if (el.tagName === "SELECT") {
      const opt = [...el.options].find(o => o.text.trim().toLowerCase() === text.trim().toLowerCase() || o.value === text);
      if (!opt) return { error: `Нет варианта «${text}»` };
      el.value = opt.value;
    } else {
      const proto = el.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      Object.getOwnPropertyDescriptor(proto, "value").set.call(el, text); // так видят изменение и React-сайты
    }
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    if (submit) {
      for (const t of ["keydown", "keypress", "keyup"]) el.dispatchEvent(new KeyboardEvent(t, { key: "Enter", code: "Enter", keyCode: 13, which: 13, bubbles: true }));
      if (el.form) { el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit(); }
    }
    return { typed: text.slice(0, 80), into: labelOf(el), submitted: !!submit };
    """

    private static let scrollJS = """
    scrollBy(0, (down ? 1 : -1) * innerHeight * 0.8);
    await new Promise(r => setTimeout(r, 400));
    return { scroll: `${Math.round(scrollY)} из ${Math.max(0, document.documentElement.scrollHeight - innerHeight)} px` };
    """

    private func js(_ body: String, _ args: [String: Any], _ done: @escaping ([String: Any]) -> Void) {
        guard webView.url != nil else { return done(["error": "Страница не открыта — сначала browser_open"]) }
        webView.callAsyncJavaScript(body, arguments: args, in: nil, in: world) { result in
            switch result {
            case .success(let v): done(v as? [String: Any] ?? [:])
            case .failure(let e): done(["error": "Страница не ответила: \(e.localizedDescription)"])
            }
        }
    }

    private func status() -> [String: Any] { ["url": webView.url?.absoluteString ?? "", "title": webView.title ?? ""] }

    /// Действие, после которого страница может смениться: ждём начала загрузки и её конца.
    private func afterAction(_ result: [String: Any], _ done: @escaping ([String: Any]) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            if navigationStarted || webView.isLoading {
                waitLoad(timeout: 15) { _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { done(result) } }
            } else { done(result) }
        }
    }

    func setBusy(_ on: Bool) { busyLabel.isHidden = !on }

    func run(_ cmd: String, _ args: [String: Any], _ done: @escaping (Any?) -> Void) {
        switch cmd {
        case "open":
            let input = args["url"] as? String ?? ""
            guard load(input) else { return done(["error": "Пустой адрес"]) }
            DispatchQueue.main.async { [self] in
                waitLoad { [self] err in
                    var r = status()
                    if let err { r["loadError"] = err }
                    done(r)
                }
            }
        case "read":
            waitLoad(timeout: 10) { [self] _ in js(Self.readJS, ["offset": args["offset"] as? Int ?? 0], done) }
        case "describe":
            js(Self.describeJS, ["ref": args["ref"] as? Int ?? -1], done)
        case "click":
            navigationStarted = false
            js(Self.clickJS, ["ref": args["ref"] as? Int ?? -1]) { [self] r in r["error"] != nil ? done(r) : afterAction(r, done) }
        case "type":
            navigationStarted = false
            let submit = args["submit"] as? Bool ?? false
            js(Self.typeJS, ["ref": args["ref"] as? Int ?? -1, "text": args["text"] as? String ?? "", "submit": submit]) { [self] r in
                (r["error"] != nil || !submit) ? done(r) : afterAction(r, done)
            }
        case "scroll":
            js(Self.scrollJS, ["down": (args["direction"] as? String ?? "down") != "up"], done)
        case "back":
            guard webView.canGoBack else { return done(["error": "Назад идти некуда"]) }
            navigationStarted = false
            webView.goBack()
            afterAction(status(), { [self] _ in done(status()) })
        case "screenshot":
            let cfg = WKSnapshotConfiguration()
            cfg.snapshotWidth = 1024
            webView.takeSnapshot(with: cfg) { image, error in
                guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                      let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
                    return done(["error": "Не удалось сделать снимок: \(error?.localizedDescription ?? "нет изображения")"])
                }
                done(["image": "data:image/jpeg;base64," + jpg.base64EncodedString()])
            }
        case "status":
            done(status())
        case "busy":
            setBusy(args["on"] as? Bool ?? false)
            done(["ok": true])
        default:
            done(["error": "Неизвестная команда \(cmd)"])
        }
    }
}
