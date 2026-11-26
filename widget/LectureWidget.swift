// 수업 전사 위젯 — 바탕화면 위젯(작은 정사각형) + 메뉴 막대 아이콘. live.py 를 대신 불러 준다.
//   [수업|회의|기타] 고르고 ▶ → 시간표에서 지금 수업(회의)을 찾아 그 과목 사전으로 live.py start
//   ⏸ = live.py stop(쉬는시간, ▶ 하면 같은 파일에 이어 씀) · ⏹ = stop 하고 끝(out/.finished/ 에 끝 표시를 남김)
// 시간표 = 캘린더 앱의 일정(제목에 사전 이름이 들어 있으면 그 과목). out/.schedule.json 이 있고 지금을 덮으면 그걸 먼저 쓴다(README).
// 상태는 live.py 의 out/.state.json 으로만 본다.
import AppKit
import EventKit
import SwiftUI

let liveScript = Bundle.main.object(forInfoDictionaryKey: "LiveScript") as? String ?? ""
let liveDir = URL(fileURLWithPath: liveScript).deletingLastPathComponent()
let outDir = liveDir.appendingPathComponent("out")
let dictDir = liveDir.deletingLastPathComponent().appendingPathComponent("dict")
let defaults = UserDefaults.standard

func pidAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
func norm(_ s: String) -> String { s.filter { !" :：·・-_()".contains($0) }.lowercased() }
let dictStems: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: dictDir.path)) ?? [])
    .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()

// MARK: 시간표
struct Event {
    let title: String, start: Date, end: Date, kind: String, course: String?
    /// "알고리즘 12주차 — 중간 발표" → ("알고리즘", "12주차 — 중간 발표")
    var split: (name: String, week: String) {
        if let r = title.range(of: #"\s*\d+주차"#, options: .regularExpression) {
            return (String(title[..<r.lowerBound]), title[r.lowerBound...].trimmingCharacters(in: .whitespaces))
        }
        return (title, "")
    }
}

final class Schedule {
    private let store = EKEventStore()
    private var asked = false
    private let iso = ISO8601DateFormatter()

