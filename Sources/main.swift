import Cocoa
import ServiceManagement

// Claude Usage — a futuristic HUD menu bar app showing the same numbers as
// Claude Code's `/usage`. `/usage` calls GET /api/oauth/usage with the OAuth
// token Claude Code keeps in the macOS Keychain (service
// "Claude Code-credentials"). We read that token read-only and call the same
// endpoint — we never refresh/rotate it (Claude Code owns that).

// MARK: - Model
struct UsageWindow { let utilization: Double; let resetsAt: Date? }   // utilization 0–100
struct LiveUsage {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let sevenDayOpus: UsageWindow?
    let sevenDaySonnet: UsageWindow?
    let extraEnabled: Bool
}
enum FetchResult { case ok(LiveUsage), noToken, authExpired, rateLimited(TimeInterval?), failed(String) }

// MARK: - Palette
enum HUD {
    static let cyan   = NSColor(srgbRed: 0.20, green: 0.95, blue: 1.00, alpha: 1)
    static let violet = NSColor(srgbRed: 0.62, green: 0.36, blue: 1.00, alpha: 1)
    static let amber  = NSColor(srgbRed: 1.00, green: 0.74, blue: 0.20, alpha: 1)
    static let red    = NSColor(srgbRed: 1.00, green: 0.28, blue: 0.32, alpha: 1)
    static let ink    = NSColor.white
    static func mono(_ s: CGFloat, _ w: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: s, weight: w)
    }
    static func center() -> NSParagraphStyle { let p = NSMutableParagraphStyle(); p.alignment = .center; return p }
}

// MARK: - Keychain
func keychainToken() -> String? {
    let p = Process()
    p.launchPath = "/usr/bin/security"
    p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    guard let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          let jd = raw.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: jd) as? [String: Any],
          let oauth = obj["claudeAiOauth"] as? [String: Any],
          let tok = oauth["accessToken"] as? String, !tok.isEmpty
    else { return nil }
    return tok
}

// MARK: - Dates
let isoFrac: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
let isoPlain: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()
func parseDate(_ s: String) -> Date? { isoFrac.date(from: s) ?? isoPlain.date(from: s) }

// MARK: - Fetch
func fetchUsage() -> FetchResult {
    guard let token = keychainToken() else { return .noToken }
    var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
    req.timeoutInterval = 10
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("claude-cli/2.1.169 (external, cli)", forHTTPHeaderField: "User-Agent")

    let sem = DispatchSemaphore(value: 0)
    var result: FetchResult = .failed("no response")
    URLSession.shared.dataTask(with: req) { data, resp, err in
        defer { sem.signal() }
        if let err = err { result = .failed(err.localizedDescription); return }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard let data = data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { result = .failed("bad response (HTTP \(code))"); return }
        if code == 401 || code == 403 { result = .authExpired; return }
        if code == 429 {
            let ra = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after")
            result = .rateLimited(ra.flatMap { Double($0) }); return
        }
        if code != 200 { result = .failed("HTTP \(code)"); return }
        func win(_ key: String) -> UsageWindow? {
            guard let w = obj[key] as? [String: Any], let u = w["utilization"] as? Double else { return nil }
            return UsageWindow(utilization: u, resetsAt: (w["resets_at"] as? String).flatMap(parseDate))
        }
        let extra = (obj["extra_usage"] as? [String: Any])?["is_enabled"] as? Bool ?? false
        result = .ok(LiveUsage(fiveHour: win("five_hour"), sevenDay: win("seven_day"),
                               sevenDayOpus: win("seven_day_opus"), sevenDaySonnet: win("seven_day_sonnet"),
                               extraEnabled: extra))
    }.resume()
    _ = sem.wait(timeout: .now() + 12)
    return result
}

