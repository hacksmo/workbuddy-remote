// WorkBuddy Remote 的 macOS 原生壳
//
// 为什么不用「bash 脚本 + Chrome --app」：
//   1. 脚本进程不连 WindowServer，Dock 里不会出现图标（图标跟着进程走）
//   2. Chrome 的 --app 没有单实例语义，每执行一次就多一个窗口
// 这也是 Fluid / Unite / Pake 这些同类工具都做原生壳的原因。
//
// 职责很窄：记住服务器地址 → 用 WKWebView 开一个窗口。
// 单实例、Dock 图标、Cmd+Tab 切换都由 AppKit 免费提供。
//
// 配置存在 ~/Library/Application Support/WorkBuddy Remote/config.json，
// 首次启动在窗口里引导一次，之后不再打扰。所以同一个 DMG 谁都能装。

import Cocoa
import WebKit

// MARK: - 配置

struct Config: Codable {
    var url: String = ""
    var token: String = ""
    /// 局域网候选地址，同网段时优先直连（延迟低一个数量级，流量不出内网）
    var lanCandidates: [String] = []
}

enum Store {
    static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("WorkBuddy Remote", isDirectory: true)
    }
    static var file: URL { dir.appendingPathComponent("config.json") }

    static func load() -> Config? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }

    static func save(_ c: Config) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(c) { try? data.write(to: file) }
    }
}

// MARK: - 网络探测
//
// 被控端会在回环 + 各网卡局域网 IP 上同时监听。探测失败是常态
// （换了网络、DHCP 换 IP），必须静默回退到用户填的地址。

func probe(_ base: String, timeout: TimeInterval = 0.4) -> Bool {
    let s = base.hasSuffix("/") ? base + "health" : base + "/health"
    guard let u = URL(string: s) else { return false }
    var req = URLRequest(url: u)
    req.timeoutInterval = timeout
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    URLSession.shared.dataTask(with: req) { _, resp, _ in
        if let h = resp as? HTTPURLResponse, h.statusCode == 200 { ok = true }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 0.3)
    return ok
}

func resolveBase(_ c: Config) -> String {
    for cand in c.lanCandidates where !cand.isEmpty {
        if probe(cand) { return cand }
    }
    return c.url
}

func buildURL(_ c: Config) -> URL? {
    let base = resolveBase(c)
    guard !base.isEmpty else { return nil }
    var s = base
    if !c.token.isEmpty {
        s += (s.contains("?") ? "&" : "?") + "token=" + c.token
    }
    return URL(string: s)
}

/// 本机所有 en* / bridge* 网卡的 /24 前缀，比如 ["192.168.0", "10.1.2"]
func localPrefixes() -> [String] {
    var addrs: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addrs) == 0, let first = addrs else { return [] }
    defer { freeifaddrs(addrs) }

    var out: [String] = []
    var ptr: UnsafeMutablePointer<ifaddrs>? = first
    while let p = ptr {
        defer { ptr = p.pointee.ifa_next }
        guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        let flags = Int32(p.pointee.ifa_flags)
        guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
        let name = String(cString: p.pointee.ifa_name)
        guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }

        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                          &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let ip = String(cString: buf)
        let parts = ip.split(separator: ".")
        // 只扫私有网段的 /24。公网地址扫不得，几百个包里全是噪音。
        guard parts.count == 4 else { continue }
        guard ip.hasPrefix("192.168.") || ip.hasPrefix("10.")
            || (ip.hasPrefix("172.") && (16...31).contains(Int(parts[1]) ?? 0)) else { continue }
        let prefix = parts[0...2].joined(separator: ".")
        if !out.contains(prefix) { out.append(prefix) }
    }
    return out
}

/// 扫本机各网段的 1…254，找开着 8797 的机器。
/// 用户在被控端同一 Wi-Fi 下时基本必中，省掉「去终端复制 IP」这一步。
func scanLAN(port: Int = 8797, onFound: @escaping (String) -> Void, completion: @escaping ([String]) -> Void) {
    let prefixes = localPrefixes()
    if prefixes.isEmpty { completion([]); return }

    var targets: [String] = []
    for p in prefixes {
        for i in 1...254 { targets.append("\(p).\(i):\(port)") }
    }

    let lock = NSLock()
    var found: [String] = []
    let q = OperationQueue()
    q.maxConcurrentOperationCount = 64
    q.qualityOfService = .userInitiated

    for t in targets {
        q.addOperation {
            let base = "http://\(t)"
            if probe(base, timeout: 0.35) {
                lock.lock(); found.append(base); lock.unlock()
                onFound(base)
            }
        }
    }
    q.waitUntilAllOperationsAreFinished()
    completion(found)
}