    func cached() -> (events: [Event], covers: Bool) {
        guard let d = try? Data(contentsOf: outDir.appendingPathComponent(".schedule.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let rows = j["events"] as? [[String: Any]] else { return ([], false) }
        let evs: [Event] = rows.compactMap { r in
            guard let t = r["title"] as? String, let s = (r["start"] as? String).flatMap(iso.date),
                  let e = (r["end"] as? String).flatMap(iso.date) else { return nil }
            return Event(title: t, start: s, end: e, kind: r["kind"] as? String ?? "수업", course: r["course"] as? String)
        }
        let until = (j["until"] as? String).flatMap(iso.date) ?? .distantPast
        return (evs, until > Date())
    }

    func calendar(_ done: @escaping ([Event]) -> Void) {
        let fetch = {
            let cal = Calendar.current, now = Date()
            let p = self.store.predicateForEvents(withStart: cal.startOfDay(for: now),
                                                  end: cal.date(byAdding: .day, value: 8, to: now)!, calendars: nil)
            let evs = self.store.events(matching: p).filter { !$0.isAllDay }.map { e -> Event in
                let t = e.title ?? ""
                return Event(title: t, start: e.startDate, end: e.endDate, kind: t.contains("회의") ? "회의" : "수업",
                             course: dictStems.first { norm(t).contains(norm($0)) })
            }
            DispatchQueue.main.async { done(evs) }
        }
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { fetch(); return }
        guard !asked else { done([]); return }
        asked = true
        store.requestFullAccessToEvents { ok, _ in if ok { fetch() } else { DispatchQueue.main.async { done([]) } } }
    }

    /// 시작 20분 전 ~ 끝나고 15분까지를 「지금」으로 본다
    static func pick(_ evs: [Event], kind: String, now: Date = Date()) -> (now: Event?, next: Event?) {
        let mine = evs.filter { $0.kind == kind && $0.title != "근로" }
        let cur = mine.filter { $0.start.addingTimeInterval(-20 * 60) <= now && now <= $0.end.addingTimeInterval(15 * 60) }
            .min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
        let nxt = mine.filter { $0.start > now }.min { $0.start < $1.start }
        return (cur, nxt)
    }
}

// MARK: 상태
final class Model: ObservableObject {
    enum Phase { case idle, starting, recording, stopping, paused }
    @Published var phase: Phase = .idle
    @Published var mode: String = defaults.string(forKey: "mode") ?? "수업" { didSet { defaults.set(mode, forKey: "mode"); refreshSchedule() } }
    @Published var current: Event?
    @Published var next: Event?
    @Published var title = defaults.string(forKey: "activeTitle") ?? ""
    @Published var sub = defaults.string(forKey: "activeSub") ?? ""
    @Published var started: Date?
    @Published var message = ""
    @Published var now = Date()
    let schedule = Schedule()
    private var stopThenFinish = false
    private var tick = 0

    init() {
        if defaults.string(forKey: "pausedDay") == Self.today, defaults.array(forKey: "activeArgs") != nil { phase = .paused }
        refreshSchedule(); poll()
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    static var today: String { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }

    func refreshSchedule() {
        let (evs, covers) = schedule.cached()
        let apply: ([Event]) -> Void = { evs in
            let p = Schedule.pick(evs, kind: self.mode); self.current = p.now; self.next = p.next
        }
        if covers { apply(evs) } else { schedule.calendar { cal in apply(cal.isEmpty ? evs : cal) } }
    }

    func readState() -> [String: Any]? {
        guard let d = try? Data(contentsOf: outDir.appendingPathComponent(".state.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let pid = j["pid"] as? Int, pidAlive(Int32(pid)) else { return nil }
        return j
    }

    func poll() {
        now = Date()
        tick += 1
        if tick % 40 == 0 && (phase == .idle) { refreshSchedule() }   // 20초마다
        if let st = readState() {
            if phase != .stopping {
                if phase == .idle, let c = st["course"] as? String {   // 채팅 등 밖에서 시작한 전사
                    title = c; sub = ""
                    defaults.set(dictStems.contains(c) ? [c] : [c, "--raw"], forKey: "activeArgs")
                    defaults.set(title, forKey: "activeTitle"); defaults.set(sub, forKey: "activeSub")
                }
                phase = .recording
            }
            if let f = st["file"] as? String { defaults.set(f, forKey: "activeFile") }
            if started == nil, let s = st["started"] as? String {
                let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                started = f.date(from: String(s.prefix(19)))
            }
        } else {
            started = nil
            switch phase {
            case .recording: phase = .paused; rememberPause()
            case .stopping: if stopThenFinish { finish() } else { phase = .paused; rememberPause() }
            default: break
            }
        }
    }

    // MARK: 동작
    /// ▶ — 쉬는시간이면 같은 과목으로 재개, 아니면 시간표에서 지금 것을 찾아 시작
    func play(manual course: String? = nil) {
        if phase == .paused, let a = defaults.stringArray(forKey: "activeArgs") { launch(a); return }
        refreshSchedule()
        let ev = current
        var args: [String]
        if let c = course {
            args = [c]; title = c; sub = "직접 고름"
        } else if mode == "수업" {
            guard let ev else { flash("지금 시간표에 수업이 없어요"); return }
            let (name, week) = ev.split
            title = name; sub = week
            args = ev.course.map { [$0] } ?? [name, "--raw"]
        } else if mode == "기타" {
            let f = DateFormatter(); f.dateFormat = "HHmm"
            title = "기타"; sub = ""
            args = ["기타 \(f.string(from: Date()))", "--raw"]   // 같은 날 여러 번이어도 파일이 섞이지 않게
        } else {
            let name = ev?.title ?? "회의"
            title = name; sub = ev.map { timeRange($0) } ?? ""
            args = [name, "--raw"]
        }
        defaults.set(title, forKey: "activeTitle"); defaults.set(sub, forKey: "activeSub")
        defaults.set(args, forKey: "activeArgs")
        launch(args)
    }

    private func launch(_ args: [String]) {
        phase = .starting; message = ""
        let log = outDir.appendingPathComponent(".widget.log")
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let fh = FileHandle(forWritingAtPath: log.path)
        _ = try? fh?.seekToEnd()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [liveScript, "start"] + args + ["--no-view"]
        p.standardOutput = fh; p.standardError = fh
        p.terminationHandler = { proc in
            DispatchQueue.main.async {
                guard proc.terminationStatus != 0, self.phase == .starting else { return }
                let tail = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").last.map(String.init)
                self.flash(tail ?? "시작 실패")
                self.phase = defaults.string(forKey: "pausedDay") == Self.today ? .paused : .idle
            }
        }
        do { try p.run() } catch { flash("python3 실행 실패"); phase = .idle; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            if self.phase == .starting { self.flash("15초째 시작 안 됨 — out/.widget.log"); self.phase = .idle }
        }
    }

    private func runStop(thenFinish: Bool) {
        stopThenFinish = thenFinish
        phase = .stopping
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [liveScript, "stop"]
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try? p.run(); p.waitUntilExit()
            DispatchQueue.main.async { self.poll() }
        }
    }

    func pause() { runStop(thenFinish: false) }
    func stop() { if phase == .recording { runStop(thenFinish: true) } else { finish() } }

    private func rememberPause() { defaults.set(Self.today, forKey: "pausedDay") }

    /// ⏹ — 「이 전사본 끝남」 표시를 out/.finished/ 에 남긴다(후처리 스크립트가 지켜볼 수 있게)
    private func markFinished() {
        guard let f = defaults.string(forKey: "activeFile") else { return }
        let dir = outDir.appendingPathComponent(".finished")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = URL(fileURLWithPath: f).deletingPathExtension().lastPathComponent
        let body = try? JSONSerialization.data(withJSONObject: ["file": f, "at": ISO8601DateFormatter().string(from: Date())])
        try? body?.write(to: dir.appendingPathComponent(name + ".json"))
    }

    private func finish() {
        markFinished()
        for k in ["pausedDay", "activeArgs", "activeTitle", "activeSub", "activeFile"] { defaults.removeObject(forKey: k) }
        phase = .idle; stopThenFinish = false
        flash("끝 — 전사본 저장됨", seconds: 12)
        title = ""; sub = ""
        refreshSchedule()
    }

    func flash(_ s: String, seconds: Double = 6) {
        message = s
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { if self.message == s { self.message = "" } }
    }

    func openFolder() { NSWorkspace.shared.open(outDir) }
    func openViewer() {
        let cmd = outDir.appendingPathComponent(".watch.command")
        try? "#!/bin/zsh\nclear\nexec /usr/bin/python3 '\(liveScript)' watch\n".write(to: cmd, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cmd.path)
        NSWorkspace.shared.open(cmd)
    }

    var elapsed: String {
        guard let s = started else { return "" }
        let t = max(0, Int(now.timeIntervalSince(s)))
        return String(format: "%d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60)
    }
}

func timeRange(_ e: Event) -> String {
    let f = DateFormatter(); f.dateFormat = "H:mm"
    return "\(f.string(from: e.start))–\(f.string(from: e.end))"
}

func whenLabel(_ e: Event) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "ko_KR")
    f.dateFormat = Calendar.current.isDateInToday(e.start) ? "H:mm" : "E H:mm"
    return f.string(from: e.start)
}

// MARK: 화면 — macOS 바탕화면 위젯(소형)과 같은 크기·모양
// 바탕화면 위젯 창은 180pt 칸 안에 8pt 여백을 두고 그려진다 → 보이는 크기 164, 위젯 사이 16 (알림 센터 창 크기로 확인)
let CELL: CGFloat = 180, INSET: CGFloat = 8, W: CGFloat = CELL - 2 * INSET

/// 바탕화면에 놓인 시스템 위젯 칸 하나의 왼쪽 위(CG 좌표, 위가 0). 없으면 nil
func widgetAnchor() -> CGPoint? {
    let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let cells = l.compactMap { w -> CGRect? in
        guard (w[kCGWindowOwnerName as String] as? String) == "알림 센터" || (w[kCGWindowOwnerName as String] as? String) == "Notification Center",
              let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        return r.width.truncatingRemainder(dividingBy: CELL) == 0 && r.height.truncatingRemainder(dividingBy: CELL) == 0 ? r : nil
    }
    return cells.min { ($0.minY, $0.minX) < ($1.minY, $1.minX) }?.origin
}
let widgetBG = Color(nsColor: NSColor(name: nil) { a in
    a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.955, alpha: 1)
})

struct ModeSwitch: View {
    @Binding var mode: String
    var body: some View {
        HStack(spacing: 2) {
            ForEach(["수업", "회의", "기타"], id: \.self) { m in
                Text(m).font(.system(size: 11, weight: .semibold))
                    .frame(width: 32, height: 20)
                    .background(mode == m ? Color(nsColor: .controlBackgroundColor) : .clear, in: Capsule())
                    .foregroundStyle(mode == m ? .primary : .secondary)
                    .contentShape(Capsule())
                    .onTapGesture { mode = m }
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.08), in: Capsule())
    }
}

struct RoundButton: View {
    let symbol: String, enabled: Bool, prominent: Bool, action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                .frame(width: 38, height: 38)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background(prominent ? Color.accentColor : Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.3)
    }
}

struct WidgetView: View {
    @ObservedObject var m: Model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                ModeSwitch(mode: $m.mode).disabled(m.phase != .idle).opacity(m.phase == .idle ? 1 : 0.4)
                Spacer()
                Circle().fill(dot).frame(width: 8, height: 8)
            }
            Spacer(minLength: 6)
            Text(heading).font(.system(size: 15, weight: .semibold)).lineLimit(2).minimumScaleFactor(0.8)
            Text(m.message.isEmpty ? detail : m.message)
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(m.phase == .recording && m.message.isEmpty ? Color.red : Color.secondary)
                .lineLimit(2).padding(.top, 2)
            Spacer(minLength: 6)
            HStack(spacing: 0) {
                playButton
                Spacer()
                RoundButton(symbol: "pause.fill", enabled: m.phase == .recording, prominent: false) { m.pause() }
                Spacer()
                RoundButton(symbol: "stop.fill", enabled: m.phase == .recording || m.phase == .paused, prominent: false) { m.stop() }
            }
        }
        .padding(14)
        .frame(width: W, height: W)
        .background(widgetBG, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contextMenu {
            Menu("과목 직접 골라 시작") {
                ForEach(dictStems, id: \.self) { s in Button(s) { m.play(manual: s) } }
            }.disabled(m.phase != .idle)
            Button("실시간 보기 창 열기") { m.openViewer() }
            Button("전사본 폴더 열기") { m.openFolder() }
            Divider()
            Button(AppDelegate.shared.onTop ? "✓ 항상 위에" : "항상 위에") { AppDelegate.shared.toggleOnTop() }
            Button("위젯 끄기") { NSApp.terminate(nil) }
        }
    }

    var playButton: some View {
        let ok = m.phase == .idle || m.phase == .paused
        return RoundButton(symbol: "play.fill", enabled: ok, prominent: ok) { m.play() }
    }

    var heading: String {
        switch m.phase {
        case .starting, .recording, .stopping, .paused: return m.title.isEmpty ? m.mode : m.title
        case .idle:
            if m.mode == "기타" { return "기타" }
            if let e = m.current { return m.mode == "수업" ? e.split.name : e.title }
            return m.mode == "수업" ? "지금 수업 없음" : "회의"
        }
    }

    var detail: String {
        switch m.phase {
        case .starting: return "시작하는 중…"
        case .stopping: return "남은 소리 확정 중…"
        case .recording: return "● " + m.elapsed + (m.sub.isEmpty ? "" : "  ·  " + m.sub)
        case .paused: return "쉬는시간 — ▶ 로 이어서"
        case .idle:
            if m.mode == "기타" { return "시간표 없이 바로 시작" }
            if let e = m.current { return [m.mode == "수업" ? e.split.week : "", timeRange(e)].filter { !$0.isEmpty }.joined(separator: " · ") }
            if let n = m.next { return "다음 · \(whenLabel(n)) \(m.mode == "수업" ? n.split.name : n.title)" }
            return m.mode == "회의" ? "▶ 누르면 바로 시작" : ""
        }
    }

    var dot: Color {
        switch m.phase {
        case .recording: return .red
        case .paused: return .orange
        case .starting, .stopping: return .yellow
        case .idle: return .secondary.opacity(0.4)
        }
    }
}