// MARK: - Formatting
func formatCountdown(to date: Date) -> String {
    let s = max(0, Int(date.timeIntervalSinceNow))
    let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

// MARK: - Gauge ring (animated)
final class GaugeView: NSView {
    var value: Double = 0            // target, 0…1
    var displayed: Double = 0        // animated, eases toward value
    var phase: CGFloat = 0           // advances continuously while animating
    var percentText: String = "—"
    var warning = false

    private func accentColors() -> [CGColor] { [HUD.cyan.cgColor, HUD.violet.cgColor] }

    /// Advance one animation frame. Returns false once everything is settled.
    @discardableResult
    func step(_ dt: CFTimeInterval) -> Bool {
        phase += CGFloat(dt) * 2.0
        let delta = value - displayed
        displayed += delta * 0.16
        if abs(delta) < 0.0008 { displayed = value }
        needsDisplay = true
        return abs(value - displayed) > 0.0008
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let lw: CGFloat = 7
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - lw / 2 - 3

        // tick marks
        let ticks = 48
        for i in 0..<ticks {
            let a = CGFloat(i) / CGFloat(ticks) * .pi * 2
            let r1 = radius + lw / 2 + 2, r2 = r1 + (i % 4 == 0 ? 3.5 : 1.8)
            ctx.move(to: CGPoint(x: c.x + cos(a) * r1, y: c.y + sin(a) * r1))
            ctx.addLine(to: CGPoint(x: c.x + cos(a) * r2, y: c.y + sin(a) * r2))
        }
        ctx.setLineWidth(1); ctx.setStrokeColor(HUD.ink.withAlphaComponent(0.14).cgColor); ctx.strokePath()

        // track
        ctx.setLineWidth(lw); ctx.setLineCap(.round)
        ctx.addArc(center: c, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.setStrokeColor(HUD.ink.withAlphaComponent(0.09).cgColor); ctx.strokePath()

        // progress arc
        let v = max(0, min(1, displayed))
        let start = CGFloat.pi / 2
        let end = start - .pi * 2 * CGFloat(v)
        guard v > 0.0008 else {
            drawPercent(ctx, center: c); return
        }

        if warning {
            // offline / stale: dim grey arc with a slow "searching" pulse — no flow,
            // deliberately neutral so it never reads like a high-usage alarm.
            let a = 0.24 + 0.22 * (0.5 + 0.5 * sin(phase * 1.3))
            ctx.setLineWidth(lw); ctx.setLineCap(.round)
            ctx.addArc(center: c, radius: radius, startAngle: start, endAngle: end, clockwise: true)
            ctx.setStrokeColor(NSColor(white: 0.72, alpha: a).cgColor)
            ctx.strokePath()
            drawPercent(ctx, center: c)
            return
        }

        // steady gradient arc with a soft glow
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 5, color: HUD.cyan.withAlphaComponent(0.45).cgColor)
        ctx.setLineWidth(lw); ctx.setLineCap(.round)
        ctx.addArc(center: c, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: accentColors() as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: bounds.minX, y: bounds.maxY),
                               end: CGPoint(x: bounds.maxX, y: bounds.minY), options: [])
        ctx.restoreGState()

        // a gentle "comet" of energy that drifts along the filled arc and loops
        let head = Double((phase * 0.16).truncatingRemainder(dividingBy: 1.0))   // 0…1 along filled arc
        let steps = 16
        let tail = 0.16                                                          // comet length (fraction of arc)
        ctx.saveGState()
        ctx.setLineWidth(lw); ctx.setLineCap(.round)
        for i in 0..<steps {
            let f = head - tail * (Double(i) / Double(steps))
            if f < 0 { continue }
            let a0 = start - .pi * 2 * CGFloat(v) * CGFloat(f)
            let a1 = a0 - .pi * 2 * CGFloat(v) * CGFloat(tail / Double(steps)) - 0.001
            let bright = CGFloat(1.0 - Double(i) / Double(steps))
            ctx.setShadow(offset: .zero, blur: 3 * bright, color: HUD.cyan.withAlphaComponent(0.4 * bright).cgColor)
            ctx.setStrokeColor(HUD.ink.withAlphaComponent(0.4 * bright).cgColor)
            ctx.beginPath()
            ctx.addArc(center: c, radius: radius, startAngle: a0, endAngle: a1, clockwise: true)
            ctx.strokePath()
        }
        ctx.restoreGState()

        drawPercent(ctx, center: c)
    }

    private func drawPercent(_ ctx: CGContext, center c: CGPoint) {

        // centered percentage
        let s = NSAttributedString(string: percentText, attributes: [
            .font: HUD.mono(21, .medium), .foregroundColor: HUD.ink.withAlphaComponent(0.96),
            .paragraphStyle: HUD.center(),
        ])
        let sz = s.size()
        s.draw(at: CGPoint(x: c.x - sz.width / 2, y: c.y - sz.height / 2))
    }
}

