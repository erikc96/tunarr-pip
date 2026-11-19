import AppKit
import WebKit
import CoreGraphics
import Foundation

let fuzzBase = ["..#....#..", "...#..#...", "..######..", ".########.", "", ".########.", "", "", "..##..##.."]
let fuzzMoods: [String: [String]] = [
    "watching": [".#k####k#.", ".#k####k#.", "..#kkkk#.."],
    "happy":    [".#k####k#.", ".##k##k##.", "..##kk##.."],
    "ok":       [".#k####k#.", ".##kkkk##.", "..######.."],
    "hungry":   [".#k####k#.", ".###kk###.", "..##kk##.."],
    "sad":      [".#k####k#.", ".###kk###.", "..#k##k#.."],
    "static":   [".#k####k#.", ".##kkkk##.", "..######.."]
]
let moodText = [
    "watching": "FUZZ IS DANCING · SOMEONE'S TUNED IN",
    "happy": "FUZZ IS FED FOR TODAY",
    "ok": "FUZZ IS PECKISH · NOBODY HAS WATCHED TODAY",
    "hungry": "FUZZ IS HUNGRY · 2 DAYS WITHOUT TV",
    "sad": "FUZZ IS SAD · %d DAYS WITHOUT TV",
    "static": "FUZZ IS FADING INTO STATIC…"
]

struct Frame: Codable, Equatable { var x: CGFloat; var y: CGFloat; var w: CGFloat; var h: CGFloat }
struct Mascot: Codable { var mood: String?; var idle: Int? }
struct Me: Codable { var streak: Int? }
struct Live: Codable { var channel: Int? }
struct Vibe: Codable { var mascot: Mascot?; var me: Me?; var live: [Live]? }
struct State: Codable { var pid: Int?; var vibe: Vibe?; var hidden: Bool?; var screen: String? }
struct WindowReport: Codable, Equatable { var frame: Frame?; var onscreen: Bool; var panel: PanelReport }
struct PanelReport: Codable, Equatable { var frame: Frame?; var visible: Bool }

func fuzzImage(_ requestedMood: String) -> NSImage {
    let mood = fuzzMoods[requestedMood] == nil ? "ok" : requestedMood
    var rows = fuzzBase
    let face = fuzzMoods[mood]!
    rows[4] = face[0]; rows[6] = face[1]; rows[7] = face[2]
    let image = NSImage(size: NSSize(width: 20, height: 18))
    image.lockFocus()
    NSColor.black.setFill()
    for (y, row) in rows.enumerated() {
        for (x, character) in row.enumerated() where character == "#" {
            if mood == "static" && Double.random(in: 0..<1) < 0.45 { continue }
            NSBezierPath(rect: NSRect(x: x * 2, y: 18 - (y + 1) * 2, width: 2, height: 2)).fill()
        }
    }
    image.unlockFocus()
    image.isTemplate = true
    return image
}

func cgFrameToNS(_ frame: Frame, primaryHeight: CGFloat) -> Frame {
    Frame(x: frame.x, y: primaryHeight - frame.y - frame.h, w: frame.w, h: frame.h)
}

func primaryScreenHeight() -> CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