// MARK: 창·메뉴 막대
final class WidgetWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override func sendEvent(_ e: NSEvent) {
        super.sendEvent(e)
        if e.type == .leftMouseUp { snap() }   // 끌어 놓으면 시스템 위젯 칸에 맞춘다
    }
    /// 시스템 위젯 칸(180pt 격자, 여백 8)에 맞춘다. 시스템 위젯이 없으면 그대로
    func snap(preferNextToAnchor: Bool = false) {
        guard let a = widgetAnchor(), let scr = screen ?? NSScreen.main else { return }
        let H = NSScreen.screens.first?.frame.height ?? scr.frame.height   // CG 좌표는 첫 화면 위가 0
        var x = frame.minX, top = H - frame.maxY                          // 지금 왼쪽 위(CG)
        if preferNextToAnchor { x = a.x + CELL + INSET; top = a.y + INSET }
        let cx = ((x - INSET - a.x) / CELL).rounded(), cy = ((top - INSET - a.y) / CELL).rounded()
        let nx = a.x + cx * CELL + INSET, ntop = a.y + cy * CELL + INSET
        setFrameOrigin(NSPoint(x: nx, y: H - ntop - W))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static var shared: AppDelegate!
    let model = Model()
    var window: WidgetWindow!
    var item: NSStatusItem!
    var onTop: Bool { defaults.bool(forKey: "onTop") }

    func applicationDidFinishLaunching(_ n: Notification) {
        AppDelegate.shared = self
        window = WidgetWindow(contentRect: NSRect(x: 0, y: 0, width: W, height: W), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: WidgetView(m: model))
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        applyLevel()
        if window.setFrameUsingName("LectureWidget3") {
            window.setContentSize(NSSize(width: W, height: W)); window.snap()
        } else {
            if let s = NSScreen.main?.visibleFrame { window.setFrameTopLeftPoint(NSPoint(x: s.minX + 200, y: s.maxY - 10)) }
            window.snap(preferNextToAnchor: true)   // 처음엔 첫 시스템 위젯 오른쪽 칸
        }
        window.setFrameAutosaveName("LectureWidget3")
        window.orderFront(nil)

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let menu = NSMenu(); menu.delegate = self
        item.menu = menu
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateIcon() }
        updateIcon()
    }

    func applyLevel() {
        window.level = onTop ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }
    func toggleOnTop() { defaults.set(!onTop, forKey: "onTop"); applyLevel() }

    // 메뉴 막대는 다른 아이콘들처럼 흑백 SF Symbol(template)
    func updateIcon() {
        let (sym, text): (String, String) = {
            switch model.phase {
            case .recording: return ("record.circle", " " + model.elapsed)
            case .paused: return ("pause.circle", "")
            case .starting, .stopping: return ("ellipsis.circle", "")
            case .idle: return ("waveform", "")
            }
        }()
        let img = NSImage(systemSymbolName: sym, accessibilityDescription: "수업 전사")?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        img?.isTemplate = true
        item.button?.image = img
        item.button?.title = text
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ t: String, _ sel: Selector, _ on: Bool = true) {
            let i = NSMenuItem(title: t, action: on ? sel : nil, keyEquivalent: ""); i.target = self; menu.addItem(i)
        }
        let p = model.phase
        let head = p == .idle ? (model.mode == "기타" ? "기타" : nil) ?? (model.current.map { model.mode == "수업" ? $0.split.name : $0.title } ?? "\(model.mode) — 지금 일정 없음") : model.title
        menu.addItem(withTitle: head, action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        add(p == .paused ? "재개" : "시작", #selector(mStart), p == .idle || p == .paused)
        add("일시정지", #selector(mPause), p == .recording)
        add("정지", #selector(mStop), p == .recording || p == .paused)
        menu.addItem(.separator())
        add(model.mode == "수업" ? "✓ 수업" : "수업", #selector(mClass), p == .idle)
        add(model.mode == "회의" ? "✓ 회의" : "회의", #selector(mMeeting), p == .idle)
        add(model.mode == "기타" ? "✓ 기타" : "기타", #selector(mOther), p == .idle)
        menu.addItem(.separator())
        add("위젯 앞으로 가져오기", #selector(mShow))
        add(onTop ? "✓ 위젯 항상 위에" : "위젯 항상 위에", #selector(mOnTop))
        add("실시간 보기 창 열기", #selector(mViewer))
        add("전사본 폴더 열기", #selector(mFolder))
        menu.addItem(.separator())
        add("위젯 끄기", #selector(mQuit))
    }

    @objc func mStart() { model.play() }
    @objc func mPause() { model.pause() }
    @objc func mStop() { model.stop() }
    @objc func mClass() { model.mode = "수업" }
    @objc func mMeeting() { model.mode = "회의" }
    @objc func mOther() { model.mode = "기타" }
    @objc func mShow() { window.level = .floating; window.orderFrontRegardless(); DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.applyLevel() } }
    @objc func mOnTop() { toggleOnTop() }
    @objc func mViewer() { model.openViewer() }
    @objc func mFolder() { model.openFolder() }
    @objc func mQuit() { NSApp.terminate(nil) }
}

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let d = AppDelegate()
        app.delegate = d
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