// MARK: - HUD button (hover + press feedback)
final class HUDButton: NSButton {
    var accent: NSColor = HUD.cyan
    var label: String = ""
    private var hovering = false
    private var pressed = false

    convenience init(label: String, accent: NSColor) {
        self.init(frame: .zero)
        self.label = label; self.accent = accent
        isBordered = false
        wantsLayer = true
        setButtonType(.momentaryChange)
        title = ""
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovering = true; needsDisplay = true; NSCursor.pointingHand.set() }
    override func mouseExited(with e: NSEvent) { hovering = false; pressed = false; needsDisplay = true; NSCursor.arrow.set() }
    override func mouseDown(with e: NSEvent) {
        pressed = true; needsDisplay = true
        super.mouseDown(with: e)          // blocks until mouseUp, fires action
        pressed = false; needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        let fillA: CGFloat = pressed ? 0.32 : (hovering ? 0.16 : 0.05)
        let strokeA: CGFloat = pressed ? 1.0 : (hovering ? 0.9 : 0.32)
        let textA: CGFloat = pressed ? 1.0 : (hovering ? 1.0 : 0.78)
        if hovering || pressed {
            ctx.setShadow(offset: .zero, blur: pressed ? 10 : 6, color: accent.withAlphaComponent(0.6).cgColor)
        }
        accent.withAlphaComponent(fillA).setFill(); path.fill()
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        accent.withAlphaComponent(strokeA).setStroke(); path.lineWidth = 1; path.stroke()
        let s = NSAttributedString(string: label, attributes: [
            .font: HUD.mono(10, .semibold), .foregroundColor: accent.withAlphaComponent(textA),
            .kern: 1.6, .paragraphStyle: HUD.center(),
        ])
        let sz = s.size()
        s.draw(at: CGPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2))
    }
}

// MARK: - HUD panel
final class HUDView: NSView {
    let sessionGauge = GaugeView()
    let weekGauge = GaugeView()
    let titleLabel = HUDView.label(11, .semibold, 0.55, kern: 4)
    let sessionTitle = HUDView.label(10, .semibold, 0.45, kern: 3)
    let weekTitle = HUDView.label(10, .semibold, 0.45, kern: 3)
    let sessionReset = HUDView.label(10, .regular, 0.6)
    let weekReset = HUDView.label(10, .regular, 0.6)
    let extraLabel = HUDView.label(9, .regular, 0.5, kern: 1)
    let footerLabel = HUDView.label(9, .regular, 0.4, kern: 1)
    let loginButton = HUDButton(label: "⏻", accent: HUD.cyan)
    let refreshButton = HUDButton(label: "↻ SYNC", accent: HUD.cyan)
    let quitButton = HUDButton(label: "QUIT", accent: HUD.red)