func playerWindow(pid: Int) -> (Frame?, Bool) {
    let options: CGWindowListOption = .optionAll
    guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return (nil, false) }
    var best: (Frame, CGFloat)?
    for window in info {
        guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.intValue == pid,
              (0...3).contains((window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1), // mpv --ontop is layer 3 (floating), measured 2026-11-19
              (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true,
              let bounds = window[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 1, rect.height > 1 else { continue }
        let area = rect.width * rect.height
        if best == nil || area > best!.1 { best = (Frame(x: rect.origin.x, y: rect.origin.y, w: rect.width, h: rect.height), area) }
    }
    return (best?.0, best != nil)
}

final class FuzzPanel: NSPanel {
    var onVisibilityChanged: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    override func orderOut(_ sender: Any?) { super.orderOut(sender); onVisibilityChanged?() }
}

/// Server-sent-events client for /events. Only `ui` events matter here ({open,tab,find} | {close}).
final class UIEvents: NSObject, URLSessionDataDelegate {
    var onUI: (([String: Any]) -> Void)?
    var request: URLRequest
    var buffer = ""
    var event = ""
    var session: URLSession!
    init(request: URLRequest) {
        self.request = request
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: .main)
    }
    func start() { buffer = ""; event = ""; session.dataTask(with: request).resume() }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer += String(decoding: data, as: UTF8.self)
        while let range = buffer.range(of: "\n") {
            let line = String(buffer[buffer.startIndex..<range.lowerBound]); buffer.removeSubrange(buffer.startIndex...range.lowerBound)
            if line.hasPrefix("event:") { event = line.dropFirst(6).trimmingCharacters(in: .whitespaces) }
            else if line.hasPrefix("data:"), event == "ui",
                    let parsed = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)),
                    let object = (parsed as? [String: Any]) ?? (parsed as? [[String: Any]])?.first { onUI?(object) } // tunarrd sends every verb's data as an argument array
            else if line.isEmpty { event = "" }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.start() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, NSWindowDelegate, WKScriptMessageHandler {
    let configDir: URL
    let port: Int
    let token: String
    let session = URLSession(configuration: .ephemeral)
    var statusItem: NSStatusItem!
    var panel: FuzzPanel!
    var webView: WKWebView!
    var stateTimer: Timer?
    var frameTimer: Timer?
    var probeTimer: Timer?
    var latestPID: Int?
    var pipFrame: Frame?
    var pipOnscreen = false
    var playerUnavailable = false
    var lastReport: WindowReport?
    var dockedFrame: NSRect?
    var mood = "ok"
    var idle = 0
    var live: [Live] = []
    var events: UIEvents?

    override init() {
        let path = ProcessInfo.processInfo.environment["TUNARRD_DIR"] ?? (NSHomeDirectory() + "/Library/Application Support/tunarr-pip")
        configDir = URL(fileURLWithPath: path)
        port = Int(ProcessInfo.processInfo.environment["TUNARRD_PORT"] ?? "7849") ?? 7849
        token = (try? String(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self; statusItem.button?.action = #selector(togglePanel)
        updateStatus()
        makePanel()
        stateTimer = Timer.scheduledTimer(timeInterval: 10, target: self, selector: #selector(fetchState), userInfo: nil, repeats: true)
        probeTimer = Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(probeWebView), userInfo: nil, repeats: true)
        fetchState()
        events = UIEvents(request: request("events"))
        events?.onUI = { [weak self] message in self?.handleUI(message) }
        events?.start()
    }

    func handleUI(_ message: [String: Any]) {
        if message["close"] as? Bool == true { panel.orderOut(nil) }
        else if message["open"] as? Bool == true, !panel.isVisible { togglePanel() }
    }

    /// The page posts {act:"close"} to `webkit.messageHandlers.fuzz` (panel.html close button / Esc).
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any], body["act"] as? String == "close" { panel.orderOut(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func windowShouldClose(_ sender: NSWindow) -> Bool { sender.orderOut(nil); return false }

    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }
    func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path)); request.httpMethod = method
        request.setValue(token, forHTTPHeaderField: "X-Tunarr-Token")
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    func makePanel() {
        panel = FuzzPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 540), styleMask: [.titled, .closable, .resizable, .utilityWindow, .hudWindow], backing: .buffered, defer: false)
        panel.title = "Fuzz"; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false; panel.delegate = self
        panel.onVisibilityChanged = { [weak self] in self?.sendWindowReport() }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(self, name: "fuzz")
        webView = WKWebView(frame: panel.contentView!.bounds, configuration: configuration)
        webView.autoresizingMask = [.width, .height]; webView.navigationDelegate = self
        panel.contentView?.addSubview(webView)
        var components = URLComponents(url: baseURL.appendingPathComponent("panel"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "t", value: token)]
        webView.load(URLRequest(url: components.url!))
        panel.orderOut(nil)
    }

    @objc func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) } else { dockPanel(); panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
        sendWindowReport()
    }

    @objc func fetchState() {
        session.dataTask(with: request("state")) { [weak self] data, response, _ in
            guard let self, let data, let response = response as? HTTPURLResponse, response.statusCode == 200,
                  let state = try? JSONDecoder().decode(State.self, from: data) else { return }
            DispatchQueue.main.async { self.consume(state) }
        }.resume()
    }

    func consume(_ state: State) {
        let oldPID = latestPID; latestPID = state.pid
        let vibe = state.vibe
        mood = vibe?.mascot?.mood ?? "ok"; idle = vibe?.mascot?.idle ?? 0; live = vibe?.live ?? []; currentStreak = vibe?.me?.streak ?? 0
        playerUnavailable = state.hidden == true || state.screen != nil
        updateStatus()
        if state.pid != nil && frameTimer == nil {
            frameTimer = Timer.scheduledTimer(timeInterval: 0.25, target: self, selector: #selector(pollFrame), userInfo: nil, repeats: true)
            pollFrame()
        } else if state.pid == nil {
            frameTimer?.invalidate(); frameTimer = nil; pipFrame = nil; pipOnscreen = false; sendWindowReport(force: true)
        }
        if oldPID != state.pid { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.dockPanel() } }
    }

    func updateStatus() {
        let line: String
        if mood == "watching" && live.contains(where: { $0.channel == 0 }) { line = "FUZZ IS WATCHING A TAPE · POPCORN OUT" }
        else { line = (moodText[mood] ?? moodText["ok"]!).replacingOccurrences(of: "%d", with: "\(idle)") }
        statusItem.button?.image = fuzzImage(mood)
        statusItem.button?.title = (/* state only supplies streak inside vibe */ currentStreak > 0) ? "\(currentStreak)" : ""
        statusItem.button?.toolTip = line
    }
    var currentStreak = 0

    @objc func pollFrame() {
        guard let pid = latestPID else { return }
        let found = playerWindow(pid: pid); pipFrame = found.0; pipOnscreen = found.1
        sendWindowReport()
    }

    func panelFrame() -> Frame? {
        guard panel.isVisible else { return nil }
        let f = panel.frame
        return Frame(x: f.origin.x, y: primaryScreenHeight() - f.origin.y - f.height, w: f.width, h: f.height)
    }
    func windowDidMove(_ notification: Notification) { sendWindowReport() }
    func windowDidResize(_ notification: Notification) { sendWindowReport() }
    func sendWindowReport(force: Bool = false) {
        let report = WindowReport(frame: pipFrame, onscreen: pipOnscreen, panel: PanelReport(frame: panelFrame(), visible: panel.isVisible))
        guard force || report != lastReport, let body = try? JSONEncoder().encode(report) else { return }
        lastReport = report
        session.dataTask(with: request("window", method: "POST", body: body)).resume()
    }

    func dockPanel() {
        if let dockedFrame, !panel.frame.equalTo(dockedFrame) { return }
        let screen: NSScreen
        var target: NSRect
        if let p = pipFrame, pipOnscreen, !playerUnavailable {
            let ns = cgFrameToNS(p, primaryHeight: primaryScreenHeight())
            guard let found = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: ns.x + ns.w / 2, y: ns.y + ns.h / 2)) }) else { return }
            screen = found
            target = NSRect(x: ns.x - 340 - 8, y: ns.y + ns.h - 540, width: 340, height: 540)
        } else {
            screen = NSScreen.main ?? NSScreen.screens[0]
            let visible = screen.visibleFrame
            target = NSRect(x: visible.maxX - 16 - 340, y: visible.minY + 16, width: 340, height: 540)
        }
        let visible = screen.visibleFrame
        target.origin.x = min(max(target.origin.x, visible.minX), visible.maxX - target.width)
        target.origin.y = min(max(target.origin.y, visible.minY), visible.maxY - target.height)
        panel.setFrame(target, display: false); dockedFrame = target
    }

    @objc func probeWebView() {
        webView.evaluateJavaScript("typeof app") { [weak self] value, _ in
            if (value as? String) != "object" { self?.reloadWebView(after: 0) }
        }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { reloadWebView(after: 1) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { reloadWebView(after: 1) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { reloadWebView(after: 1) }
    func reloadWebView(after seconds: TimeInterval) { DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.webView.reload() } }
}

func synchronousState(port: Int, token: String) -> State? {
    let url = URL(string: "http://127.0.0.1:\(port)/state")!; var request = URLRequest(url: url); request.setValue(token, forHTTPHeaderField: "X-Tunarr-Token")
    let semaphore = DispatchSemaphore(value: 0); var result: State?
    URLSession.shared.dataTask(with: request) { data, response, _ in
        if let data, (response as? HTTPURLResponse)?.statusCode == 200 { result = try? JSONDecoder().decode(State.self, from: data) }; semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + 2); return result
}

let arguments = CommandLine.arguments
if arguments.contains("--selftest") {
    for mood in ["watching", "happy", "ok", "hungry", "sad", "static"] { _ = fuzzImage(mood); print("icon \(mood): ok") }
    let conversion = cgFrameToNS(Frame(x: 10, y: 20, w: 30, h: 40), primaryHeight: 900)
    precondition(conversion == Frame(x: 10, y: 840, w: 30, h: 40)); print("CG-to-NSScreen: ok")
    // The SSE reader must open the panel for tunarrd's real wire format: data is an argument array.
    let events = UIEvents(request: URLRequest(url: URL(string: "http://127.0.0.1:1/events")!)); var seen: [[String: Any]] = []
    events.onUI = { seen.append($0) }
    let wire = "event: ui\ndata: [{\"open\":true,\"tab\":\"xray\",\"find\":false}]\n\nevent: tab\ndata: [\"tv\"]\n\nevent: ui\ndata: [{\"close\":true}]\n\n"
    events.urlSession(events.session, dataTask: events.session.dataTask(with: events.request), didReceive: Data(wire.utf8))
    precondition(seen.count == 2 && seen[0]["open"] as? Bool == true && seen[0]["tab"] as? String == "xray" && seen[1]["close"] as? Bool == true); print("ui events: ok")
    exit(0)
}
if arguments.contains("--print-frame") {
    let directory = ProcessInfo.processInfo.environment["TUNARRD_DIR"] ?? (NSHomeDirectory() + "/Library/Application Support/tunarr-pip")
    let port = Int(ProcessInfo.processInfo.environment["TUNARRD_PORT"] ?? "7849") ?? 7849
    let token = (try? String(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    if let pid = synchronousState(port: port, token: token)?.pid { let result = playerWindow(pid: pid); let object: [String: Any] = ["frame": result.0.map { ["x": $0.x, "y": $0.y, "w": $0.w, "h": $0.h] } ?? NSNull(), "onscreen": result.1]; let data = try! JSONSerialization.data(withJSONObject: object); print(String(data: data, encoding: .utf8)!) } else { print("null") }
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate(); app.delegate = delegate; app.run()