// MARK: - 应用

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate,
                         WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var window: NSWindow?
    private var webView: WKWebView?
    private var config: Config?
    private var scanning = false

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
        config = Store.load()
        buildWindow()
        if config?.url.isEmpty ?? true {
            loadSetup()
        } else {
            loadApp()
        }
        debugScanIfNeeded()
    }

    // 点 Dock 图标：已有窗口就提到前面，没有才新建。
    // 「点一下缩小、再点一下回来」就来自这里，不用自己实现。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if window == nil { buildWindow() }
        if let w = window {
            if w.isMiniaturized { w.deminiaturize(nil) }
            // 关掉窗口后 w 还活着（isReleasedWhenClosed = false），
            // 但不在屏幕上，必须显式 orderFront 才会重新出现
            w.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    // 关窗不退出：留在 Dock 里，下次点击还能唤回来
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: 建窗

    private func buildWindow() {
        guard window == nil else { return }

        let cfg = WKWebViewConfiguration()
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        cfg.userContentController.add(self, name: "wb")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.allowsBackForwardNavigationGestures = true
        wv.navigationDelegate = self
        // 没有 UIDelegate 时，confirm() / alert() / <input type=file> 全部
        // 静默失效 —— 前端调 confirm() 会直接拿到 false，删除这类二次确认
        // 就永远走不下去，表现是「点了没反应」。
        wv.uiDelegate = self
        webView = wv

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "WorkBuddy Remote"
        w.contentView = wv
        w.delegate = self
        // 关闭后保活对象。默认 true 会释放窗口，Swift 侧留下的引用就成了
        // 悬空指针 —— 之后再 buildWindow/orderFront 会直接崩溃，
        // 表现为「关窗后点 Dock 图标，应用没了」。
        w.isReleasedWhenClosed = false

        // 位置：自己算，不用 setFrameAutosaveName。
        //
        // 踩过的坑：autosave 记录的格式里带「上次所在屏幕」四个数，
        // 多显示器（尤其是排列里位于上方/左侧的屏）恢复时会算出屏幕外坐标，
        // 实测窗口被恢复到 Y=-971，人眼看不到任何东西，以为应用没启动。
        //
        // 用 screens.first（带菜单栏的主显示器）居中，不能用 NSScreen.main ——
        // main 是「当前接收键盘事件的屏」，多屏时会指到外接屏上。
        if let vis = NSScreen.screens.first?.visibleFrame {
            // 窗口比屏幕还大（小笔记本）就按比例缩，别overflow
            let w0 = min(1180, vis.width - 40)
            let h0 = min(800, vis.height - 40)
            w.setFrame(NSRect(x: vis.midX - w0 / 2,
                              y: vis.midY - h0 / 2,
                              width: w0, height: h0),
                       display: false)
        }

        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    // MARK: 页面

    private func loadApp() {
        guard let c = config, let url = buildURL(c) else { loadSetup(); return }
        window?.title = "WorkBuddy Remote"
        webView?.load(URLRequest(url: url))
    }

    /// 引导页。之前用 NSAlert，但它在窗口尚未建立时居中算错，
    /// 弹到屏幕外（实测 Y=-940），用户看不到任何东西。
    /// 直接做成窗口内的页面：位置一定正确，还能放「扫描」按钮。
    private func loadSetup() {
        window?.title = "WorkBuddy Remote · 连接"
        let c = config
        let fallbackURL = (c?.url.isEmpty == false) ? (c?.url ?? "") : "http://127.0.0.1:8797"
        let esc = { (s: String) -> String in
            s.replacingOccurrences(of: "&", with: "&amp;")
             .replacingOccurrences(of: "\"", with: "&quot;")
             .replacingOccurrences(of: "<", with: "&lt;")
        }
        webView?.loadHTMLString(setupHTML(url: esc(fallbackURL), token: esc(c?.token ?? "")),
                                baseURL: nil)
    }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let d = message.body as? [String: Any],
              let action = d["action"] as? String else { return }

        switch action {
        case "scan":
            startScan()
        case "connect":
            let url = (d["url"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let token = (d["token"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            connect(url: url, token: token)
        case "setup":
            loadSetup()
        case "reload":
            loadApp()
        default:
            break
        }
    }

    private func connect(url raw: String, token: String) {
        var url = raw
        while url.hasSuffix("/") { url.removeLast() }
        guard !url.isEmpty else { return }
        if !url.lowercased().hasPrefix("http") { url = "http://" + url }

        var c = config ?? Config()
        c.url = url
        c.token = token
        // 用户手填的是局域网地址就记成候选，之后同网段会优先走它
        if url.contains("192.168.") || url.contains("://10.") || url.contains("://172.") {
            if !c.lanCandidates.contains(url) { c.lanCandidates.append(url) }
        }
        config = c
        Store.save(c)
        loadApp()
    }

    private func startScan() {
        guard !scanning else { return }
        scanning = true
        webView?.evaluateJavaScript("scanStarted()", completionHandler: nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            scanLAN(onFound: { base in
                DispatchQueue.main.async {
                    self?.webView?.evaluateJavaScript(
                        "scanFound(\(jsString(base)))", completionHandler: nil)
                }
            }, completion: { list in
                DispatchQueue.main.async {
                    self?.scanning = false
                    self?.webView?.evaluateJavaScript(
                        "scanDone(\(list.count))", completionHandler: nil)
                }
            })
        }
    }

    /// 调试入口：WBR_DEBUG_SCAN=1 时启动即跑一次扫描并打印，
    /// 用来在没有 GUI 自动化的情况下验证扫描链路。
    func debugScanIfNeeded() {
        guard ProcessInfo.processInfo.environment["WBR_DEBUG_SCAN"] == "1" else { return }
        print("[debug] prefixes = \(localPrefixes())")
        let t0 = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            scanLAN(onFound: { print("[debug] found \($0)") }, completion: { list in
                print("[debug] done \(list.count) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
            })
        }
    }

    // MARK: 菜单动作

    @objc func reload(_ sender: Any?) {
        if config?.url.isEmpty ?? true { loadSetup() } else { webView?.reload() }
    }

    @objc func zoomIn(_ sender: Any?) {
        guard let wv = webView else { return }
        wv.pageZoom = min(3.0, wv.pageZoom + 0.1)
    }
    @objc func zoomOut(_ sender: Any?) {
        guard let wv = webView else { return }
        wv.pageZoom = max(0.5, wv.pageZoom - 0.1)
    }
    @objc func zoomReset(_ sender: Any?) { webView?.pageZoom = 1.0 }

    @objc func changeServer(_ sender: Any?) {
        buildWindow()
        loadSetup()
    }

    // MARK: 加载失败给可操作的提示，而不是白屏

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        webView.loadHTMLString(errorHTML(), baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        webView.loadHTMLString(errorHTML(), baseURL: nil)
    }

    // MARK: - WKUIDelegate
    //
    // WKWebView 默认不弹任何原生对话框。前端调 confirm() 会静默拿到 false，
    // 于是「删除会话」这类带二次确认的操作看起来是「点了没反应」。
    // alert/prompt 同理，<input type=file> 也是 —— 都得自己实现。
    //
    // 用 JS 在页面内画弹窗也行，但那样每个页面都得改，而且和系统风格不一致。
    // 这里直接用 NSAlert，暗色模式、键盘响应、按钮顺序都跟系统一致。

    func webView(_ webView: WKWebView,
                 runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "好")
        attachToWindow(alert)
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        // 顺序很重要：macOS 里第一个按钮是默认按钮（回车触发）。
        // 删除确认这种破坏性操作，「取消」才该是默认 —— 手快回车不会误删。
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "确定")
        // 让「取消」看起来是常规样式，蓝色高亮落在「确定」上会诱导误操作。
        // 破坏性动作系统惯例用红色，这里保持中性即可。
        attachToWindow(alert)
        let r = alert.runModal()
        completionHandler(r == .alertSecondButtonReturn)
    }

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        attachToWindow(alert)
        alert.window.initialFirstResponder = field
        let r = alert.runModal()
        completionHandler(r == .alertFirstButtonReturn ? field.stringValue : nil)
    }

    /// 让弹窗出现在应用窗口中央，而不是系统乱算的位置。
    /// 独立 modal 在窗口未定位时会算出屏幕外坐标（踩过，Y=-940）。
    private func attachToWindow(_ alert: NSAlert) {
        alert.window.level = .modalPanel
        if let w = window, w.isVisible {
            let pf = w.frame
            let af = alert.window.frame
            alert.window.setFrameOrigin(NSPoint(x: pf.midX - af.width / 2,
                                               y: pf.midY - af.height / 2))
        } else {
            alert.window.center()
        }
    }

    // 文件选择：<input type="file"> 需要这个回调才会真的弹面板
    func webView(_ webView: WKWebView,
                 runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true

        if let w = window, w.isVisible {
            // sheet 形式：贴在窗口顶部，不会飘到别的屏幕上
            panel.beginSheetModal(for: w) { r in
                completionHandler(r == .OK ? panel.urls : nil)
            }
        } else {
            let r = panel.runModal()
            completionHandler(r == .OK ? panel.urls : nil)
        }
    }
}

// MARK: - 内嵌 HTML

func jsString(_ s: String) -> String {
    let escaped = s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
    return "\"\(escaped)\""
}

let sharedCSS = """
*{box-sizing:border-box;margin:0;padding:0}
body{font:14px/1.6 -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;
     background:#fafafa;color:#1d1d1f;
     display:flex;align-items:center;justify-content:center;min-height:100vh;padding:32px}
@media (prefers-color-scheme:dark){
  body{background:#1c1c1e;color:#f5f5f7}
  .card{background:#2c2c2e!important;box-shadow:0 1px 3px rgba(0,0,0,.5)!important}
  input{background:#1c1c1e!important;border-color:#3a3a3c!important;color:#f5f5f7!important}
  .hint{color:#98989d!important}
  .cand{background:#1c1c1e!important;border-color:#3a3a3c!important}
  .cand:hover{border-color:#0a84ff!important}
}
.card{background:#fff;border-radius:14px;padding:28px 30px;width:440px;
      box-shadow:0 2px 14px rgba(0,0,0,.07)}
.logo{width:52px;height:52px;border-radius:12px;background:linear-gradient(135deg,#0071e3,#5e5ce6);
      display:flex;align-items:center;justify-content:center;color:#fff;font-size:24px;
      font-weight:600;margin-bottom:18px}
h1{font-size:19px;font-weight:600;margin-bottom:6px}
.sub{font-size:13px;color:#86868b;margin-bottom:22px}
label{display:block;font-size:12px;font-weight:500;margin:14px 0 6px;color:#6e6e73}
input{width:100%;padding:9px 11px;border:1px solid #d2d2d7;border-radius:8px;
      font-size:13px;font-family:inherit;outline:none;background:#fff;color:#1d1d1f}
input:focus{border-color:#0071e3;box-shadow:0 0 0 3px rgba(0,113,227,.15)}
button{font:inherit;font-size:13px;border-radius:8px;border:1px solid #d2d2d7;
       background:#fff;color:#1d1d1f;padding:8px 14px;cursor:pointer}
button:hover{border-color:#b0b0b5}
button.primary{background:#0071e3;border-color:#0071e3;color:#fff;font-weight:500;width:100%;
               padding:10px;margin-top:22px}
button.primary:hover{background:#0062c4}
button.primary:disabled{opacity:.5;cursor:default}
.row{display:flex;gap:8px;margin-top:6px}
.row input{flex:1}
.row button{white-space:nowrap}
.hint{font-size:12px;color:#86868b;margin-top:14px;line-height:1.7}
.hint code{background:rgba(120,120,128,.12);padding:1px 5px;border-radius:4px;font-size:11px}
.cands{margin-top:12px;display:flex;flex-direction:column;gap:6px}
.cand{padding:9px 11px;border:1px solid #d2d2d7;border-radius:8px;cursor:pointer;
      font-size:13px;display:flex;align-items:center;gap:8px;background:#fff}
.cand:hover{border-color:#0071e3}
.dot{width:7px;height:7px;border-radius:50%;background:#34c759;flex:none}
.scan-msg{font-size:12px;color:#86868b;margin-top:10px;min-height:18px}
"""

func setupHTML(url: String, token: String) -> String {
    return """
    <!DOCTYPE html><html><head><meta charset="utf-8"><style>
    \(sharedCSS)
    </style></head><body>
    <div class="card">
      <div class="logo">W</div>
      <h1>连接到 WorkBuddy</h1>
      <div class="sub">填被控端地址。被控端终端会打印这个地址。</div>

      <label>服务器地址</label>
      <div class="row">
        <input id="u" value="\(url)" placeholder="http://192.168.1.10:8797" spellcheck="false">
        <button id="scanBtn" onclick="doScan()">扫描</button>
      </div>

      <label>访问密码</label>
      <input id="t" type="password" value="\(token)" placeholder="被控端启动时设置的 token" spellcheck="false">

      <div id="cands" class="cands"></div>
      <div id="msg" class="scan-msg"></div>

      <button class="primary" onclick="doConnect()">连接</button>

      <div class="hint">
        首次使用先在终端 <code>workbuddy-remote</code> 启动被控端。<br>
        同一 Wi-Fi 下点「扫描」能自动找到它。
      </div>
    </div>
    <script>
    const $ = id => document.getElementById(id);
    const cands = $('cands'), msg = $('msg'), scanBtn = $('scanBtn');

    function doConnect(){
      const url = $('u').value.trim(), token = $('t').value.trim();
      if (!url) { msg.textContent = '地址不能为空'; return; }
      webkit.messageHandlers.wb.postMessage({action:'connect', url, token});
    }

    function doScan(){
      cands.innerHTML = '';
      webkit.messageHandlers.wb.postMessage({action:'scan'});
    }

    function scanStarted(){
      scanBtn.disabled = true;
      scanBtn.textContent = '扫描中';
      msg.textContent = '正在扫描局域网…';
    }

    function scanFound(base){
      const d = document.createElement('div');
      d.className = 'cand';
      d.innerHTML = '<span class="dot"></span><span></span>';
      d.lastChild.textContent = base;
      d.onclick = () => { $('u').value = base; };
      cands.appendChild(d);
    }

    function scanDone(n){
      scanBtn.disabled = false;
      scanBtn.textContent = '扫描';
      msg.textContent = n > 0 ? ('找到 ' + n + ' 个，点一下填入地址')
                              : '没找到。确认被控端已启动，且在同一网络。';
    }

    $('t').addEventListener('keydown', e => { if (e.key === 'Enter') doConnect(); });
    $('u').addEventListener('keydown', e => { if (e.key === 'Enter') doConnect(); });
    </script>
    </body></html>
    """
}

func errorHTML() -> String {
    return """
    <!DOCTYPE html><html><head><meta charset="utf-8"><style>
    \(sharedCSS)
    .card{text-align:center}
    .logo{margin:0 auto 18px}
    .acts{display:flex;gap:8px;margin-top:22px}
    .acts button{flex:1}
    </style></head><body>
    <div class="card">
      <div class="logo" style="background:linear-gradient(135deg,#ff453a,#ff9f0a)">!</div>
      <h1>连不上 WorkBuddy</h1>
      <div class="sub" style="margin-bottom:0">
        确认被控端 <code style="background:rgba(120,120,128,.12);padding:1px 5px;border-radius:4px">workbuddy-remote</code> 正在运行，<br>
        并且地址和密码是对的。
      </div>
      <div class="acts">
        <button onclick="webkit.messageHandlers.wb.postMessage({action:'setup'})">更改服务器</button>
        <button onclick="webkit.messageHandlers.wb.postMessage({action:'reload'})">重试</button>
      </div>
    </div>
    </body></html>
    """
}

// MARK: - 菜单

let app = NSApplication.shared

func buildMenu() {
    let main = NSMenu()

    let appItem = NSMenuItem()
    main.addItem(appItem)
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "关于 WorkBuddy Remote",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "更改服务器…",
                    action: #selector(AppDelegate.changeServer(_:)), keyEquivalent: ",")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "隐藏 WorkBuddy Remote",
                    action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "退出 WorkBuddy Remote",
                    action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu

    let editItem = NSMenuItem()
    main.addItem(editItem)
    let editMenu = NSMenu(title: "编辑")
    editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
    editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
    editMenu.addItem(.separator())
    editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    editItem.submenu = editMenu

    let viewItem = NSMenuItem()
    main.addItem(viewItem)
    let viewMenu = NSMenu(title: "显示")
    viewMenu.addItem(withTitle: "重新载入", action: #selector(AppDelegate.reload(_:)), keyEquivalent: "r")
    viewMenu.addItem(withTitle: "实际大小", action: #selector(AppDelegate.zoomReset(_:)), keyEquivalent: "0")
    viewMenu.addItem(withTitle: "放大", action: #selector(AppDelegate.zoomIn(_:)), keyEquivalent: "=")
    viewMenu.addItem(withTitle: "缩小", action: #selector(AppDelegate.zoomOut(_:)), keyEquivalent: "-")
    viewItem.submenu = viewMenu

    NSApp.mainMenu = main
}

buildMenu()
let delegate = AppDelegate()
app.delegate = delegate
app.run()