    static func label(_ size: CGFloat, _ w: NSFont.Weight = .regular, _ alpha: CGFloat = 0.6, kern: CGFloat = 0) -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.font = HUD.mono(size, w); f.textColor = HUD.ink.withAlphaComponent(alpha); f.alignment = .center
        f.drawsBackground = false; f.isBezeled = false; f.isEditable = false; f.isSelectable = false
        f.cell?.usesSingleLineMode = true; f.tag = Int(kern * 100)
        return f
    }
    private func setText(_ field: NSTextField, _ text: String) {
        field.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: field.font!, .foregroundColor: field.textColor!,
            .paragraphStyle: HUD.center(), .kern: CGFloat(field.tag) / 100,
        ])
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        titleLabel.frame    = NSRect(x: 0,   y: 224, width: 300, height: 16)
        sessionGauge.frame  = NSRect(x: 30,  y: 110, width: 100, height: 100)
        weekGauge.frame     = NSRect(x: 170, y: 110, width: 100, height: 100)
        sessionTitle.frame  = NSRect(x: 20,  y: 90,  width: 120, height: 14)
        weekTitle.frame     = NSRect(x: 160, y: 90,  width: 120, height: 14)
        sessionReset.frame  = NSRect(x: 20,  y: 74,  width: 120, height: 14)
        weekReset.frame     = NSRect(x: 160, y: 74,  width: 120, height: 14)
        extraLabel.frame    = NSRect(x: 0,   y: 52,  width: 300, height: 12)
        footerLabel.frame   = NSRect(x: 0,   y: 36,  width: 300, height: 12)
        loginButton.frame   = NSRect(x: 268, y: 223, width: 24,  height: 18)   // small toggle, top-right
        loginButton.toolTip = "Launch at login"
        refreshButton.frame = NSRect(x: 66,  y: 6,   width: 92,  height: 22)
        quitButton.frame    = NSRect(x: 170, y: 6,   width: 64,  height: 22)
        for v in [titleLabel, sessionTitle, weekTitle, sessionReset, weekReset, extraLabel, footerLabel] { addSubview(v) }
        for v in [sessionGauge, weekGauge] { addSubview(v) }
        for v in [loginButton, refreshButton, quitButton] { addSubview(v) }
        setText(titleLabel, "CLAUDE  USAGE")
        setText(sessionTitle, "SESSION · 5H")
        setText(weekTitle, "WEEK · 7D")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setStrokeColor(HUD.ink.withAlphaComponent(0.12).cgColor); ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: 24, y: 32)); ctx.addLine(to: CGPoint(x: 276, y: 32)); ctx.strokePath()
    }

    /// Reset gauges to 0 so they animate up on appear.
    func beginAppear() { sessionGauge.displayed = 0; weekGauge.displayed = 0 }

    func animationTick(_ dt: CFTimeInterval) {
        sessionGauge.step(dt); weekGauge.step(dt)
    }

    func render(sessionPct: Double?, sessionReset rs: Date?, weekPct: Double?, weekReset rw: Date?,
                extra: String?, footer: String, warning: Bool) {
        sessionGauge.warning = warning; weekGauge.warning = warning
        sessionGauge.value = (sessionPct ?? 0) / 100
        weekGauge.value = (weekPct ?? 0) / 100
        sessionGauge.percentText = sessionPct.map { "\(Int($0.rounded()))%" } ?? "—"
        weekGauge.percentText = weekPct.map { "\(Int($0.rounded()))%" } ?? "—"
        setText(sessionReset, rs.map { "RESETS \(formatCountdown(to: $0))" } ?? " ")
        setText(weekReset, rw.map { "RESETS \(formatCountdown(to: $0))" } ?? " ")
        setText(extraLabel, extra ?? " ")
        setText(footerLabel, footer)
        sessionGauge.needsDisplay = true; weekGauge.needsDisplay = true
    }
}

// MARK: - App
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var hud: HUDView!
    var pollTimer: Timer?
    var animTimer: Timer?
    var lastUsage: LiveUsage?
    var lastUpdated: Date?
    var lastAttempt: Date?                     // last time we *tried* to fetch (success or not)
    let pollInterval: TimeInterval = 300       // 5 min steady-state poll
    let openMinGap: TimeInterval = 90          // don't refetch on open more often than this

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 252))
        let blur = NSVisualEffectView(frame: container.bounds)
        blur.material = .hudWindow; blur.blendingMode = .behindWindow; blur.state = .active
        blur.autoresizingMask = [.width, .height]; container.addSubview(blur)
        hud = HUDView(frame: container.bounds)
        hud.autoresizingMask = [.width, .height]; container.addSubview(hud)
        hud.refreshButton.target = self; hud.refreshButton.action = #selector(refreshTapped)
        hud.quitButton.target = self; hud.quitButton.action = #selector(quit)
        hud.loginButton.target = self; hud.loginButton.action = #selector(toggleLogin)

        let vc = NSViewController(); vc.view = container
        popover.contentViewController = vc
        popover.contentSize = container.frame.size
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = NSAppearance(named: .vibrantDark)
        popover.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.image = makeIcon(session: 0, week: 0, warning: false)
        statusItem.button?.imagePosition = .imageLeft

        enableLoginItemIfNeeded()
        updateLoginLabel()

        // Show the on-disk cache instantly; only hit the network if it's stale.
        // This stops relaunches from each firing a request (the main 429 cause).
        if let (u, ts) = loadCache() {
            lastUsage = u; lastUpdated = ts
            renderUsage(u, footer: "CACHED \(hhmmss(ts))")
            let age = Date().timeIntervalSince(ts)
            if age >= pollInterval { refresh() } else { scheduleNextFetch(after: pollInterval - age) }
        } else {
            refresh()
        }
    }

    // MARK: popover + animation lifecycle
    @objc func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // refetch on open only if we haven't tried recently — avoids open-storms
        if lastAttempt == nil || Date().timeIntervalSince(lastAttempt!) > openMinGap { refresh() }
    }
    func popoverDidShow(_ n: Notification) { hud.beginAppear(); startAnim() }
    func popoverDidClose(_ n: Notification) { stopAnim() }

    private func startAnim() {
        stopAnim()
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.hud.animationTick(1.0 / 30.0) }
        RunLoop.main.add(t, forMode: .common)   // keeps firing during popover tracking
        animTimer = t
    }
    private func stopAnim() { animTimer?.invalidate(); animTimer = nil }

    private func scheduleNextFetch(after t: TimeInterval) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { [weak self] _ in self?.refresh() }
    }

    // MARK: login item
    func enableLoginItemIfNeeded() {
        if #available(macOS 13.0, *), SMAppService.mainApp.status == .notRegistered {
            try? SMAppService.mainApp.register()
        }
    }
    @objc func toggleLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                else { try SMAppService.mainApp.register() }
            } catch { NSLog("login item toggle failed: \(error)") }
        }
        updateLoginLabel()
    }
    func updateLoginLabel() {
        var accent = NSColor(white: 0.45, alpha: 1)   // off
        var tip = "Launch at login: OFF"
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled: accent = HUD.cyan; tip = "Launch at login: ON"
            case .requiresApproval: accent = HUD.amber; tip = "Launch at login: approve in System Settings"
            default: break
            }
        }
        hud.loginButton.accent = accent
        hud.loginButton.toolTip = tip
        hud.loginButton.needsDisplay = true
    }

    // MARK: actions
    @objc func quit() { NSApp.terminate(nil) }

    @objc func refreshTapped() {
        hud.render(sessionPct: lastUsage?.fiveHour?.utilization, sessionReset: lastUsage?.fiveHour?.resetsAt,
                   weekPct: lastUsage?.sevenDay?.utilization, weekReset: lastUsage?.sevenDay?.resetsAt,
                   extra: nil, footer: "SYNCING…", warning: false)
        refresh()
    }

    @objc func refresh() {
        lastAttempt = Date()
        DispatchQueue.global(qos: .utility).async {
            let result = fetchUsage()
            DispatchQueue.main.async { self.apply(result) }
        }
    }

    private func hhmmss(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: d)
    }

    func renderUsage(_ u: LiveUsage, footer: String) {
        var bits: [String] = []
        if let o = u.sevenDayOpus { bits.append("OPUS 7D \(Int(o.utilization.rounded()))%") }
        if let s = u.sevenDaySonnet { bits.append("SONNET 7D \(Int(s.utilization.rounded()))%") }
        hud.render(sessionPct: u.fiveHour?.utilization, sessionReset: u.fiveHour?.resetsAt,
                   weekPct: u.sevenDay?.utilization, weekReset: u.sevenDay?.resetsAt,
                   extra: bits.isEmpty ? nil : bits.joined(separator: "   "),
                   footer: footer, warning: false)
        statusItem.button?.image = makeIcon(session: u.fiveHour?.utilization ?? 0, week: u.sevenDay?.utilization ?? 0, warning: false)
        statusItem.button?.attributedTitle = barTitle(u.fiveHour?.utilization, u.sevenDay?.utilization, warning: false)
    }

    func renderWarning(_ msg: String) {
        let u = lastUsage
        hud.render(sessionPct: u?.fiveHour?.utilization, sessionReset: u?.fiveHour?.resetsAt,
                   weekPct: u?.sevenDay?.utilization, weekReset: u?.sevenDay?.resetsAt,
                   extra: lastUpdated.map { "LAST GOOD \(hhmmss($0))" }, footer: msg, warning: true)
        statusItem.button?.image = makeIcon(session: u?.fiveHour?.utilization ?? 0, week: u?.sevenDay?.utilization ?? 0, warning: true)
        statusItem.button?.attributedTitle = barTitle(u?.fiveHour?.utilization, u?.sevenDay?.utilization, warning: true)
    }

    func apply(_ result: FetchResult) {
        switch result {
        case .ok(let u):
            lastUsage = u; lastUpdated = Date(); saveCache(u)
            renderUsage(u, footer: "SYNCED \(hhmmss(lastUpdated!))")
            scheduleNextFetch(after: pollInterval)
        case .rateLimited(let ra):
            let wait = max(ra ?? 150, 60)
            // not an outage — keep the last good numbers in normal colors
            if let u = lastUsage { renderUsage(u, footer: "RATE-LIMITED · RETRY \(Int(wait))s") }
            else { renderWarning("RATE-LIMITED · RETRY \(Int(wait))s") }
            scheduleNextFetch(after: wait)
        case .authExpired:
            renderWarning("TOKEN EXPIRED — RUN  claude"); scheduleNextFetch(after: 300)
        case .noToken:
            renderWarning("NO CLAUDE LOGIN — RUN  claude"); scheduleNextFetch(after: 300)
        case .failed(let m):
            renderWarning("OFFLINE · \(m.uppercased())"); scheduleNextFetch(after: 90)
        }
    }

    // MARK: disk cache — lets relaunches/opens show instantly without a network call
    private func cacheURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("ClaudeUsage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.json")
    }
    func saveCache(_ u: LiveUsage) {
        func enc(_ w: UsageWindow?) -> [String: Any]? {
            guard let w = w else { return nil }
            var d: [String: Any] = ["u": w.utilization]
            if let r = w.resetsAt { d["r"] = isoFrac.string(from: r) }
            return d
        }
        var obj: [String: Any] = ["ts": isoFrac.string(from: Date()), "extra": u.extraEnabled]
        if let s = enc(u.fiveHour) { obj["five"] = s }
        if let w = enc(u.sevenDay) { obj["week"] = w }
        if let o = enc(u.sevenDayOpus) { obj["opus"] = o }
        if let s = enc(u.sevenDaySonnet) { obj["sonnet"] = s }
        if let data = try? JSONSerialization.data(withJSONObject: obj) { try? data.write(to: cacheURL()) }
    }
    func loadCache() -> (LiveUsage, Date)? {
        guard let data = try? Data(contentsOf: cacheURL()),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tss = obj["ts"] as? String, let ts = parseDate(tss) else { return nil }
        func dec(_ k: String) -> UsageWindow? {
            guard let d = obj[k] as? [String: Any], let u = d["u"] as? Double else { return nil }
            return UsageWindow(utilization: u, resetsAt: (d["r"] as? String).flatMap(parseDate))
        }
        return (LiveUsage(fiveHour: dec("five"), sevenDay: dec("week"),
                          sevenDayOpus: dec("opus"), sevenDaySonnet: dec("sonnet"),
                          extraEnabled: (obj["extra"] as? Bool) ?? false), ts)
    }

    func barTitle(_ s: Double?, _ w: Double?, warning: Bool) -> NSAttributedString {
        let txt = " \(s.map { String(Int($0.rounded())) } ?? "–")·\(w.map { String(Int($0.rounded())) } ?? "–")"
        let color = warning ? NSColor(white: 0.55, alpha: 1) : HUD.ink.withAlphaComponent(0.85)
        return NSAttributedString(string: txt, attributes: [.font: HUD.mono(11, .medium), .foregroundColor: color, .kern: 0.5])
    }

    func makeIcon(session: Double, week: Double, warning: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()
        let ctx = NSGraphicsContext.current!.cgContext
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        func ring(_ r: CGFloat, _ v: Double, _ color: NSColor) {
            ctx.setLineWidth(2); ctx.setLineCap(.round)
            ctx.addArc(center: c, radius: r, startAngle: 0, endAngle: .pi * 2, clockwise: false)
            ctx.setStrokeColor(HUD.ink.withAlphaComponent(0.22).cgColor); ctx.strokePath()
            let vv = max(0, min(1, v / 100))
            if vv > 0 {
                ctx.addArc(center: c, radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - .pi * 2 * CGFloat(vv), clockwise: true)
                ctx.setStrokeColor(color.cgColor); ctx.strokePath()
            }
        }
        ring(7, session, warning ? NSColor(white: 0.7, alpha: 1) : HUD.cyan)
        ring(3.4, week, warning ? NSColor(white: 0.5, alpha: 1) : HUD.violet)
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
