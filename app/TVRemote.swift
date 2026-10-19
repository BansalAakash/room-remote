// TVRemote.swift: menu bar remote for the Mi TV. UI and client logic only; every action is a JSON call to
// the local helper (tvd.py on 127.0.0.1:8787). Preview and self-test code is in TVRemoteDebug.swift.
import SwiftUI
import AppKit
import Combine
import Carbon.HIToolbox
import CoreImage.CIFilterBuiltins
import ServiceManagement

enum Config {
    /// Everything the app runs lives under one folder: tv/ (the TV helper) and room/ (the plug script and its keys).
    /// Set ROOM_REMOTE_HOME to use another folder.
    static let supportRoot: URL = {
        if let custom = ProcessInfo.processInfo.environment["ROOM_REMOTE_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RoomRemote", isDirectory: true)
    }()
    static let helperDirectory = supportRoot.appendingPathComponent("tv", isDirectory: true)
    static let baseURL = "http://127.0.0.1:8787"
    static let width: CGFloat = 340, height: CGFloat = 512
}

/// True only in the preview build: no helper calls, no polling, no timers that touch the helper.
enum Preview {
#if DEBUG_TOOLS
    static let offline = Launch.offline
#else
    static let offline = false
#endif
}

/// Debug-only log line for the proof scripts. Every call site that has a literal sits inside #if DEBUG_TOOLS.
#if DEBUG_TOOLS
func trace(_ line: String) { print(line); fflush(stdout) }
#else
@inline(__always) func trace(_ line: String) {}
#endif

/// One blue accent; everything else is primary-based (DESIGN_SPEC 11).
enum Theme {
    static let accent = Color(nsColor: .systemBlue), red = Color(nsColor: .systemRed), grey = Color(nsColor: .systemGray)
    static let secondary = Color.primary.opacity(0.66), key = Color.primary.opacity(0.06)
    static let keyHover = Color.primary.opacity(0.10), keyFill = Color.primary.opacity(0.10)
    static let strong = Color.primary.opacity(0.14)
    static let row = Color.primary.opacity(0.10), trough = Color.primary.opacity(0.12)
    static let hairline = Color.primary.opacity(0.09)
}

extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }

/// The six streaming apps, in chip order. `package` is what the helper reports as the running app.
struct TVApp: Identifiable {
    let id: String, name: String, package: String
    static let all = [
        TVApp(id: "netflix", name: "Netflix", package: "com.netflix.ninja"),
        TVApp(id: "youtube", name: "YouTube", package: "com.google.android.youtube.tv"),
        TVApp(id: "prime", name: "Prime Video", package: "com.amazon.amazonvideo.livingroom"),
        TVApp(id: "hotstar", name: "JioHotstar", package: "in.startv.hotstar"),
        TVApp(id: "sonyliv", name: "Sony LIV", package: "com.sonyliv"),
        TVApp(id: "zee5", name: "ZEE5", package: "com.graymatrix.did"),
    ]
    static func name(_ id: String) -> String { all.first { $0.id == id }?.name ?? id }
}

func friendlyAppName(_ package: String) -> String? {
    let p = package.trimmed
    if p.isEmpty { return nil }
    if p.lowercased().contains("launcher") { return "Home" }
    return TVApp.all.first { $0.package == p }?.name ?? p.split(separator: ".").last.map { String($0).capitalized } ?? p
}

// MARK: - Wire types

struct TVStatus: Decodable, Equatable {
    let state: String, app: String?
    var volume: Int?, muted: Bool?, volumeMax: Int?
    enum CodingKeys: String, CodingKey { case state, app, volume, muted, volumeMax = "volume_max" }
}

struct VolumeReply: Decodable { let volume: Int? }
struct PowerReply: Decodable { let ok: Bool? }
/// `kind` is "user", "tool" or "text".
struct AssistantEvent: Decodable, Equatable { let kind: String, text: String }

struct AssistantState: Decodable {
    let running: Bool, events: [AssistantEvent], finalText: String?, error: String?, elapsed: Double?
    enum CodingKeys: String, CodingKey { case running, events, error, elapsed, finalText = "final" }
}

/// A refusal is flagged, so the header can leave it out while a State panel shows (WORK_ORDER 3.2).
struct Notice: Equatable { let text: String, isError: Bool; var refusal = false }

// MARK: - HTTP client

enum APIError: Error { case helperDown, timedOut, server(code: Int, message: String) }

/// The words a person sees for a failed request. Helper internals never reach the screen.
func describeError(_ error: Error) -> String {
    switch error {
    case APIError.helperDown: return "Can't reach Mi TV"
    case APIError.server(_, let text) where text.localizedCaseInsensitiveContains("awake"): return "Mi TV is asleep"
    default: return "Didn't go through. Try again."
    }
}

enum API {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()
    @discardableResult
    static func call(_ path: String, method: String = "GET", json: [String: Any]? = nil, timeout: TimeInterval = 10) async throws -> Data {
        guard let url = URL(string: Config.baseURL + path) else { throw APIError.helperDown }
        if Preview.offline { return Data("{}".utf8) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let result: (Data, URLResponse)
        do { result = try await session.data(for: request) }
        catch let error as URLError where error.code == .timedOut { throw APIError.timedOut }
        catch { throw APIError.helperDown }
        guard let http = result.1 as? HTTPURLResponse else { throw APIError.helperDown }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(code: http.statusCode, message: errorMessage(result.0))
        }
        return result.0
    }

    static func json<T: Decodable>(_ type: T.Type, _ path: String, method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval = 10) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await call(path, method: method, json: body, timeout: timeout))
    }

    static func post(_ path: String, _ body: [String: Any]? = nil, timeout: TimeInterval = 10) async throws {
        try await call(path, method: "POST", json: body ?? [:], timeout: timeout)
    }

    private static func errorMessage(_ data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let text = object["error"] as? String {
            return text
        }
        return (String(data: data, encoding: .utf8) ?? "").trimmed
    }
}

// MARK: - Helper process (tvd.py)

@MainActor
final class HelperProcess {
    static let shared = HelperProcess()
    private var process: Process?
    private var log: FileHandle?
    private var lastLaunch = Date.distantPast
    private var launching = false

    /// Launches the helper unless one was started under 15 s ago, then waits up to 10 s for /status.
    func ensureRunning() async {
        guard !Preview.offline, !launching else { return }
        launching = true
        defer { launching = false }
        if (try? await API.call("/status", timeout: 1)) != nil { return }
        if Date().timeIntervalSince(lastLaunch) >= 15 { launch() }
        for _ in 0..<10 {
            if (try? await API.call("/status", timeout: 1)) != nil { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func stop() {
        if let process, process.isRunning { process.terminate() }
        process = nil
        try? log?.close()
        log = nil
    }

    private func launch() {
        lastLaunch = Date()
        let fm = FileManager.default
        let logURL = Config.helperDirectory.appendingPathComponent("cam/tvd.log")
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logURL.path) { fm.createFile(atPath: logURL.path, contents: nil) }
        try? log?.close()
        log = try? FileHandle(forWritingTo: logURL)
        _ = log?.seekToEndOfFile()
        let child = Process()
        child.executableURL = Config.helperDirectory.appendingPathComponent(".venv/bin/python")
        child.arguments = ["tvd.py"]
        child.currentDirectoryURL = Config.helperDirectory
        child.standardOutput = log ?? FileHandle.nullDevice
        child.standardError = log ?? FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
        environment["PYTHONUNBUFFERED"] = "1"
        child.environment = environment
        do {
            try child.run()
            process = child
        } catch {
            process = nil
            try? log?.write(contentsOf: Data("TVRemote: could not start tvd.py: \(error)\n".utf8))
        }
    }
}

// MARK: - Pure rules (no UI, no network: the self-test drives these)

/// Three failed /status polls in a row mark the helper down; any success resets (DESIGN_SPEC 6.1).
struct HelperHealth: Equatable {
    private(set) var up = false, failures = 0
    var downSince: Date?
    /// Failures 1 and 2: the remote dims and keeps its last state.
    var dimmed: Bool { up && (1...2).contains(failures) }

    mutating func poll(ok: Bool, now: Date) {
        if ok { up = true; failures = 0; downSince = nil; return }
        failures += 1
        if failures >= 3 { up = false; downSince = downSince ?? now }
    }
}

/// The volume on screen and what was asked for (DESIGN_SPEC 4.1). One target; polls never overwrite it.
struct VolumeModel: Equatable {
    private(set) var level: Int?, target: Int?           // the TV's reading; the asked-for level
    private(set) var holdUntil = Date.distantPast, muted = false, muteHoldUntil = Date.distantPast
    var shown: Int? { target ?? level }

    mutating func request(_ value: Int, ceiling: Int) -> Bool {
        let unmute = muted
        muted = false; muteHoldUntil = .distantPast
        target = min(max(value, 0), ceiling)
        return unmute
    }

    mutating func poll(level reading: Int?, muted reading2: Bool?, now: Date) {
        if target == nil, now >= holdUntil { level = reading }
        if now >= muteHoldUntil { muted = reading2 ?? false }
    }

    mutating func toggleMute(now: Date) { muted.toggle(); muteHoldUntil = now.addingTimeInterval(3) }

    /// The TV confirmed `sent`; a newer target that arrived meanwhile stays pending.
    mutating func confirm(_ sent: Int, reply: Int?, now: Date) {
        if target == sent { target = nil }
        level = reply ?? sent
        holdUntil = now.addingTimeInterval(2)
    }

    mutating func fail(_ sent: Int) {
        if target == sent { target = nil }
        holdUntil = .distantPast
    }
}

enum SleepTap: Equatable { case arm, sleep, ignored }

/// Sleep takes two taps: the first arms for 3 s; a tap 0.4 s or more later, within 3 s, sleeps.
struct SleepArm: Equatable {
    private(set) var armedAt: Date?
    var isArmed: Bool { armedAt != nil }

    mutating func tap(now: Date) -> SleepTap {
        if let armedAt, now.timeIntervalSince(armedAt) < 3 {
            guard now.timeIntervalSince(armedAt) >= 0.4 else { return .ignored }
            clear()
            return .sleep
        }
        armedAt = now
        return .arm
    }

    mutating func clear() { armedAt = nil }
}

enum PanelState: Equatable { case waking, offline, asleep, connecting, didntConnect }

/// The panel the facts call for, in precedence order; nil when the TV is on.
func statePanel(waking: Bool, helperUp: Bool, downFor: TimeInterval, tvState: String?) -> PanelState? {
    if waking { return .waking }
    guard helperUp else { return downFor >= 20 ? .didntConnect : .connecting }
    switch tvState {
    case "on", nil: return nil
    case "standby": return .asleep
    default: return .offline
    }
}

/// A held run (an Ask in progress) hides only Connecting; Asleep, Waking, Offline and Didn't connect show (3.2).
func visiblePanel(_ panel: PanelState?, held: Bool) -> PanelState? { held && panel == .connecting ? nil : panel }

/// A held run is lost while the helper is down (WORK_ORDER 1.1). Stop is off while lost.
func runLost(held: Bool, up: Bool) -> Bool { held && !up }

/// The strip's word: "Waiting" while a State panel shows (WORK_ORDER 1.1), else "Working".
func workingWord(panel: Bool) -> String { panel ? "Waiting" : "Working" }

/// The strip's detail after the word (DESIGN_SPEC 3.19). Only a run with no panel and no loss shows a step and a count.
func workingDetail(panel: Bool, lost: Bool, step: String, elapsed: Int) -> String? {
    panel || lost ? nil : "· \(step) · \(elapsed) s"
}

/// The strip's VoiceOver label (WORK_ORDER 1.2). The element opens the transcript, so it never says "Stop".
func workingLabel(panel: Bool, lost: Bool, step: String, elapsed: Int) -> String {
    if panel { return "Waiting. Show steps." }
    if lost { return "Working. Show steps." }
    return "Working, \(step), \(elapsed) seconds. Show steps."
}

// MARK: - Remote model

@MainActor
final class RemoteModel: ObservableObject {
    @Published var status: TVStatus?
    @Published var health = HelperHealth()
    @Published var volume = VolumeModel()
    @Published var wakeStarted: Date?
    @Published private(set) var sleepArm = SleepArm()
    @Published private(set) var notice: Notice?
    /// The label of a field action in flight ("Opening Netflix"); Return waits for it.
    @Published private(set) var pending: String?
    @Published private(set) var recentApps: [String]
    @Published private(set) var clock = Date()
    /// True from the moment the surface opens until the helper's deliberate check of the TV answers.
    @Published private(set) var checking = false
    private(set) var surfaceOpen = false
    private var lastPowerAt = Date.distantPast, powerBusy = false
    private var keyQueue: [String] = [], keyDraining = false
    private var volumeRunning = false, unmutePending = false
    private var armTask: Task<Void, Never>?, noticeTask: Task<Void, Never>?
    init() {
        recentApps = UserDefaults.standard.stringArray(forKey: "recentApps") ?? []
        health.downSince = Date()
        guard !Preview.offline else { return }
        Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                if !self.health.up { await HelperProcess.shared.ensureRunning() }
                try? await Task.sleep(for: .seconds(self.surfaceOpen ? 2 : 8))
            }
        }
        Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self.clock = Date()
            }
        }
    }

    var isOn: Bool { status?.state == "on" }
    /// From the wake call until the TV reads on, for at most 120 s.
    var isWaking: Bool { wakeStarted.map { !isOn && Date() < $0.addingTimeInterval(120) } ?? false }
    var displayVolume: Int? { volume.shown }
    var volumeCeiling: Int { status?.volumeMax ?? 100 }

    var currentAppId: String? {
        guard let package = status?.app else { return nil }
        return TVApp.all.first { $0.package == package }?.id
    }

    var panel: PanelState? {
        if checking && status != nil { return nil }       // never flash a verdict from stale data while the TV is being checked
        return statePanel(waking: isWaking, helperUp: health.up,
                   downFor: clock.timeIntervalSince(health.downSince ?? clock), tvState: status?.state)
    }

    /// Why the TV cannot take keys, volume or transport now (DESIGN_SPEC 4.3), or nil when it is on.
    func refusal() -> String? {
        guard health.up else { return "Can't reach Mi TV" }
        switch status?.state {
        case "on": return nil
        case "standby": return "Mi TV is asleep"
        default: return "Mi TV is offline"
        }
    }

    private func ready(_ what: String) -> Bool {
        guard let reason = refusal() else { return true }
        refuse(what, reason)
        return false
    }

    /// A refused key, command or row action: logged, then shown in row 2 unless a State panel shows (3.2).
    func refuse(_ what: String, _ text: String, error: Bool = true) {
        #if DEBUG_TOOLS
        trace("REFUSED \(what) \(text)")
        #endif
        flash(text, error: error, refusal: true)
    }

    func setSurfaceOpen(_ open: Bool) {
        let opening = open && !surfaceOpen
        surfaceOpen = open
        if !open { disarm() }
        if opening { checkNow() }
    }

    /// Opening the surface reads the TV's state then, with a patient check, instead of trusting what a background loop last saw.
    private func checkNow() {
        guard !Preview.offline else { return }
        checking = true
        flash("Checking Mi TV", error: false)
        Task {
            await refresh(fresh: true)
            checking = false
            if notice?.text == "Checking Mi TV" { notice = nil; noticeTask?.cancel() }
        }
    }

    func refresh(fresh deliberate: Bool = false) async {
        guard !Preview.offline else { return }
        let wasOn = isOn
        do {
            let fresh = try await API.json(TVStatus.self, deliberate ? "/status?fresh=1" : "/status", timeout: deliberate ? 20 : 2.5)
            health.poll(ok: true, now: Date())
            status = fresh
            volume.poll(level: fresh.volume, muted: fresh.muted, now: Date())
        } catch {
            health.poll(ok: false, now: Date())
            if !health.up { status = nil }
        }
        if isOn { wakeStarted = nil }
        if let started = wakeStarted, Date() >= started.addingTimeInterval(120) {
            wakeStarted = nil
            flash("Mi TV didn't wake. Try again.", error: true)
        }
        if wasOn != isOn { disarm() }
    }

    @discardableResult
    func press(_ key: String) -> Bool {
        guard ready(key) else { return false }
        keyQueue.append(key)
        guard !keyDraining else { return true }
        keyDraining = true
        Task {
            while !keyQueue.isEmpty {
                let batch = keyQueue
                keyQueue.removeAll()
                do {
                    // The helper runs keys behind its TV lock, so a key can wait for a long text or volume job.
                    try await API.post("/key", ["keys": batch, "gap": 0.06], timeout: 90)
                } catch {
                    keyQueue.removeAll()
                    flash(describeError(error), error: true)
                }
            }
            keyDraining = false
        }
        return true
    }

    @discardableResult
    func toggleMute() -> Bool {
        guard press("MUTE") else { return false }
        volume.toggleMute(now: Date())
        return true
    }

    /// Plus, minus, "[" and "]": the target is the shown level moved by one. Never VOLUME_UP or VOLUME_DOWN.
    func nudge(_ delta: Int) {
        if let base = displayVolume { setVolume(base + delta) }
    }

    @discardableResult
    func setVolume(_ level: Int) -> Bool {
        guard ready("volume") else { return false }
        if volume.request(level, ceiling: volumeCeiling) { unmutePending = true }
        if !volumeRunning {
            sendVolume()
        } else if let goal = volume.target {
            // A run is already in flight: send the new goal now. The helper keeps one goal (latest wins) and redirects
            // the run instead of finishing the old target first.
            Task { _ = try? await API.json(VolumeReply.self, "/vol", method: "POST", body: ["level": goal], timeout: 120) }
        }
        return true
    }

    private func sendVolume() {
        volumeRunning = true
        Task {
            while let sent = volume.target {
                do {
                    if unmutePending {
                        unmutePending = false
                        try await API.post("/key", ["keys": ["MUTE"], "gap": 0.06], timeout: 90)
                    }
                    let reply = try await API.json(VolumeReply.self, "/vol", method: "POST", body: ["level": sent], timeout: 120)
                    volume.confirm(sent, reply: reply.volume, now: Date())
                } catch {
                    volume.fail(sent)
                    flash("Couldn't set the volume.", error: true)
                    await refresh()
                }
            }
            volumeRunning = false
        }
    }

    func wake() {
        if !health.up { refuse("wake", "Can't reach Mi TV") } else if isOn { refuse("wake", "Already on", error: false) } else { power(sleeping: false) }
    }

    /// The header key and Return on "sleep". Returns true when the sleep was sent.
    @discardableResult
    func sleepTap() -> Bool {
        switch sleepArm.tap(now: Date()) {
        case .arm:
            armTask?.cancel()
            if !Preview.offline {
                armTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    if !Task.isCancelled { self?.sleepArm.clear() }
                }
            }
            return false
        case .sleep:
            disarm()
            power(sleeping: true)
            return true
        case .ignored:
            return false
        }
    }

    func disarm() {
        armTask?.cancel()
        sleepArm.clear()
    }

    /// Two-second debounce; the helper's answer is awaited, then the state is read again.
    private func power(sleeping: Bool) {
        let now = Date()
        guard !powerBusy, now.timeIntervalSince(lastPowerAt) >= 2 else { return }
        lastPowerAt = now
        powerBusy = true
        if !sleeping { wakeStarted = now }
        flash(sleeping ? "Going to sleep" : "Waking Mi TV", error: false)
        Task {
            do {
                // The helper gives a wake up to 120 s, so the client waits longer than that.
                let reply = try await API.json(PowerReply.self, sleeping ? "/sleep" : "/wake", method: "POST", body: [:], timeout: 130)
                if reply.ok == false { powerFailed(sleeping) }
            } catch {
                powerFailed(sleeping)
            }
            powerBusy = false
            await refresh()
        }
    }

    private func powerFailed(_ sleeping: Bool) {
        if sleeping { flash("Didn't go through. Try again.", error: true); return }
        wakeStarted = nil
        flash("Mi TV didn't wake. Try again.", error: true)
    }

    /// Runs one field action (DESIGN_SPEC 7.2 and 7.3). Returns true when the text should clear.
    func perform(_ action: FieldAction) async -> Bool {
        switch action {
        case .nothing, .ask:
            return false
        case .open(let id):
            guard ready(id) else { return false }
            let ok = await post("/app", ["name": id], pending: "Opening \(TVApp.name(id))", success: "Opening \(TVApp.name(id))")
            if ok { addRecent(id) }
            return ok
        case .search(let query):
            guard ready("search") else { return false }
            return await post("/youtube", ["q": query], pending: "Searching YouTube", success: "Searching YouTube")
        case .type(let text):
            guard text.count <= 200 else {
                flash("Keep it to 200 characters", error: true)
                return false
            }
            guard ready("type") else { return false }
            return await post("/text", ["text": text], timeout: 90, pending: "Typing on the TV", success: "Typed on the TV")
        case .command(let command):
            return runCommand(command)
        case .sleep:
            if status?.state == "standby" {
                refuse("sleep", "Already asleep", error: false)
                return true
            }
            return ready("sleep") && sleepTap()
        }
    }

    private func runCommand(_ command: Command) -> Bool {
        switch command {
        case .volume(let level): return setVolume(level)
        case .mute: return toggleMute()
        case .wake: wake(); return true
        case .pause, .play: return press("MEDIA_PLAY_PAUSE")
        case .rewind: return press("MEDIA_REWIND")
        case .forward: return press("MEDIA_FAST_FORWARD")
        case .back: return press("BACK")
        case .home: return press("HOME")
        case .menu: return press("MENU")
        }
    }

    private func post(_ path: String, _ body: [String: Any], timeout: TimeInterval = 30,
                      pending label: String, success: String) async -> Bool {
        pending = label
        defer { pending = nil }
        do {
            try await API.post(path, body, timeout: timeout)
            flash(success, error: false)
            await refresh()
            return true
        } catch {
            flash(describeError(error), error: true)
            return false
        }
    }

    private func addRecent(_ id: String) {
        recentApps = Array(([id] + recentApps.filter { $0 != id }).prefix(6))
        UserDefaults.standard.set(recentApps, forKey: "recentApps")
    }

    /// Info clears after 2.5 s, an error after 4 s; a new message replaces the old at once.
    func flash(_ text: String, error: Bool, refusal: Bool = false) {
        notice = Notice(text: text, isError: error, refusal: refusal)
        noticeTask?.cancel()
        guard !Preview.offline else { return }   // the preview holds its message
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(error ? 4 : 2.5))
            if !Task.isCancelled { self?.notice = nil }
        }
    }
}

// MARK: - Assistant model

enum SendResult { case started, notice(Notice), failed }

/// Mirrors the helper's assistant run. The helper keeps the conversation, so the transcript is
/// always replaced by the server's list rather than appended to.
@MainActor
final class AssistantModel: ObservableObject {
    @Published var events: [AssistantEvent] = []
    @Published var finalText = ""
    @Published var running = false
    @Published private(set) var starting = false
    @Published private(set) var stopping = false
    @Published var elapsed = 0.0
    /// The held answer and the last failed Ask. Both stay until the next Ask or New chat.
    @Published var answer: String?
    @Published var askError: String?
    private var freshSession = false
    private var watching = false
    init() {
        guard !Preview.offline else { return }
        Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refresh()
                try? await Task.sleep(for: .seconds(self.busy || self.watching ? 0.8 : 5))
            }
        }
    }

    var busy: Bool { running || starting }

    var transcript: [AssistantEvent] {
        let reply = finalText.trimmed
        var items = events
        if !running, !reply.isEmpty, !events.contains(where: { $0.kind == "text" && $0.text.trimmed == reply }) {
            items.append(AssistantEvent(kind: "text", text: reply))
        }
        return items
    }

    func setWatching(_ on: Bool) {
        guard watching != on else { return }
        watching = on
        if on { Task { await refresh() } }
    }

    func refresh() async {
        guard !Preview.offline else { return }
        guard let state = try? await API.json(AssistantState.self, "/assistant", timeout: 5) else { return }
        apply(state)
    }

    private func apply(_ state: AssistantState) {
        if state.events != events { events = state.events }
        let reply = state.finalText ?? ""
        if reply != finalText { finalText = reply }
        let endedNow = running && !state.running
        running = state.running
        elapsed = state.elapsed ?? 0
        guard endedNow else { return }
        if let error = state.error, !error.isEmpty { askError = error }
        else if !reply.trimmed.isEmpty { answer = reply.trimmed }
    }

    func send(_ prompt: String) async -> SendResult {
        let text = prompt.trimmed
        guard !text.isEmpty else { return .failed }
        guard !busy else { return .notice(Notice(text: "Still working. Stop to ask something new.", isError: false)) }
        starting = true
        answer = nil
        askError = nil
        defer { starting = false }
        var body: [String: Any] = ["prompt": text]
        if freshSession { body["new"] = true }
        do {
            try await API.post("/assistant", body, timeout: 10)
            freshSession = false
            running = true
            elapsed = 0
            await refresh()
            return .started
        } catch APIError.server(let code, _) where code == 409 {
            await refresh()
            return .notice(Notice(text: "A run is already going. Stop it first.", isError: true))
        } catch {
            askError = describeError(error)
            return .failed
        }
    }

    func stop() async {
        stopping = true
        defer { stopping = false }
        try? await API.post("/assistant/stop")
        await refresh()
    }

    /// Clears the chat. Returns a message when it could not.
    func reset() async -> Notice? {
        guard !busy else { return Notice(text: "Stop the run before starting a new chat.", isError: true) }
        do {
            try await API.post("/assistant/reset")
            events = []; finalText = ""; answer = nil; askError = nil; elapsed = 0
            freshSession = true
            return nil
        } catch APIError.server(let code, _) where code == 409 {
            return Notice(text: "Stop the run before starting a new chat.", isError: true)
        } catch {
            return Notice(text: describeError(error), isError: true)
        }
    }
}

/// Friendly wording for one tool event. The raw text stays available as a tooltip.
func assistantStep(for raw: String) -> String {
    let text = raw.trimmed
    let lower = text.lowercased()
    let tokens = lower.split(separator: " ").map(String.init)
    if tokens.first == "sleep" { return "Waiting" }
    if tokens.count >= 2 {
        let path = tokens[1].split(separator: "?").first.map(String.init) ?? tokens[1]
        switch (tokens[0], path) {
        case ("get", "/status"): return "Checking the TV"
        case ("get", "/screen"), ("post", "/screen"): return "Looking at the screen"
        case ("post", "/key"): return "Pressing buttons"
        case ("post", "/vol"): return "Setting the volume"
        case ("post", "/youtube"): return "Searching YouTube"
        case ("post", "/netflix"): return "Playing on Netflix"
        case ("post", "/seek"): return "Seeking"
        case ("post", "/wake"): return "Waking the TV"
        case ("post", "/text"): return "Typing"
        case ("post", "/app"): return "Opening an app"
        default: break
        }
    }
    let screenshot = lower == "screen" || lower.hasPrefix("screenshot") || lower.contains(".png")
        || lower.contains(".jpg") || (lower.contains("file_path") && lower.contains("screen"))
    if screenshot { return "Looking at the screen" }
    if text.isEmpty { return "Working" }
    return text.count > 56 ? String(text.prefix(56)).trimmed + "…" : text
}

// MARK: - Shortcut and surface state

@MainActor
final class ShortcutModel: ObservableObject {
    @Published var display: String
    @Published private(set) var recording = false
    @Published var note: String?
    @Published var noteIsError = false
    private var monitor: Any?
    init() { display = UserDefaults.standard.string(forKey: "hotkeyDisplay") ?? "⌥⌘T" }

    func begin() {
        guard monitor == nil else { return }
        recording = true
        note = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            Task { @MainActor in self?.record(event) }
            return nil                                  // the keystroke is consumed
        }
    }

    func end() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func record(_ event: NSEvent) {
        guard recording else { return }
        if event.keyCode == 53 { end(); note = nil; return }                       // Esc
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.isDisjoint(with: [.command, .control, .option]) else {
            note = "Add Command, Control or Option"
            noteIsError = false
            return
        }
        let modifiers = [(NSEvent.ModifierFlags.command, cmdKey), (.control, controlKey), (.option, optionKey), (.shift, shiftKey)]
            .reduce(0) { flags.contains($1.0) ? $0 | $1.1 : $0 }
        let label = (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !label.isEmpty else { return }
        end()
        apply(keyCode: Int(event.keyCode), modifiers: modifiers, label: label)
    }

    /// A combo another app owns keeps the old binding and says so in red.
    private func apply(keyCode: Int, modifiers: Int, label: String) {
        let saved = HotKey.saved
        if keyCode == saved.keyCode && modifiers == saved.modifiers { note = nil; return }
        guard HotKey.register(keyCode: keyCode, modifiers: modifiers) == noErr else {
            note = "Taken by another app"
            noteIsError = true
            return
        }
        display = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & $0.0 != 0 }.map { $0.1 }.joined() + label
        let d = UserDefaults.standard
        d.set(keyCode, forKey: "hotkeyKeyCode")
        d.set(modifiers, forKey: "hotkeyModifiers")
        d.set(display, forKey: "hotkeyDisplay")
        note = nil
    }
}

/// What the field does with plain text: hand it to the assistant (Ask), or type exactly those words into whatever field the TV has focused (Search).
enum FieldMode: String {
    case ask, search
    var toggled: FieldMode { self == .ask ? .search : .ask }
    var placeholder: String { self == .ask ? "Ask Mi TV" : "Type on TV" }
    var symbol: String { self == .ask ? "sparkles" : "keyboard" }
}

/// The one surface's own state: the field text, the suggestion highlight and the transcript flag.
@MainActor
final class SurfaceModel: ObservableObject {
    @Published var text = ""
    /// Ask is the default; the last choice is remembered.
    @Published var mode = FieldMode(rawValue: UserDefaults.standard.string(forKey: "fieldMode") ?? "") ?? .ask {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "fieldMode") }
    }
    /// The row the user moved to with Up or Down. nil means the row the grammar would run.
    @Published var highlight: Int?
    @Published var transcript = false
    @Published private(set) var focusToken = 0
    @Published private(set) var unfocusToken = 0

    func focusField() { focusToken += 1 }
    func unfocusField() { unfocusToken += 1 }
    func clearField() { text = ""; highlight = nil }
    func toggleMode() { mode = mode.toggled; highlight = nil; focusField() }

    /// A printable key pressed on the unfocused remote lands in the field, so no key is lost.
    func typeFromRemote(_ character: String) { text += character; focusField() }
}

// MARK: - Global hotkey (Carbon RegisterEventHotKey: no permission needed)

enum HotKey {
    static var onPress: (() -> Void)?
    private static var ref: EventHotKeyRef?
    private static var handlerInstalled = false
    static var saved: (keyCode: Int, modifiers: Int) {
        let d = UserDefaults.standard
        return (d.object(forKey: "hotkeyKeyCode") as? Int ?? kVK_ANSI_T, d.object(forKey: "hotkeyModifiers") as? Int ?? (cmdKey | optionKey))
    }

    /// Version 1 (round 3) saved Control+Option. Version 2 restores the default once.
    static func migrate() {
        let d = UserDefaults.standard
        guard d.integer(forKey: "hotkeyVersion") < 2 else { return }
        d.set(kVK_ANSI_T, forKey: "hotkeyKeyCode")
        d.set(cmdKey | optionKey, forKey: "hotkeyModifiers")
        d.set("⌥⌘T", forKey: "hotkeyDisplay")
        d.set(2, forKey: "hotkeyVersion")
    }

    @discardableResult
    static func registerSaved() -> OSStatus { register(keyCode: saved.keyCode, modifiers: saved.modifiers) }

    /// Registers the combo. The old binding is released only after the new one is accepted.
    @discardableResult
    static func register(keyCode: Int, modifiers: Int) -> OSStatus {
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.onPress?() }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        var newRef: EventHotKeyRef?
        let id = EventHotKeyID(signature: 0x544D_5258, id: 1)     // 'TMRX'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &newRef)
        #if DEBUG_TOOLS
        trace("HOTKEY registered \(status)")
        #endif
        guard status == noErr else { return status }
        if let ref { UnregisterEventHotKey(ref) }
        ref = newRef
        return noErr
    }
}

// MARK: - Field grammar (DESIGN_SPEC 7.2)

enum Command: Equatable {
    case pause, play, rewind, forward, mute, back, home, menu, wake
    case volume(Int)
    var label: String {
        switch self {
        case .pause: return "Pause"
        case .play: return "Play"
        case .rewind: return "Rewind"
        case .forward: return "Forward"
        case .mute: return "Mute"
        case .back: return "Back"
        case .home: return "Home"
        case .menu: return "Menu"
        case .wake: return "Wake Mi TV"
        case .volume(let level): return "Volume \(min(max(level, 0), 100))"
        }
    }
}

/// `open` carries the app id.
enum FieldAction: Equatable {
    case nothing, open(String), search(String), type(String), ask(String), command(Command), sleep
}

private let appAliases: [(names: [String], id: String)] = [
    (["netflix"], "netflix"), (["youtube", "yt"], "youtube"), (["prime", "prime video", "amazon"], "prime"),
    (["hotstar", "jiohotstar", "jio hotstar"], "hotstar"), (["sonyliv", "sony liv", "sony"], "sonyliv"),
    (["zee5", "zee"], "zee5"),
]

private let commandWords: [String: Command] = [
    "pause": .pause, "play": .play, "rewind": .rewind, "forward": .forward, "mute": .mute,
    "back": .back, "home": .home, "menu": .menu, "wake": .wake,
]

/// The universal field, first match wins. Pure: no side effects. Matching is trimmed and lower-cased;
/// the words after a prefix keep their capitals.
func parseField(_ raw: String, mode: FieldMode = .ask) -> FieldAction {
    let text = raw.trimmed
    let lower = text.lowercased()
    if mode == .search { return text.isEmpty ? .nothing : .type(text) }     // Search mode: exactly the typed words, typed into the TV's focused field
    if text.isEmpty || lower == "ask" || lower == "type" { return .nothing }
    if let words = wordsAfter("ask ", text, lower) { return .ask(words) }
    if let entry = appAliases.first(where: { $0.names.contains(lower) }) { return .open(entry.id) }
    if let words = wordsAfter("yt ", text, lower) ?? wordsAfter("youtube ", text, lower) { return .search(words) }
    if let words = wordsAfter("type ", text, lower) { return .type(words) }
    if lower == "sleep" { return .sleep }
    if let command = commandWords[lower] { return .command(command) }
    for prefix in ["volume ", "vol "] where lower.hasPrefix(prefix) {
        if let level = Int(String(lower.dropFirst(prefix.count)).trimmed) { return .command(.volume(level)) }
    }
    return .ask(text)                       // everything else typed here is for the assistant
}

private func wordsAfter(_ prefix: String, _ text: String, _ lower: String) -> String? {
    guard lower.hasPrefix(prefix) else { return nil }
    let words = String(text.dropFirst(prefix.count)).trimmed
    return words.isEmpty ? nil : words
}

struct SuggestionRow: Identifiable {
    let id: Int
    let title: String
    let action: FieldAction
}

/// The row name of an action. Nil only for nothing: every other action, commands and sleep included, has a row.
func actionVerb(_ action: FieldAction) -> String? {
    switch action {
    case .open(let id): return "Open \(TVApp.name(id))"
    case .search: return "Search YouTube"
    case .type: return "Type on TV"
    case .ask: return "Ask Mi TV"
    case .command(let command): return command.label
    case .sleep: return "Sleep Mi TV"
    case .nothing: return nil
    }
}

/// Bare prefix words, typed with nothing after them: they show no list.
private let barePrefixes: Set<String> = ["ask", "type", "yt"]

/// True when the grammar took a typed prefix ("ask", "yt", "youtube" or "type" with words after it, or a volume
/// level). Such text gets its parsed row only: a whole-text row would send the prefix word as well.
private func typedPrefix(_ text: String) -> Bool {
    let lower = text.lowercased()
    if ["ask ", "yt ", "youtube ", "type "].contains(where: { lower.hasPrefix($0) }) { return true }
    if case .command(.volume(_)) = parseField(text) { return true }
    return false
}

/// Rows are built from parseField, so the lit row runs what Return runs. The parsed action is the first row, and
/// its title names the words it uses ("Search YouTube: barsaat" for "yt barsaat"). Only text with no typed prefix
/// adds the app names it contains and the whole text as each row action. Five at most, no repeats. The empty
/// field and a bare prefix ("ask", "type", "yt") show no list.
func suggestionRows(for text: String, mode: FieldMode = .ask) -> [SuggestionRow] {
    let query = text.trimmed
    let parsed = parseField(query, mode: mode)
    if mode == .search {
        guard parsed != .nothing, let title = rowTitle(parsed) else { return [] }
        return [SuggestionRow(id: 0, title: title, action: parsed)]
    }
    if parsed == .nothing || barePrefixes.contains(query.lowercased()) { return [] }
    var candidates = [parsed]
    if !typedPrefix(query) {
        let lower = query.lowercased()
        let apps = TVApp.all.filter { $0.name.lowercased().contains(lower) }.prefix(2).map { FieldAction.open($0.id) }
        candidates += apps + [.search(query), .ask(query), .type(query)]
    }
    var rows: [SuggestionRow] = []
    for action in candidates {
        guard rows.count < 5, !rows.contains(where: { $0.action == action }), let title = rowTitle(action) else { continue }
        rows.append(SuggestionRow(id: rows.count, title: title, action: action))
    }
    return rows
}

private func rowTitle(_ action: FieldAction) -> String? {
    guard let verb = actionVerb(action) else { return nil }
    switch action {
    case .search(let words), .type(let words), .ask(let words): return "\(verb): \(words)"
    default: return verb
    }
}

/// The row Return runs: the highlighted row while it is still listed, else the row carrying the parsed action.
func litRow(_ rows: [SuggestionRow], text: String, highlight: Int?, mode: FieldMode = .ask) -> Int? {
    if let highlight, rows.indices.contains(highlight) { return highlight }
    return rows.firstIndex { $0.action == parseField(text, mode: mode) }
}

/// What Return runs. The lit row, the click and Return all read this, so they cannot disagree.
func returnAction(text: String, highlight: Int?, mode: FieldMode = .ask) -> FieldAction {
    let rows = suggestionRows(for: text, mode: mode)
    if let index = litRow(rows, text: text, highlight: highlight, mode: mode) { return rows[index].action }
    return parseField(text, mode: mode)
}

/// What the focused field's VoiceOver name says Return does: the one place a Return action is named, since the
/// lit row already shows it on screen. Nil while the field is unfocused, because an unfocused Return presses OK on the TV.
func returnSpeech(text: String, focused: Bool, highlight: Int?, on: Bool, standby: Bool, armed: Bool, mode: FieldMode = .ask) -> String? {
    guard focused, !text.trimmed.isEmpty else { return nil }
    let action = returnAction(text: text, highlight: highlight, mode: mode)
    switch action {
    case .sleep where standby: return "Already asleep"
    case .sleep where armed: return "Return: Sleep Mi TV (tap again)"
    case .command(.wake) where on: return "Already on"
    default: break
    }
    if let verb = actionVerb(action) { return "Return: \(verb)" }
    return "Type your question"
}

// MARK: - Keys and controls

/// A key or capsule: fill 6% (10% on hover), accent while pressed, scale 0.95 held, 50% disabled.
struct KeyStyle<S: Shape>: ButtonStyle {
    let shape: S
    var fill = Theme.key, foreground = Color.primary, pressed = Theme.accent, hover = Theme.keyHover
    var outline = true

    func makeBody(configuration: Configuration) -> some View { KeyBody(configuration: configuration, style: self) }
}

private struct KeyBody<S: Shape>: View {
    let configuration: ButtonStyleConfiguration
    let style: KeyStyle<S>
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false
    var body: some View {
        let down = configuration.isPressed
        configuration.label
            .foregroundStyle(down ? Color.white : style.foreground)
            .background(style.shape.fill(down ? style.pressed : hovering ? style.hover : style.fill))
            .overlay(style.shape.stroke(style.outline ? Theme.hairline : .clear, lineWidth: 0.5))
            .contentShape(style.shape)
            .scaleEffect(down ? 0.95 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { hovering = $0 }
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: down)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// A round key with one glyph. `size` is the drawn diameter. `repeats` (volume plus and minus) acts on
/// press, then every 0.25 s once the press has lasted 0.4 s.
struct RoundKey: View {
    let symbol: String, size: CGFloat, glyph: CGFloat, label: String
    var weight: Font.Weight = .medium
    var prominent = false, lit = false, enabled = true, repeats = false
    let action: () -> Void
    @State private var repeater: Task<Void, Never>?
    var body: some View {
        Button { if !repeats { action() } } label: {
            Image(systemName: symbol).font(.system(size: glyph, weight: weight)).frame(width: size, height: size)
        }
        .buttonStyle(KeyStyle(shape: Circle(), fill: prominent ? Theme.accent : (lit ? Theme.strong : Theme.key),
                              foreground: prominent ? .white : .primary, hover: prominent ? Theme.accent.opacity(0.9) : Theme.keyHover))
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard repeats, enabled, repeater == nil else { return }
                action()
                repeater = Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    while !Task.isCancelled { action(); try? await Task.sleep(for: .milliseconds(250)) }
                }
            }
            .onEnded { _ in repeater?.cancel(); repeater = nil })
        .accessibilityAction(.default) { action() }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

struct Wedge: Shape {
    let center: Double

    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2, inner = outer * 0.34
        let a0 = Angle(degrees: center - 43.5), a1 = Angle(degrees: center + 43.5)
        func point(_ r: CGFloat, _ a: Angle) -> CGPoint {
            CGPoint(x: c.x + r * CGFloat(cos(a.radians)), y: c.y + r * CGFloat(sin(a.radians)))
        }
        var path = Path()
        path.move(to: point(inner, a0))
        path.addLine(to: point(outer, a0))
        path.addArc(center: c, radius: outer, startAngle: a0, endAngle: a1, clockwise: false)
        path.addLine(to: point(inner, a1))
        path.addArc(center: c, radius: inner, startAngle: a1, endAngle: a0, clockwise: true)
        path.closeSubpath()
        return path
    }
}

/// The D-pad, 160 pt across. Chevrons sit 50 pt from centre; OK is a 54 pt circle.
struct DPad: View {
    let press: (String) -> Void
    private let directions: [(key: String, angle: Double, chevron: String, label: String)] = [
        ("DPAD_UP", 270, "chevron.up", "Up"), ("DPAD_RIGHT", 0, "chevron.right", "Right"),
        ("DPAD_DOWN", 90, "chevron.down", "Down"), ("DPAD_LEFT", 180, "chevron.left", "Left"),
    ]
    var body: some View {
        ZStack {
            Circle().strokeBorder(Theme.hairline, lineWidth: 0.5)
            ForEach(directions.indices, id: \.self) { index in
                let d = directions[index], r = d.angle * .pi / 180
                Button { press(d.key) } label: {
                    Image(systemName: d.chevron)
                        .font(.system(size: 15, weight: .bold))
                        .offset(x: CGFloat(cos(r)) * 50, y: CGFloat(sin(r)) * 50)
                        .frame(width: 160, height: 160)
                }
                .buttonStyle(KeyStyle(shape: Wedge(center: d.angle)))
                .accessibilityLabel(d.label)
            }
            Button { press("DPAD_CENTER") } label: {
                Text("OK").font(.system(size: 15, weight: .semibold, design: .rounded)).frame(width: 54, height: 54)
            }
            .buttonStyle(KeyStyle(shape: Circle()))
            .accessibilityLabel("OK")
        }
        .frame(width: 160, height: 160)
    }
}

/// Volume row: minus 32, track 136, value 44, plus 32, mute 32, gaps 8 (308 pt).
struct VolumeRow: View {
    @ObservedObject var model: RemoteModel
    @State private var drag: Int?
    var body: some View {
        let known = model.displayVolume != nil, muted = model.volume.muted
        let shown = drag ?? model.displayVolume
        HStack(spacing: 8) {
            RoundKey(symbol: "minus", size: 32, glyph: 13, label: "Volume down", enabled: known, repeats: true) { model.nudge(-1) }
            VolumeTrack(level: shown ?? 0, ceiling: model.volumeCeiling, enabled: known, dimmed: muted,
                        onDrag: { drag = $0 }, onCommit: { drag = nil; model.setVolume($0) })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Volume")
                .accessibilityValue(muted ? "Muted" : shown.map { "Volume \($0)" } ?? "Volume unknown")
                .accessibilityAdjustableAction { if known { model.nudge($0 == .increment ? 1 : -1) } }
            Text(muted ? "Muted" : shown.map { "\($0)" } ?? "--")
                .font(muted ? .system(size: 13, weight: .semibold) : .system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(muted || model.volume.target != nil || drag != nil ? Theme.secondary : Color.primary)
                .frame(width: 44, alignment: .trailing)
            RoundKey(symbol: "plus", size: 32, glyph: 13, label: "Volume up", enabled: known, repeats: true) { model.nudge(1) }
            RoundKey(symbol: muted ? "speaker.slash" : "speaker.wave.2", size: 32, glyph: 13,
                     label: muted ? "Unmute" : "Mute", lit: muted) { model.toggleMute() }
        }
        .frame(height: 40)
    }
}

struct VolumeTrack: View {
    let level: Int, ceiling: Int, enabled: Bool, dimmed: Bool
    let onDrag: (Int) -> Void
    let onCommit: (Int) -> Void
    private let width: CGFloat = 136
    var body: some View {
        let fraction = CGFloat(min(max(level, 0), ceiling)) / CGFloat(max(ceiling, 1))
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.trough).frame(width: width, height: 4)
            Capsule().fill(Theme.accent).frame(width: width * fraction, height: 4)
            Circle().fill(.white).overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.5))
                .frame(width: 14, height: 14)
                .offset(x: min(max(width * fraction - 7, 0), width - 14))
        }
        .frame(width: width, height: 40)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { onDrag(value(at: $0.location.x)) }
            .onEnded { onCommit(value(at: $0.location.x)) })
        .opacity((enabled ? 1 : 0.5) * (dimmed ? 0.5 : 1))
        .allowsHitTesting(enabled)
    }

    private func value(at x: CGFloat) -> Int {
        Int((min(max(x / width, 0), 1) * CGFloat(max(ceiling, 1))).rounded())
    }
}

struct TransportRow: View {
    @ObservedObject var model: RemoteModel
    var body: some View {
        HStack(spacing: 24) {
            RoundKey(symbol: "backward.fill", size: 40, glyph: 15, label: "Rewind") { model.press("MEDIA_REWIND") }
            RoundKey(symbol: "playpause.fill", size: 56, glyph: 22, label: "Play or pause", prominent: true) { model.press("MEDIA_PLAY_PAUSE") }
            RoundKey(symbol: "forward.fill", size: 40, glyph: 15, label: "Forward") { model.press("MEDIA_FAST_FORWARD") }
        }
        .frame(maxWidth: .infinity, minHeight: 56, maxHeight: 56)
    }
}

// MARK: - State panel

extension PanelState {
    /// The one action's words: Offline and Didn't connect share "Try again" (WORK_ORDER 1.4).
    static let tryAgain = "Try again"

    /// The title; a transient line never repeats it while the panel shows (WORK_ORDER 3.2).
    var title: String {
        switch self {
        case .asleep: return "Mi TV is asleep"
        case .waking: return "Waking Mi TV"
        case .offline: return "Mi TV is offline"
        case .connecting: return "Connecting to Mi TV"
        case .didntConnect: return "Mi TV didn't connect."
        }
    }

    /// The icon and subtitle (WORK_ORDER 2.12). Waking's subtitle is the one time-dependent line.
    func look(elapsed: TimeInterval) -> (symbol: String?, subtitle: String?) {
        switch self {
        case .asleep: return ("moon.zzz", nil)
        case .waking: return (nil, elapsed >= 60 ? "Still waiting. This can take up to 2 minutes." : elapsed >= 15 ? "Taking longer than usual. A deeply asleep TV can take up to 40 s." : "This usually takes a few seconds.")
        case .offline: return ("wifi.exclamationmark", "Check that it is on and on Wi-Fi.")
        case .connecting: return (nil, "This takes a few seconds.")
        case .didntConnect: return ("exclamationmark.triangle", "Check that it is on and on Wi-Fi.")
        }
    }
}

/// The body takeover when the TV cannot be driven (WORK_ORDER 2.12): one view, one five-row table.
struct PanelView: View {
    let panel: PanelState
    @ObservedObject var model: RemoteModel
    @State private var busy = false

    var body: some View {
        let look = panel.look(elapsed: model.clock.timeIntervalSince(model.wakeStarted ?? model.clock))
        VStack(spacing: 0) {
            Group {
                if let symbol = look.symbol { Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(Theme.secondary) }
                else { ProgressView().controlSize(.small) }
            }
            .frame(height: 22)
            Text(panel.title).font(.system(size: 15, weight: .semibold, design: .rounded)).padding(.top, 12)
            if let subtitle = look.subtitle {
                Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center).lineLimit(2).frame(width: 260).padding(.top, 4)
            }
            action.padding(.top, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var action: some View {
        switch panel {
        case .asleep:
            Button { model.wake() } label: { Text("Wake").font(.system(size: 15, weight: .semibold, design: .rounded)).frame(width: 140, height: 44) }
                .buttonStyle(KeyStyle(shape: Capsule(), fill: Theme.accent, foreground: .white, hover: Theme.accent.opacity(0.9)))
                .accessibilityLabel("Wake Mi TV")
        case .offline:
            pill(PanelState.tryAgain) { await model.refresh() }
        case .didntConnect:
            pill(PanelState.tryAgain) {
                await HelperProcess.shared.ensureRunning(); await model.refresh()
                if !model.health.up { model.flash("Still not connected.", error: true) }
            }
        case .waking, .connecting:
            EmptyView()
        }
    }

    /// A 28 pt key. While its work runs, a spinner replaces the label for at least 1.5 s.
    private func pill(_ label: String, _ work: @escaping () async -> Void) -> some View {
        Button {
            busy = true
            Task {
                let started = Date()
                await work()
                try? await Task.sleep(for: .seconds(max(0, 1.5 - Date().timeIntervalSince(started))))
                busy = false
            }
        } label: {
            ZStack { Text(label).opacity(busy ? 0 : 1); if busy { ProgressView().controlSize(.small) } }
                .font(.system(size: 13, weight: .semibold, design: .rounded)).padding(.horizontal, 14).frame(height: 28)
        }
        .buttonStyle(KeyStyle(shape: Capsule(), fill: Theme.keyFill, hover: Theme.strong))
        .disabled(busy)
    }
}

// MARK: - Navigate slot pieces

struct AppChips: View {
    @ObservedObject var model: RemoteModel
    let open: (String) -> Void
    private var chips: [TVApp] {
        let recents = model.recentApps.compactMap { id in TVApp.all.first { $0.id == id } }
        return Array((recents + TVApp.all.filter { app in !recents.contains { $0.id == app.id } }).prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Open").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(chips) { app in
                    let current = app.id == model.currentAppId
                    Button { open(app.id) } label: {
                        Text(app.name)
                            .font(.system(size: 13, weight: current ? .semibold : .medium))
                            .lineLimit(1).minimumScaleFactor(0.8).padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
                    }
                    // The current app is a neutral selected fill, not accent (WORK_ORDER 1.5).
                    .buttonStyle(KeyStyle(shape: Capsule(), fill: current ? Theme.strong : Theme.key,
                                          hover: current ? Theme.strong : Theme.keyHover))
                    .accessibilityLabel(current ? "Open \(app.name), current app" : "Open \(app.name)")
                }
            }
        }
        .frame(width: 308, height: 208)
    }
}

/// Up to five rows, 34 tall, 4 apart, centred in the 208 slot (186 pt for five). The fill runs 16 to 324 and
/// the text sits at x 32, where the field's text sits. The highlighted row is what Return runs.
struct SuggestionList: View {
    let rows: [SuggestionRow]
    let highlight: Int?
    let hover: (Int) -> Void
    let run: (FieldAction) -> Void
    var body: some View {
        VStack(spacing: 4) {
            ForEach(rows) { row in
                Button { run(row.action) } label: {
                    Text(row.title)
                        .font(.system(size: 13, weight: .medium)).lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)
                        .padding(.horizontal, 16)
                }
                .buttonStyle(KeyStyle(shape: RoundedRectangle(cornerRadius: 12, style: .continuous),
                                      fill: row.id == highlight ? Theme.row : .clear, hover: Theme.row, outline: false))
                .onHover { if $0 { hover(row.id) } }
                .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .frame(width: 308, height: 208)
        .animation(.easeOut(duration: 0.15), value: rows.map(\.title))
    }
}

// MARK: - Transcript and steps

private enum TranscriptRow: Identifiable {
    case bubble(Int, AssistantEvent)
    case steps(Int, [String])
    var id: Int {
        switch self {
        case .bubble(let index, _), .steps(let index, _): return index
        }
    }
}

/// The transcript body: Back and New chat on top, then the chat. The only scroll in the app.
struct TranscriptView: View {
    @ObservedObject var assistant: AssistantModel
    @ObservedObject var surface: SurfaceModel
    let model: RemoteModel

    /// Consecutive tool events fold into one step group. A running turn always ends with one.
    private var rows: [TranscriptRow] {
        var result: [TranscriptRow] = []
        for (index, event) in assistant.transcript.enumerated() {
            if event.kind != "tool" {
                result.append(.bubble(index, event))
            } else if case .steps(let start, let steps)? = result.last {
                result[result.count - 1] = .steps(start, steps + [event.text])
            } else {
                result.append(.steps(index, [event.text]))
            }
        }
        var endsWithSteps = false
        if case .steps? = result.last { endsWithSteps = true }
        if assistant.busy && !endsWithSteps { result.append(.steps(assistant.transcript.count, [])) }
        return result
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { surface.transcript = false } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                        Text("Back").font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .padding(.horizontal, 12).frame(height: 28)
                }
                .buttonStyle(KeyStyle(shape: Capsule(), fill: Theme.keyFill, hover: Theme.strong))
                Spacer()
                Button {
                    Task { if let note = await assistant.reset() { model.flash(note.text, error: note.isError) } }
                } label: {
                    Text("New chat").font(.system(size: 13, weight: .semibold, design: .rounded)).padding(.horizontal, 12).frame(height: 28)
                }
                .buttonStyle(KeyStyle(shape: Capsule(), fill: Theme.keyFill, hover: Theme.strong))
                .disabled(assistant.busy)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if rows.isEmpty { emptyState }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { position, row in
                        rowView(row, live: assistant.busy && position == rows.count - 1)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("Ask Mi TV to do something on the TV.")
            Text("Can't see inside Netflix, JioHotstar or other protected apps.").lineLimit(2)
        }
        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
        .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 60)
    }

    @ViewBuilder
    private func rowView(_ row: TranscriptRow, live: Bool) -> some View {
        switch row {
        case .bubble(_, let event) where event.kind == "user":
            HStack(spacing: 0) {
                Spacer(minLength: 48)
                Text(event.text)
                    .font(.system(size: 13)).foregroundStyle(.white).padding(12)
                    .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(Theme.accent))
            }
        case .bubble(_, let event):
            Text(event.text).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        case .steps(_, let steps):
            StepStatusLine(steps: steps, live: live, elapsed: Int(assistant.elapsed))
        }
    }
}

/// Tool steps for one turn: a 28 pt line that expands on tap into a plain list.
struct StepStatusLine: View {
    let steps: [String]
    let live: Bool
    let elapsed: Int
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.spring(response: 0.30, dampingFraction: 0.90)) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    if live {
                        Text(steps.last.map { assistantStep(for: $0) } ?? "Working").lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(elapsed) s").monospacedDigit()
                    } else {
                        Text(steps.count == 1 ? "1 step" : "\(steps.count) steps")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .bold)).rotationEffect(.degrees(expanded ? 90 : 0))
                        Spacer(minLength: 0)
                    }
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, minHeight: 28, maxHeight: 28, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, raw in Text(assistantStep(for: raw)).lineLimit(1).help(raw) }
                }
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
            }
        }
    }
}

// MARK: - Settings

/// The one small Settings window: the shortcut, its recorder, and Quit (DESIGN_SPEC 10).
struct SettingsView: View {
    @ObservedObject var shortcut: ShortcutModel
    @State private var quitHover = false
    var body: some View {
        VStack(spacing: 0) {
            Text("Shortcut").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary)
            Spacer(minLength: 8)
            if shortcut.recording {
                Text("Press the new shortcut").font(.system(size: 15, weight: .semibold, design: .rounded))
                Text("Esc cancels").font(.system(size: 11)).foregroundStyle(Theme.secondary).padding(.top, 2)
            } else {
                Text(shortcut.display)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .accessibilityLabel("Shortcut, \(shortcut.display)")
            }
            if let note = shortcut.note {
                Text(note).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(shortcut.noteIsError ? Theme.red : Theme.secondary).padding(.top, 6)
            }
            Text("Opens Mi TV from anywhere.").font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(.top, 6)
            Spacer(minLength: 12)
            if shortcut.recording {
                Button { shortcut.end() } label: { Text("Done").font(.system(size: 13, weight: .semibold, design: .rounded)).frame(width: 112, height: 28) }
                .buttonStyle(KeyStyle(shape: Capsule(), fill: Theme.accent, foreground: .white, hover: Theme.accent.opacity(0.9)))
                .accessibilityLabel("Done")
            } else {
                Button { shortcut.begin() } label: { Text("Change").font(.system(size: 13, weight: .semibold, design: .rounded)).frame(width: 112, height: 28) }
                .buttonStyle(KeyStyle(shape: Capsule(), fill: Theme.keyFill, hover: Theme.strong))
                .accessibilityLabel("Change shortcut")
            }
            // "Quit Mi TV" is a quiet text link: 13 regular, secondary, primary on hover (DESIGN_SPEC 3.5).
            Button { NSApp.terminate(nil) } label: {
                Text("Quit Mi TV").font(.system(size: 13)).foregroundStyle(quitHover ? Color.primary : Theme.secondary)
            }
            .buttonStyle(.plain)
            .onHover { quitHover = $0 }
            .accessibilityLabel("Quit Mi TV")
            .padding(.top, 12)
        }
        .padding(16)
        .frame(width: 340, height: 232)
        .background(Button("Quit") { quitCommandQ() }.keyboardShortcut("q", modifiers: .command).opacity(0).frame(width: 0, height: 0))
    }
}

// MARK: - Surface

let lostMessage = "Lost connection to Mi TV. The run may still be going."

enum StripSource {
    case notice(Notice), lost, answer(String), failure(String), idle(String)
    var text: String {
        switch self {
        case .notice(let notice): return notice.text
        case .lost: return lostMessage
        case .answer(let answer): return answer
        case .failure(let error): return "Couldn't finish. \(error)"
        case .idle(let line): return line
        }
    }

    var color: Color {
        switch self {
        case .notice(let notice): return notice.isError ? Theme.red : Theme.secondary
        case .failure: return Theme.red
        case .answer: return .primary
        case .lost, .idle: return Theme.secondary
        }
    }

}

/// Row 2 of the header, first match wins (WORK_ORDER 3.1). A refusal, or a transient that repeats the visible
/// panel's title, gives way to the panel (3.2). Pure: the self-test drives it.
func headerSource(notice: Notice?, panel: PanelState?, lost: Bool, answer: String?, failure: String?,
                  isOn: Bool, app: String?) -> StripSource {
    let clash = panel.map { notice?.refusal == true || notice?.text == $0.title } ?? false
    if let notice, !clash { return .notice(notice) }
    if lost && panel == nil { return .lost }
    if let answer { return .answer(answer) }
    if let failure { return .failure(failure) }
    // The default line: the app while the TV is on and no panel shows; blank otherwise.
    guard panel == nil, isOn else { return .idle("") }
    return .idle(friendlyAppName(app ?? "") ?? "On")
}

/// The one surface, 340 x 480: header strip (16 to 72), body region (84 to 412), field (424 to 464).
// MARK: - Plugs (local Tuya control through room/room.py)

enum RoomTab: String, CaseIterable, Identifiable {
    case tv = "TV", plugs = "Plugs"
    var id: String { rawValue }
}

/// A Tuya plug from room/devices.json: `id` is its key there. An optional "title" and "symbol" (an SF Symbol name) in its entry
/// set how it is shown.
struct PlugDevice: Hashable, Identifiable {
    let id: String
    let title: String
    let symbol: String

    /// What a timed hold does: a fridge or freezer pauses then restarts; anything else runs for a while then stops.
    var holdOn: Bool { !["fridge", "freezer"].contains { id.lowercased().contains($0) } }

    init(id: String, entry: [String: Any]) {
        self.id = id
        let lower = id.lowercased()
        title = entry["title"] as? String ?? (id.count <= 3 ? id.uppercased() : id.replacingOccurrences(of: "_", with: " ").capitalized)
        symbol = entry["symbol"] as? String
            ?? (lower.contains("fridge") || lower.contains("freezer") ? "snowflake" : lower.contains("light") || lower.contains("lamp") ? "lightbulb"
                : lower.contains("fan") ? "fan" : lower.contains("ro") || lower.contains("water") ? "drop.fill" : "powerplug")
    }

    /// The plugs listed in room/devices.json, by name.
    static func load() -> [PlugDevice] {
        let url = Config.supportRoot.appendingPathComponent("room/devices.json")
        guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return object.keys.sorted().compactMap { name in (object[name] as? [String: Any]).map { PlugDevice(id: name, entry: $0) } }
    }
}

/// One PlugModel per plug, made when first shown.
@MainActor
final class PlugStore: ObservableObject {
    @Published private(set) var devices = PlugDevice.load()
    private var models: [String: PlugModel] = [:]

    func reload() { devices = PlugDevice.load() }
    func device(_ id: String) -> PlugDevice { devices.first { $0.id == id } ?? devices[0] }
    func model(_ id: String) -> PlugModel {
        if let model = models[id] { return model }
        let model = PlugModel(plug: id)
        models[id] = model
        return model
    }
}

enum RoomScript {
    static let directory = Config.supportRoot.appendingPathComponent("room", isDirectory: true)

    /// Runs `room.py <args>` off the main thread and returns the JSON it prints. The child is killed after `timeout` seconds.
    static func call(_ args: [String], timeout: Double = 15) async -> [String: Any]? {
        await Task.detached(priority: .userInitiated) { () -> [String: Any]? in
            let child = Process()
            child.executableURL = directory.appendingPathComponent(".venv/bin/python")
            child.arguments = ["room.py"] + args
            child.currentDirectoryURL = directory
            let pipe = Pipe()
            child.standardOutput = pipe
            child.standardError = FileHandle.nullDevice
            do { try child.run() } catch { return nil }
            let timer = DispatchWorkItem { if child.isRunning { child.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            timer.cancel()
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }.value
    }

    /// `room.py <command> <plug> --json`: the plug's switch state.
    static func run(_ command: String, _ plug: String) async -> Bool? {
        let object = await call([command, plug, "--json"])
        return object?["on"] as? Bool
    }
}

/// One switch change from the plug's history.
struct PlugLogEntry: Identifiable {
    let id: Int
    let date: Date
    let on: Bool
}

/// One schedule row, as the Smart Life app shows it. `loops` has one digit per day, Sunday first.
struct PlugTimer: Identifiable, Equatable {
    let group: String, category: String
    var time: String, loops: String, on: Bool, enabled: Bool
    var id: String { group }

    init?(json: [String: Any]) {
        guard let group = json["group"] as? String, let category = json["category"] as? String,
              let time = json["time"] as? String, let loops = json["loops"] as? String else { return nil }
        self.group = group; self.category = category; self.time = time; self.loops = loops
        on = json["on"] as? Bool ?? false
        enabled = json["enabled"] as? Bool ?? true
    }

    static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    var repeatText: String {
        switch loops {
        case "1111111": return "Every day"
        case "0111110": return "Weekdays"
        case "1000001": return "Weekends"
        case "0000000": return "Once"
        default: return zip(Self.dayNames, loops).filter { $0.1 == "1" }.map(\.0).joined(separator: " ")
        }
    }
}

@MainActor
final class PlugModel: ObservableObject {
    let plug: String
    @Published var on: Bool?
    @Published var busy = false
    @Published var failed = false
    /// Seconds left on the plug's own countdown when last read, and when that was.
    @Published var countdown = 0
    @Published var countdownRead = Date()
    /// What the plug does when power returns: memory, on or off.
    @Published var relay: String?
    /// Seconds the plug stays on after each switch-on before turning itself off (its "inching" setting); 0 if unset.
    @Published var inching = 0
    /// False when no Tuya developer keys are set up: schedules and history are then unavailable (switching still works).
    @Published var cloud = true
    @Published var timers: [PlugTimer] = []
    @Published var timersLoaded = false
    @Published var timerBusy = false
    @Published var timerError: String?
    @Published var log: [PlugLogEntry] = []
    @Published var logLoaded = false
    @Published var logBusy = false
    init(plug: String) { self.plug = plug }

    /// The last 24 hours of switch changes from Tuya's cloud log, newest first.
    func loadLog() async {
        guard !logBusy else { return }
        logBusy = true
        let object = await RoomScript.call(["log", plug, "24", "--json"], timeout: 40)
        logBusy = false
        guard let events = object?["events"] as? [[String: Any]] else { return }
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        format.locale = Locale(identifier: "en_US_POSIX")
        log = events.enumerated().compactMap { index, event in
            guard let text = event["time"] as? String, let date = format.date(from: text), let value = event["value"] as? String else { return nil }
            return PlugLogEntry(id: index, date: date, on: value == "ON")
        }.reversed()
        logLoaded = true
    }

    private func apply(_ object: [String: Any]?) {
        guard let state = object?["on"] as? Bool else { failed = true; return }
        failed = false
        on = state
        countdown = object?["countdown"] as? Int ?? 0
        countdownRead = Date()
        relay = object?["relay"] as? String
        inching = object?["inching"] as? Int ?? 0
        cloud = object?["cloud"] as? Bool ?? true
    }

    private func run(_ args: [String]) async {
        guard !busy else { return }
        busy = true
        apply(await RoomScript.call(args + ["--json"]))
        busy = false
    }

    func refresh() async { await run(["status", plug]) }
    func set(_ turnOn: Bool) async { await run([turnOn ? "on" : "off", plug]) }
    /// Switches now and lets the plug flip back by itself after `seconds`.
    func hold(_ turnOn: Bool, seconds: Int) async { await run(["for", plug, turnOn ? "on" : "off", String(seconds)]) }
    func cancelCountdown() async { await run(["cancel", plug]) }
    func setRelay(_ value: String) async { await run(["relay", plug, value]) }

    /// Reads the schedule from Tuya's cloud, the same list the Smart Life app shows.
    func loadTimers() async {
        guard !timerBusy else { return }
        timerBusy = true
        let object = await RoomScript.call(["timers", plug], timeout: 25)
        timerBusy = false
        guard let list = object?["timers"] as? [[String: Any]] else { timerError = "Can't load the schedule"; return }
        timers = list.compactMap(PlugTimer.init(json:))
        timersLoaded = true
        timerError = nil
    }

    /// Runs a timer-add / timer-set / timer-enable / timer-del command, then re-reads the schedule.
    func changeTimer(_ args: [String]) async {
        guard !timerBusy else { return }
        timerBusy = true
        let object = await RoomScript.call(args, timeout: 25)
        timerBusy = false
        timerError = object?["ok"] as? Bool == true ? nil : "Couldn't save the change"
        await loadTimers()
    }
}

/// A stretch of the dial between two neighbouring schedules, as fractions of the day.
struct PlugSection {
    let start: PlugTimer, end: PlugTimer
    let from: Double, to: Double
    var arcs: [(Double, Double)] { to > from ? [(from, to)] : to == from ? [(0, 1)] : [(from, 1), (0, to)] }
}

/// Pure schedule maths for the Plugs tab: the next event, and the on/off picture of today.
enum PlugSchedule {
    struct Segment { let from: Double, to: Double, on: Bool }

    private static func minutes(_ timer: PlugTimer) -> Int? {
        let parts = timer.time.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
    }

    private static func runs(_ timer: PlugTimer, weekday: Int) -> Bool {
        let digits = Array(timer.loops)
        return timer.enabled && digits.count == 7 && digits[weekday] == "1"
    }

    static func next(_ timers: [PlugTimer], after now: Date) -> (timer: PlugTimer, at: Date)? {
        let calendar = Calendar.current
        var best: (timer: PlugTimer, at: Date)?
        for timer in timers {
            guard let total = minutes(timer) else { continue }
            for offset in 0...7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                      let at = calendar.date(bySettingHour: total / 60, minute: total % 60, second: 0, of: day), at > now else { continue }
                guard runs(timer, weekday: calendar.component(.weekday, from: at) - 1) else { continue }
                if best == nil || at < best!.at { best = (timer, at) }
                break
            }
        }
        return best
    }

    /// Today's events in time order; the strip shades off periods only when the day has both an on and an off event.
    static func today(_ timers: [PlugTimer], now: Date, inching: Int = 0) -> (segments: [Segment], ticks: [Double], longestOff: (hours: Double, from: String, to: String)?) {
        let weekday = Calendar.current.component(.weekday, from: now) - 1
        let events = timers.filter { runs($0, weekday: weekday) && minutes($0) != nil }.sorted { minutes($0)! < minutes($1)! }
        guard !events.isEmpty else { return ([], [], nil) }
        if inching > 0 {  // every switch-on is followed by the plug's own auto-off
            var lit: [Segment] = []
            for event in events where event.on {
                let from = Double(minutes(event)!) / 1440, to = from + Double(inching) / 86400
                if to <= 1 { lit.append(Segment(from: from, to: to, on: true)) }
                else { lit.append(Segment(from: from, to: 1, on: true)); lit.append(Segment(from: 0, to: to - 1, on: true)) }
            }
            return (lit, [], nil)
        }
        guard events.contains(where: { $0.on }) && events.contains(where: { !$0.on }) else {
            return ([], events.map { Double(minutes($0)!) / 1440 }, nil)
        }
        var segments: [Segment] = []
        var longest: (hours: Double, from: String, to: String)?
        for (index, event) in events.enumerated() {
            let start = minutes(event)!, following = events[(index + 1) % events.count]
            let end = minutes(following)!
            if end > start { segments.append(Segment(from: Double(start) / 1440, to: Double(end) / 1440, on: event.on)) }
            else {
                segments.append(Segment(from: Double(start) / 1440, to: 1, on: event.on))
                segments.append(Segment(from: 0, to: Double(end) / 1440, on: event.on))
            }
            if !event.on {
                let length = Double((end - start + 1440) % 1440) / 60
                if longest == nil || length > longest!.hours { longest = (length, event.time, following.time) }
            }
        }
        return (segments, [], longest)
    }

    /// The stretch of today that `fraction` falls in: from the schedule before it to the one after it.
    static func section(at fraction: Double, timers: [PlugTimer], now: Date, inching: Int = 0, litOnly: Bool = false) -> PlugSection? {
        let weekday = Calendar.current.component(.weekday, from: now) - 1
        let events = timers.filter { runs($0, weekday: weekday) && minutes($0) != nil }.sorted { minutes($0)! < minutes($1)! }
        guard !events.isEmpty else { return nil }
        if inching > 0 {  // a lit stretch belongs to the one schedule that starts it
            let length = Double(inching) / 86400
            for event in events where event.on {
                let from = Double(minutes(event)!) / 1440
                let margin = 0.008  // a little slack either side (about 12 minutes), since a 30-minute stretch is a small target
                if (fraction - from + 1 + margin).truncatingRemainder(dividingBy: 1) < length + 2 * margin {
                    return PlugSection(start: event, end: event, from: from, to: (from + length).truncatingRemainder(dividingBy: 1))
                }
            }
            return nil
        }
        let point = fraction * 1440
        let index = events.lastIndex { Double(minutes($0)!) <= point } ?? events.count - 1
        let start = events[index], end = events[(index + 1) % events.count]
        if litOnly && (!start.on || !events.contains(where: { !$0.on })) { return nil }  // dim stretches are for adding, not deleting
        return PlugSection(start: start, end: end, from: Double(minutes(start)!) / 1440, to: Double(minutes(end)!) / 1440)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}

/// The add / edit form's working copy. `group` is nil for a new timer.
struct TimerDraft {
    var group: String?
    var time: Date
    var on: Bool
    var days: [Bool]
    var enabled = true
    var wasEnabled = true

    init() { group = nil; time = TimerDraft.date("08:00"); on = true; days = Array(repeating: true, count: 7) }
    init(_ timer: PlugTimer) {
        group = timer.group; time = TimerDraft.date(timer.time); on = timer.on
        days = timer.loops.map { $0 == "1" }
        enabled = timer.enabled; wasEnabled = timer.enabled
    }

    /// A new schedule at the tapped point of the dial, rounded to the nearest quarter hour.
    init(roundedTo fraction: Double) {
        self.init()
        let quarter = Int((fraction * 96).rounded()) % 96
        time = TimerDraft.date(String(format: "%02d:%02d", quarter / 4, quarter % 4 * 15))
    }

    static let format: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
    static func date(_ text: String) -> Date { format.date(from: text) ?? Date() }
    /// "18:30" as "6:30 PM", to match the 12 h dial.
    static func twelve(_ text: String) -> String {
        guard let date = format.date(from: text) else { return text }
        let display = DateFormatter()
        display.dateFormat = "h:mm a"
        return display.string(from: date)
    }
    var timeText: String { Self.format.string(from: time) }
    var loops: String { days.map { $0 ? "1" : "0" }.joined() }
}

/// Adds plugs from the user's Smart Life account: sign in by scanning a QR code, then pick the plugs to add.
@MainActor
final class PlugSetupModel: ObservableObject {
    enum Step { case checking, code, waiting(String), devices }
    struct Found: Identifiable {
        let id: String, name: String, product: String
        var online: Bool, added: Bool
    }

    @Published var step: Step = .checking
    @Published var devices: [Found] = []
    @Published var error: String?
    @Published var busy = false
    @Published var adding: String?
    private var pollTask: Task<Void, Never>?

    /// Already signed in? Go straight to the device list.
    func begin() async {
        if await loadDevices() { return }
        step = .code
    }

    func start(code: String) async {
        error = nil
        busy = true
        let object = await RoomScript.call(["login-start", code.trimmed], timeout: 30)
        busy = false
        guard let qr = object?["qr"] as? String else { error = "That didn't work. Check the user code and your internet connection."; return }
        step = .waiting(qr)
        pollTask?.cancel()
        pollTask = Task { await poll() }
    }

    private func poll() async {
        for _ in 0..<90 {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { return }
            let object = await RoomScript.call(["login-poll"], timeout: 20)
            if object?["status"] as? String == "ok" {
                if await !loadDevices() { error = "Signed in, but couldn't read your devices."; step = .code }
                return
            }
        }
        error = "Timed out waiting for the scan. Try again."
        step = .code
    }

    @discardableResult
    func loadDevices() async -> Bool {
        busy = true
        let object = await RoomScript.call(["discover"], timeout: 40)
        busy = false
        guard let list = object?["devices"] as? [[String: Any]] else { return false }
        devices = list.compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            return Found(id: id, name: name, product: item["product"] as? String ?? "", online: item["online"] as? Bool ?? false, added: item["added"] as? Bool ?? false)
        }
        step = .devices
        return true
    }

    func add(_ device: Found, store: PlugStore) async {
        error = nil
        adding = device.id
        let object = await RoomScript.call(["add-device", device.id], timeout: 90)
        adding = nil
        if object?["ok"] as? Bool == true {
            if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index].added = true }
            store.reload()
        } else {
            error = "Couldn't find \(device.name) on your network. Is it on, and is this Mac on the same Wi-Fi?"
        }
    }

    func stop() { pollTask?.cancel() }
}

struct PlugSetupView: View {
    @ObservedObject var store: PlugStore
    let close: () -> Void
    @StateObject private var model = PlugSetupModel()
    @State private var code = ""

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Add a plug").font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                RoundKey(symbol: "xmark", size: 26, glyph: 11, label: "Close") { model.stop(); close() }
            }
            .padding(.top, 12)
            switch model.step {
            case .checking:
                Spacer(); ProgressView(); Spacer()
            case .code:
                codeStep
            case .waiting(let qr):
                qrStep(qr)
            case .devices:
                deviceStep
            }
            if let error = model.error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.red).multilineTextAlignment(.center).frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await model.begin() }
        .onDisappear { model.stop() }
    }

    private var codeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add your plugs in the Smart Life app first. Then, in Smart Life, open Me, the settings gear, Account and Security, User Code, and type the code here.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("User code", text: $code)
                .textFieldStyle(.plain).font(.system(size: 15, design: .monospaced)).padding(.horizontal, 12).frame(height: 36)
                .background(Capsule().fill(Theme.key))
                .onSubmit { Task { await model.start(code: code) } }
            Button { Task { await model.start(code: code) } } label: {
                HStack { if model.busy { ProgressView().controlSize(.small) }; Text("Continue") }
                    .font(.system(size: 13, weight: .semibold, design: .rounded)).frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(KeyStyle(shape: Capsule(), fill: Theme.accent, foreground: .white, hover: Theme.accent.opacity(0.9)))
            .disabled(code.trimmed.isEmpty || model.busy)
            Spacer()
        }
    }

    private func qrStep(_ qr: String) -> some View {
        VStack(spacing: 12) {
            if let image = Self.qrImage(qr) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: 190, height: 190)
                    .padding(10).background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
            }
            Text("In Smart Life, tap the scan icon at the top right of Home and scan this code. Approve the sign-in on your phone.")
                .font(.system(size: 13)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Waiting for the scan").font(.system(size: 12)).foregroundStyle(Theme.secondary) }
            Spacer()
        }
    }

    private var deviceStep: some View {
        VStack(spacing: 8) {
            Text("Pick the plugs to add. They need to be on and on this Wi-Fi.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, alignment: .leading)
            if model.devices.isEmpty {
                Spacer(); Text("No devices on this account").font(.system(size: 13)).foregroundStyle(Theme.secondary); Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.devices) { device in
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name).font(.system(size: 14, weight: .medium))
                                    Text(device.product).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 6)
                                if model.adding == device.id {
                                    ProgressView().controlSize(.small)
                                } else if device.added {
                                    Label("Added", systemImage: "checkmark").font(.system(size: 12, weight: .medium)).foregroundStyle(Color(nsColor: .systemGreen))
                                } else {
                                    Button { Task { await model.add(device, store: store) } } label: {
                                        Text("Add").font(.system(size: 12, weight: .semibold, design: .rounded)).padding(.horizontal, 14).frame(height: 26)
                                    }
                                    .buttonStyle(KeyStyle(shape: Capsule(), fill: Theme.keyFill, hover: Theme.strong))
                                    .disabled(model.adding != nil)
                                }
                            }
                            .padding(.vertical, 8)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
            Button { close() } label: {
                Text("Done").font(.system(size: 13, weight: .semibold, design: .rounded)).frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(KeyStyle(shape: Capsule(), fill: Theme.keyFill, hover: Theme.strong))
        }
    }

    static func qrImage(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

struct PlugView: View {
    @Binding var device: PlugDevice
    let devices: [PlugDevice]
    let onAdd: () -> Void
    let onRemove: (PlugDevice) -> Void
    @ObservedObject var model: PlugModel
    @State private var armed = false
    @State private var armedHold: Int?
    @State private var editing: TimerDraft?
    @State private var deleteArmed: String?
    @State private var section: PlugSection?
    @State private var showLog = false
    @State private var confirmRemove = false
    @State private var half = Calendar.current.component(.hour, from: Date()) >= 12 ? 1 : 0
    @State private var sectionArmed = false

    private static let holds = [(label: "30 min", seconds: 1800), (label: "1 h", seconds: 3600), (label: "2 h", seconds: 7200), (label: "4 h", seconds: 14400)]

    private var word: String { model.failed ? "Can't reach" : model.on == nil ? "Checking" : model.on == true ? "On" : "Off" }
    private var dot: Color { model.failed || model.on == nil ? Theme.grey : model.on == true ? Color(nsColor: .systemGreen) : Theme.red }

    var body: some View {
        VStack(spacing: 12) {
            controlRow.padding(.top, 12)
            if confirmRemove {
                removeConfirm
            } else if editing != nil {
                editor
            } else if showLog {
                logView
            } else {
                if model.cloud {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        VStack(spacing: 6) {
                            clock(now: context.date)
                            DayBar(segments: PlugSchedule.today(model.timers, now: context.date, inching: model.inching).segments,
                                   selection: section, now: context.date) { handlePick($0, fromDot: false) }
                        }
                    }
                } else {
                    noCloud
                }
                holdRow
                Spacer(minLength: 0)
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await poll() }
    }

    // MARK: Header

    private var controlRow: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(devices) { item in Button(item.title) { device = item } }
                Divider()
                Button("Add a plug…") { onAdd() }
                Button("Remove \(device.title)…") { confirmRemove = true }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: device.symbol).font(.system(size: 13))
                    Text(device.title).font(.system(size: 14, weight: .semibold, design: .rounded))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.secondary)
                }
                .padding(.horizontal, 12).frame(height: 30)
                .background(Capsule().fill(Theme.key))
                .contentShape(Capsule())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("Plug, \(device.title)")
            HStack(spacing: 5) {
                if model.on != nil || model.failed {
                    Circle().fill(dot).frame(width: 7, height: 7)
                    Text(word).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1).fixedSize()
                }
                if model.busy || (model.on == nil && !model.failed) { ProgressView().controlSize(.small) }
            }
            Spacer(minLength: 4)
            if model.on != nil {
                Button { toggle() } label: {
                    Text(buttonTitle).font(.system(size: 13, weight: .semibold, design: .rounded)).padding(.horizontal, 14).frame(height: 30)
                }
                .buttonStyle(KeyStyle(shape: Capsule(), fill: armed ? Theme.red.opacity(0.25) : Theme.keyFill, hover: Theme.strong))
                .disabled(model.busy)
                .accessibilityLabel(buttonTitle)
            }
        }
    }

    private var noCloud: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "calendar.badge.clock").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.secondary)
            Text("Schedules need a Tuya developer key").font(.system(size: 14, weight: .semibold, design: .rounded))
            Text("Switching, timed holds and the power-cut setting work now. The README shows how to unlock schedules and history.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 244)
    }

    // MARK: The 24 h clock

    private var halfPicker: some View {
        HStack(spacing: 2) {
            ForEach(["AM", "PM"].indices, id: \.self) { index in
                Button { half = index } label: {
                    Text(index == 0 ? "AM" : "PM").font(.system(size: 11, weight: .semibold, design: .rounded))
                        .frame(width: 34, height: 22)
                        .background(Capsule().fill(half == index ? Theme.strong : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(index == 0 ? "Morning" : "Afternoon and evening")
            }
        }
        .padding(2).background(Capsule().fill(Theme.key))
    }

    /// A tap on the dial or the day bar: select the lit stretch under it, or start a new schedule on a dim spot.
    private func handlePick(_ fraction: Double, fromDot: Bool) {
        sectionArmed = false
        guard fraction >= 0 else { section = nil; return }
        section = PlugSchedule.section(at: fraction, timers: model.timers, now: Date(), inching: model.inching, litOnly: !fromDot)
        if section == nil { editing = TimerDraft(roundedTo: fraction) }
    }

    private func clock(now: Date) -> some View {
        let day = PlugSchedule.today(model.timers, now: now, inching: model.inching)
        let upcoming = PlugSchedule.next(model.timers, after: now)
        return ZStack {
            DayClock(timers: model.timers, segments: day.segments, now: now, inching: model.inching, half: half, selection: section,
                     pick: { fraction, fromDot in handlePick(fraction, fromDot: fromDot) })
            VStack(spacing: 10) {
            VStack(spacing: 3) {
                if model.countdown > 0 && model.on != nil {
                    let left = max(60, Double(model.countdown) - now.timeIntervalSince(model.countdownRead))
                    Text(model.on == true ? "Turns off" : "Back on").font(.system(size: 14, weight: .medium))
                    Text("in \(PlugSchedule.duration(left))").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                } else if let upcoming {
                    Text("\(upcoming.timer.on ? "On" : "Off") in \(PlugSchedule.duration(upcoming.at.timeIntervalSince(now)))").font(.system(size: 14, weight: .medium))
                    Text(upcoming.timer.on && model.inching > 0 ? "for \(PlugSchedule.duration(Double(model.inching)))" : "at \(TimerDraft.twelve(upcoming.timer.time))")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                } else {
                    Text(model.timersLoaded ? "No schedule" : "Loading").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                }
            }
            .allowsHitTesting(false)
                halfPicker
            }
        }
        .frame(height: 216)
    }

    // MARK: Hold for a while

    @ViewBuilder
    private var holdRow: some View {
        if let section {
            sectionRow(section)
        } else if model.countdown > 0 && model.on != nil {
            Button { Task { await model.cancelCountdown() } } label: {
                Text("Cancel countdown").font(.system(size: 13, weight: .semibold, design: .rounded)).frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(KeyStyle(shape: Capsule(), fill: Theme.keyFill, hover: Theme.strong))
            .disabled(model.busy)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(device.holdOn ? "Turn on for, then off" : "Turn off for, then back on")
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                HStack(spacing: 6) {
                    ForEach(Self.holds, id: \.seconds) { item in
                        Button { hold(item.seconds) } label: {
                            Text(armedHold == item.seconds ? "Tap again" : item.label).font(.system(size: 12, weight: .medium, design: .rounded))
                                .frame(maxWidth: .infinity, minHeight: 28)
                        }
                        .buttonStyle(KeyStyle(shape: Capsule(), fill: armedHold == item.seconds ? Theme.red.opacity(0.25) : Theme.key, hover: Theme.strong))
                        .disabled(model.busy || model.on == nil)
                        .accessibilityLabel("\(device.holdOn ? "Turn on" : "Turn off") for \(item.label)")
                    }
                }
            }
        }
    }

    private func sectionRow(_ section: PlugSection) -> some View {
        let both = section.start.group != section.end.group
        return VStack(spacing: 8) {
            Text(both ? "\(TimerDraft.twelve(section.start.time)) to \(TimerDraft.twelve(section.end.time))"
                      : "\(TimerDraft.twelve(section.start.time))\(model.inching > 0 ? " for \(PlugSchedule.duration(Double(model.inching)))" : "")")
                .font(.system(size: 14, weight: .medium))
            HStack(spacing: 8) {
                Button { self.section = nil; sectionArmed = false } label: {
                    Text("Cancel").font(.system(size: 13, weight: .semibold, design: .rounded)).frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(KeyStyle(shape: Capsule(), fill: Theme.keyFill, hover: Theme.strong))
                Button { editing = TimerDraft(section.start); self.section = nil; sectionArmed = false } label: {
                    Text("Edit").font(.system(size: 13, weight: .semibold, design: .rounded)).frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(KeyStyle(shape: Capsule(), fill: Theme.keyFill, hover: Theme.strong))
                Button { deleteSection(section) } label: {
                    Text(sectionArmed ? "Tap again" : (both ? "Delete both" : "Delete")).font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.red).frame(maxWidth: .infinity, minHeight: 30)
                }
                .buttonStyle(KeyStyle(shape: Capsule(), fill: sectionArmed ? Theme.red.opacity(0.25) : Theme.keyFill, hover: Theme.strong))
                .disabled(model.timerBusy)
            }
        }
    }

    private func deleteSection(_ section: PlugSection) {
        if !sectionArmed {
            sectionArmed = true
            Task { try? await Task.sleep(for: .seconds(4)); sectionArmed = false }
            return
        }
        sectionArmed = false
        self.section = nil
        Task {
            await model.changeTimer(["timer-del", model.plug, section.start.group])
            if section.end.group != section.start.group { await model.changeTimer(["timer-del", model.plug, section.end.group]) }
        }
    }

    private func hold(_ seconds: Int) {
        if !device.holdOn && armedHold != seconds {
            armedHold = seconds
            Task { try? await Task.sleep(for: .seconds(4)); if armedHold == seconds { armedHold = nil } }
            return
        }
        armedHold = nil
        Task { await model.hold(device.holdOn, seconds: seconds) }
    }

    // MARK: Remove

    private var removeConfirm: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "minus.circle").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.secondary)
            Text("Remove \(device.title)?").font(.system(size: 15, weight: .semibold, design: .rounded))
            Text("It disappears from this app only. It stays in Smart Life, and you can add it again any time.")
                .font(.system(size: 12)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center).padding(.horizontal, 12)
            HStack(spacing: 10) {
                Button { confirmRemove = false } label: {
                    Text("Cancel").font(.system(size: 13, weight: .semibold, design: .rounded)).frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(KeyStyle(shape: Capsule(), fill: Theme.keyFill, hover: Theme.strong))
                Button { confirmRemove = false; onRemove(device) } label: {
                    Text("Remove").font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Theme.red).frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(KeyStyle(shape: Capsule(), fill: Theme.keyFill, hover: Theme.strong))
            }
            .padding(.top, 6)
            Spacer()
        }
    }

    // MARK: History

    private var logView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("History, last 24 h").font(.system(size: 13, weight: .semibold, design: .rounded))
                if model.logBusy { ProgressView().controlSize(.small) }
                Spacer()
                RoundKey(symbol: "arrow.clockwise", size: 26, glyph: 11, label: "Reload history") { Task { await model.loadLog() } }
                RoundKey(symbol: "xmark", size: 26, glyph: 11, label: "Close history") { showLog = false }
            }
            if model.log.isEmpty {
                Spacer()
                Text(model.logLoaded ? "No switching in the last 24 hours" : "Loading").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.log) { entry in
                            HStack(spacing: 10) {
                                Circle().fill(entry.on ? Color(nsColor: .systemGreen) : Theme.red).frame(width: 8, height: 8)
                                Text(entry.on ? "Turned on" : "Turned off").font(.system(size: 14))
                                Spacer()
                                Text(Self.logTime(entry.date)).font(.system(size: 12)).foregroundStyle(Theme.secondary).monospacedDigit()
                            }
                            .padding(.vertical, 7)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 14)
    }

    private static func logTime(_ date: Date) -> String {
        let format = DateFormatter()
        format.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm:ss" : "EEE HH:mm:ss"
        return format.string(from: date)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 10) {
            if let error = model.timerError {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.red).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                if model.cloud {
                    Button { editing = TimerDraft() } label: {
                        Label("Add schedule", systemImage: "plus").font(.system(size: 13, weight: .semibold, design: .rounded))
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(KeyStyle(shape: Capsule(), fill: Theme.keyFill, hover: Theme.strong))
                    .accessibilityLabel("Add schedule")
                    RoundKey(symbol: "list.bullet", size: 30, glyph: 12, label: "History") {
                        showLog = true
                        Task { await model.loadLog() }
                    }
                } else {
                    Spacer()
                }
                RoundKey(symbol: "arrow.clockwise", size: 30, glyph: 12, label: "Refresh") {
                    Task { await model.refresh(); await model.loadTimers() }
                }
                if model.timerBusy { ProgressView().controlSize(.small) }
            }
            HStack {
                Text("After a power cut").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Spacer()
                Menu {
                    Button("Restore last state") { Task { await model.setRelay("memory") } }
                    Button("Turn on") { Task { await model.setRelay("on") } }
                    Button("Stay off") { Task { await model.setRelay("off") } }
                } label: {
                    HStack(spacing: 4) {
                        Text(relayText).font(.system(size: 12))
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.secondary)
                    }
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .disabled(model.relay == nil || model.busy)
            }
        }
        .padding(.bottom, 14)
    }

    private var relayText: String {
        switch model.relay {
        case "memory": return "Restore last state"
        case "on": return "Turn on"
        case "off": return "Stay off"
        default: return "—"
        }
    }

    // MARK: Editor

    private var editor: some View {
        let draft = Binding(get: { editing ?? TimerDraft() }, set: { editing = $0 })
        return VStack(spacing: 16) {
            Text(draft.wrappedValue.group == nil ? "New schedule" : "Edit schedule")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            DatePicker("", selection: draft.time, displayedComponents: .hourAndMinute)
                .labelsHidden().datePickerStyle(.stepperField).scaleEffect(1.25).padding(.vertical, 6)
            Picker("", selection: draft.on) {
                Text("Turn on").tag(true)
                Text("Turn off").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden()
            HStack(spacing: 6) {
                ForEach(0..<7, id: \.self) { index in
                    Button { var value = draft.wrappedValue; value.days[index].toggle(); draft.wrappedValue = value } label: {
                        Text(String(PlugTimer.dayNames[index].prefix(1))).font(.system(size: 13, weight: .semibold, design: .rounded))
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(draft.wrappedValue.days[index] ? Theme.accent : Theme.key))
                            .foregroundStyle(draft.wrappedValue.days[index] ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(PlugTimer.dayNames[index])
                }
            }
            Text(repeatSummary(draft.wrappedValue.loops)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            if let group = draft.wrappedValue.group {
                HStack {
                    Toggle("Enabled", isOn: draft.enabled).toggleStyle(.switch).controlSize(.small).font(.system(size: 13))
                    Spacer()
                    Button { askDelete(group) } label: {
                        Text(deleteArmed == group ? "Tap again to delete" : "Delete").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.red)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Button { editing = nil } label: { Text("Cancel").font(.system(size: 13, weight: .semibold, design: .rounded)).frame(maxWidth: .infinity, minHeight: 32) }
                    .buttonStyle(KeyStyle(shape: Capsule(), fill: Theme.keyFill, hover: Theme.strong))
                Button { save(draft.wrappedValue) } label: {
                    Text("Save").font(.system(size: 13, weight: .semibold, design: .rounded)).frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(KeyStyle(shape: Capsule(), fill: Theme.accent, foreground: .white, hover: Theme.accent.opacity(0.9)))
                .disabled(model.timerBusy)
            }
            .padding(.bottom, 16)
        }
    }

    private func repeatSummary(_ loops: String) -> String {
        PlugTimer(json: ["group": "", "category": "", "time": "", "loops": loops])?.repeatText ?? ""
    }

    private func save(_ draft: TimerDraft) {
        let action = draft.on ? "on" : "off"
        let args = draft.group.map { ["timer-set", model.plug, $0, draft.timeText, action, draft.loops] }
            ?? ["timer-add", model.plug, draft.timeText, action, draft.loops]
        editing = nil
        Task {
            await model.changeTimer(args)
            if let group = draft.group, draft.enabled != draft.wasEnabled {
                await model.changeTimer(["timer-enable", model.plug, group, draft.enabled ? "1" : "0"])
            }
        }
    }

    private func askDelete(_ group: String) {
        if deleteArmed == group {
            deleteArmed = nil
            editing = nil
            Task { await model.changeTimer(["timer-del", model.plug, group]) }
        } else {
            deleteArmed = group
            Task { try? await Task.sleep(for: .seconds(4)); if deleteArmed == group { deleteArmed = nil } }
        }
    }

    // MARK: Power key and polling

    private var buttonTitle: String {
        guard let on = model.on else { return "Checking" }
        if on { return armed ? "Tap again" : "Turn off" }
        return "Turn on"
    }

    private func toggle() {
        guard let on = model.on else { return }
        if on && !armed {
            armed = true
            Task { try? await Task.sleep(for: .seconds(4)); armed = false }
            return
        }
        armed = false
        Task { await model.set(!on) }
    }

    /// Reads the plug when the tab opens and every 20 s while it stays open; the cloud schedule every 60 s (not while editing).
    private func poll() async {
        var round = 0
        while !Task.isCancelled {
            await model.refresh()
            if round % 3 == 0 && editing == nil && model.cloud { await model.loadTimers() }
            round += 1
            try? await Task.sleep(for: .seconds(20))
        }
    }
}

/// Today as a 12 h dial (12 at the top): lit green while the plug is on, dim while off. `half` is 0 for AM, 1 for PM.
/// Each schedule of a plug that switches both ways is a dot to tap; stretches have rounded ends where they truly begin and end.
struct DayClock: View {
    let timers: [PlugTimer]
    let segments: [PlugSchedule.Segment]
    let now: Date
    let inching: Int
    let half: Int
    let selection: PlugSection?
    let pick: (Double, Bool) -> Void

    private var low: Double { Double(half) * 0.5 }

    private func fraction(_ time: String) -> Double {
        let parts = time.split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 ? (parts[0] * 60 + parts[1]) / 1440 : 0
    }

    /// A stretch of the day cut to this half and rescaled to 0...1 around the dial; the flags say whether its true start / end is in view.
    private func clip(_ from: Double, _ to: Double) -> (from: Double, to: Double, start: Bool, end: Bool)? {
        let a = max(from, low), b = min(to, low + 0.5)
        guard b > a else { return nil }
        return ((a - low) * 2, (b - low) * 2, true, true)  // every end is rounded, including where a stretch carries on into the other half
    }

    private func point(_ fraction: Double, radius: Double, center: CGPoint) -> CGPoint {
        let angle = fraction * 2 * .pi - .pi / 2
        return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    private func arc(_ part: (from: Double, to: Double, start: Bool, end: Bool), width: CGFloat, color: Color, radius: Double, center: CGPoint) -> some View {
        let cap = Double(width / 2) / (2 * .pi * radius)
        let a = part.start ? part.from + cap : part.from, b = part.end ? part.to - cap : part.to
        return ZStack {
            if b > a {
                Circle().trim(from: a, to: b).stroke(color, style: StrokeStyle(lineWidth: width, lineCap: .butt))
                    .rotationEffect(.degrees(-90)).frame(width: radius * 2, height: radius * 2).position(center)
            }
            if part.start { Circle().fill(color).frame(width: width, height: width).position(point(min(a, b), radius: radius, center: center)) }
            if part.end { Circle().fill(color).frame(width: width, height: width).position(point(max(a, b), radius: radius, center: center)) }
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let radius = min(proxy.size.width, proxy.size.height) / 2 - 20
            let nowDay = (Double(Calendar.current.component(.hour, from: now)) * 60 + Double(Calendar.current.component(.minute, from: now))) / 1440
            ZStack {
                Circle().stroke(Theme.key, lineWidth: 14).frame(width: radius * 2, height: radius * 2).position(center)
                ZStack {  // drawn solid, then softened as one group so overlapping caps don't show
                    ForEach(Array((selection?.arcs ?? []).compactMap { clip($0.0, $0.1) }.enumerated()), id: \.offset) { _, part in
                        arc(part, width: 22, color: Color.primary, radius: radius, center: center)
                    }
                }
                .compositingGroup().opacity(0.28)
                ZStack {
                    ForEach(Array(segments.filter(\.on).compactMap { clip($0.from, $0.to) }.enumerated()), id: \.offset) { _, part in
                        arc(part, width: 14, color: Color(nsColor: .systemGreen), radius: radius, center: center)
                    }
                }
                .compositingGroup().opacity(0.85)
                ForEach(0..<12, id: \.self) { index in
                    Text(index == 0 ? "12" : "\(index)").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                        .position(point(Double(index) / 12, radius: radius + 18, center: center))
                }
                if nowDay >= low && nowDay < low + 0.5 {
                    Path { path in
                        path.move(to: point((nowDay - low) * 2, radius: radius - 11, center: center))
                        path.addLine(to: point((nowDay - low) * 2, radius: radius + 11, center: center))
                    }
                    .stroke(Color.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                }
                // No dots: tap a lit stretch to edit or delete it, or a dim spot to add a schedule.
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                let dx = location.x - center.x, dy = location.y - center.y
                guard abs(hypot(dx, dy) - radius) < 24 else { pick(-1, false); return }
                var angle = Double(atan2(dy, dx)) + Double.pi / 2
                if angle < 0 { angle += 2 * Double.pi }
                let turn: Double = angle / (2 * Double.pi)
                pick(low + turn / 2, false)
            }
        }
    }
}

/// The whole day as one thin bar (midnight at the left): lit while the plug is on.
struct DayBar: View {
    let segments: [PlugSchedule.Segment]
    let selection: PlugSection?
    let now: Date
    let pick: (Double) -> Void

    var body: some View {
        let nowDay = (Double(Calendar.current.component(.hour, from: now)) * 60 + Double(Calendar.current.component(.minute, from: now))) / 1440
        VStack(spacing: 2) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.key).frame(height: 10)
                    ForEach(Array((selection?.arcs ?? []).enumerated()), id: \.offset) { _, arc in
                        RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.28))
                            .frame(width: max(6, (arc.1 - arc.0) * width + 4), height: 16).offset(x: arc.0 * width - 2)
                    }
                    ForEach(Array(segments.filter(\.on).enumerated()), id: \.offset) { _, segment in
                        RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .systemGreen).opacity(0.85))
                            .frame(width: max(4, (segment.to - segment.from) * width), height: 10).offset(x: segment.from * width)
                    }
                    Rectangle().fill(Color.primary).frame(width: 2, height: 16).offset(x: width * nowDay - 1)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { location in pick(min(max(location.x / width, 0), 0.9999)) }
            }
            .frame(height: 18)
            HStack {
                ForEach(Array(["0", "6", "12", "18", "24"].enumerated()), id: \.offset) { index, mark in
                    Text(mark).font(.system(size: 10)).foregroundStyle(Theme.secondary)
                    if index < 4 { Spacer() }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

struct TabBar: View {
    @Binding var tab: RoomTab
    var body: some View {
        HStack(spacing: 4) {
            ForEach(RoomTab.allCases) { item in
                Button { tab = item } label: {
                    Text(item.rawValue).font(.system(size: 13, weight: tab == item ? .semibold : .regular, design: .rounded))
                        .frame(maxWidth: .infinity).frame(height: 28)
                        .background(Capsule().fill(tab == item ? Theme.strong : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.key))
    }
}

struct RootView: View {
    @ObservedObject var model: RemoteModel
    @StateObject private var plugs = PlugStore()
    @State private var tab: RoomTab = .tv
    @State private var showSetup = false
    @State private var plugID = UserDefaults.standard.string(forKey: "plugDevice") ?? ""
    @ObservedObject var assistant: AssistantModel
    @ObservedObject var surface: SurfaceModel
    @FocusState private var fieldFocused: Bool
    @FocusState private var surfaceFocused: Bool
    /// Chips and rows follow the field's focus with a short grace delay: a click on one takes focus off the field first, and the click must still land.
    @State private var modesVisible = false
    private var rows: [SuggestionRow] { suggestionRows(for: surface.text, mode: surface.mode) }
    private var highlight: Int? { litRow(rows, text: surface.text, highlight: surface.highlight, mode: surface.mode) }
    /// An Ask in progress is a held run: no State panel shows (DESIGN_SPEC 2.1).
    private var held: Bool { assistant.busy }
    private var lost: Bool { runLost(held: held, up: model.health.up) }
    private var shownPanel: PanelState? { visiblePanel(model.panel, held: held) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TabBar(tab: $tab)
                RoundKey(symbol: "power", size: 32, glyph: 13, label: "Quit Mi TV") { NSApp.terminate(nil) }
            }
            .padding(.top, 10)
            switch tab {
            case .tv:
                header.padding(.top, 10).padding(.bottom, 12)
                bodyRegion.frame(height: 328).padding(.bottom, 12)
                field.frame(height: 40).padding(.bottom, 16)
            case .plugs:
                if showSetup {
                    PlugSetupView(store: plugs) { showSetup = false }
                } else if plugs.devices.isEmpty {
                    noPlugs
                } else {
                    let device = plugs.device(plugID)
                    PlugView(device: Binding(get: { device }, set: { plugID = $0.id }), devices: plugs.devices, onAdd: { showSetup = true },
                             onRemove: { removed in
                                 Task {
                                     _ = await RoomScript.call(["remove-device", removed.id])
                                     plugID = ""
                                     plugs.reload()
                                 }
                             },
                             model: plugs.model(device.id)).id(device.id)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(width: Config.width, height: Config.height, alignment: .top)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(shortcuts)
        .focusable()
        .focused($surfaceFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat], action: handleKey)
        .onAppear {
            surfaceFocused = true
            if surface.focusToken > 0 { focusSoon() }
        }
        .onChange(of: surface.focusToken) { _, _ in focusSoon() }
        .onChange(of: surface.unfocusToken) { _, _ in fieldFocused = false; modesVisible = false; surfaceFocused = true }
        .onChange(of: fieldFocused) { _, focused in
            if focused { modesVisible = true; return }
            surfaceFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if !fieldFocused { modesVisible = false } }
        }
        .onChange(of: surface.text) { _, _ in surface.highlight = nil }
        .onChange(of: plugID) { _, id in UserDefaults.standard.set(id, forKey: "plugDevice") }
        .animation(.easeInOut(duration: 0.2), value: shownPanel)
        .animation(.easeInOut(duration: 0.2), value: surface.transcript)
    }

    private var noPlugs: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "powerplug").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.secondary)
            Text("No plugs set up").font(.system(size: 15, weight: .semibold, design: .rounded))
            Text("Add the plugs from your Smart Life account.").font(.system(size: 12)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            Button { showSetup = true } label: {
                Text("Add a plug").font(.system(size: 13, weight: .semibold, design: .rounded)).padding(.horizontal, 18).frame(height: 32)
            }
            .buttonStyle(KeyStyle(shape: Capsule(), fill: Theme.accent, foreground: .white, hover: Theme.accent.opacity(0.9)))
            .padding(.top, 6)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Hidden buttons: Command+W closes, Command+, opens Settings, Command+Q quits. All work while the surface is key.
    private var shortcuts: some View {
        Group {
            Button("Close") { AppDelegate.shared?.closeSurface() }.keyboardShortcut("w", modifiers: .command)
            Button("Settings") { AppDelegate.shared?.openSettings() }.keyboardShortcut(",", modifiers: .command)
            Button("Quit") { quitCommandQ() }.keyboardShortcut("q", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
    }

    private var dotColor: Color {
        if !model.health.up { return Theme.grey }
        if model.isWaking || model.status?.state == "standby" { return Color(nsColor: .systemOrange) }
        return model.isOn ? Color(nsColor: .systemGreen) : Theme.grey
    }

    /// The header: a fixed 56 pt block with no card. Row 1 is the status and the power key; row 2 is one line.
    private var header: some View {
        let source = headerSource(notice: model.notice, panel: shownPanel, lost: lost, answer: assistant.answer,
                                  failure: assistant.askError, isOn: model.isOn, app: model.status?.app)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text("Mi TV").font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer(minLength: 8)
                powerKey
            }
            .frame(height: 20)
            Text(source.text)
                .font(.system(size: 13)).foregroundStyle(source.color).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32, alignment: .topLeading)
                .padding(.leading, 16)
                .help(source.text)
        }
        .frame(width: 308, height: 56, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { switch source { case .answer, .failure: surface.transcript = true; default: break } }
        .onChange(of: source.text) { _, text in
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    @ViewBuilder
    private var powerKey: some View {
        if model.sleepArm.isArmed {
            Button { model.sleepTap() } label: {
                Text("Tap again to sleep").font(.system(size: 13, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 12).frame(height: 28)
            }
            .buttonStyle(KeyStyle(shape: Capsule(), fill: Theme.strong))
            .accessibilityLabel("Tap again to sleep")
        } else if model.health.up && model.isOn {
            RoundKey(symbol: "power", size: 28, glyph: 13, label: "Sleep Mi TV", weight: .semibold) { model.sleepTap() }
        }
    }

    @ViewBuilder
    private var bodyRegion: some View {
        if let panel = shownPanel {
            PanelView(panel: panel, model: model)
        } else if surface.transcript {
            TranscriptView(assistant: assistant, surface: surface, model: model)
        } else {
            VStack(spacing: 12) {
                VolumeRow(model: model)
                TransportRow(model: model)
                navigate.frame(height: 208)
            }
            .opacity(model.health.dimmed || model.checking || lost ? 0.5 : 1)
        }
    }

    @ViewBuilder
    private var navigate: some View {
        if modesVisible && surface.text.trimmed.isEmpty && surface.mode == .ask {
            AppChips(model: model) { run(.open($0)) }
        } else if modesVisible {
            SuggestionList(rows: rows, highlight: highlight, hover: { surface.highlight = $0 }, run: run)
        } else {
            VStack(spacing: 12) {
                DPad { model.press($0) }
                HStack(spacing: 12) {
                    RoundKey(symbol: "arrow.uturn.backward", size: 36, glyph: 13, label: "Back") { model.press("BACK") }
                    RoundKey(symbol: "house.fill", size: 36, glyph: 13, label: "Home") { model.press("HOME") }
                    RoundKey(symbol: "line.3.horizontal", size: 36, glyph: 13, label: "Menu") { model.press("MENU") }
                }
            }
            .frame(height: 208)
        }
    }

    private var field: some View {
        Group {
            if assistant.busy { workingStrip } else { textField }
        }
        .frame(height: 40)
        .background(Capsule().fill(Theme.key))
        .overlay(Capsule().strokeBorder(Theme.accent, lineWidth: fieldFocused ? 1 : 0))
    }

    private var textField: some View {
        let speech = returnSpeech(text: surface.text, focused: fieldFocused, highlight: surface.highlight, on: model.isOn,
                                  standby: model.status?.state == "standby", armed: model.sleepArm.isArmed, mode: surface.mode)
        return HStack(spacing: 8) {
            Button { surface.toggleMode() } label: {
                Image(systemName: surface.mode.symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                    .frame(width: 20, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(surface.mode == .ask ? "Mode: Ask Mi TV. Switch to typing on the TV" : "Mode: Type on TV. Switch to Ask Mi TV")
            .help("Tab switches between Ask Mi TV and typing on the TV")
            ZStack(alignment: .leading) {
                if surface.text.isEmpty {
                    Text(surface.mode.placeholder).font(.system(size: 13)).foregroundStyle(Color.primary.opacity(0.5))
                        .allowsHitTesting(false)
                }
                TextField("", text: $surface.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($fieldFocused)
                    .onSubmit(runReturn)
                    .onKeyPress(keys: [.tab], phases: .down) { press in
                        if press.modifiers.contains(.shift) { fieldFocused = false; modesVisible = false } else { surface.toggleMode() }
                        return .handled
                    }
                    .onKeyPress(.escape) { escape(); return .handled }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.downArrow) { move(1) }
                    .accessibilityLabel(speech.map { "\(surface.mode.placeholder). \($0)" } ?? surface.mode.placeholder)
            }
            .opacity(model.pending == nil ? 1 : 0.5)

            if let pending = model.pending {
                ProgressView().controlSize(.small)
                Text(pending).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.secondary).lineLimit(1).fixedSize()
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
    }

    /// Replaces the field while an Ask runs. The step opens the transcript; Stop is neutral and off while lost.
    /// While a State panel shows, the strip reads "Waiting" with no step or count (WORK_ORDER 1.1).
    private var workingStrip: some View {
        let step = assistant.events.last { $0.kind == "tool" }.map { assistantStep(for: $0.text) } ?? "Starting"
        let panel = shownPanel != nil, elapsed = Int(assistant.elapsed)
        let detail = workingDetail(panel: panel, lost: lost, step: step, elapsed: elapsed)
        return HStack(spacing: 8) {
            Button { surface.transcript = true } label: {
                HStack(spacing: 4) {
                    Text(workingWord(panel: panel)).font(.system(size: 13, weight: .semibold))
                    if let detail {
                        Text(detail).font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(workingLabel(panel: panel, lost: lost, step: step, elapsed: elapsed))

            Button { Task { await assistant.stop() } } label: {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill").font(.system(size: 11, weight: .bold))
                    Text(assistant.stopping ? "Stopping" : "Stop").font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .padding(.horizontal, 12).frame(height: 28)
            }
            .buttonStyle(KeyStyle(shape: Capsule(), fill: Theme.keyFill, hover: Theme.strong))
            .disabled(assistant.stopping || lost)
            .accessibilityLabel("Stop")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The window may not be key yet when focus is requested, so the request waits a moment.
    private func focusSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            fieldFocused = true
            // AppKit selects all on focus; the caret goes to the end on the following turns.
            for delay in [0.0, 0.1] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { placeCaretAtEnd() } }
        }
    }

    /// Caret at the end with no selection (DESIGN_SPEC 2.6). The editor is the key window's, or the window holding it.
    private func placeCaretAtEnd() {
        guard let editor = (NSApp.keyWindow ?? NSApp.windows.first { $0.firstResponder is NSTextView })?.firstResponder as? NSTextView
        else { return }
        #if DEBUG_TOOLS
        let before = editor.selectedRange()
        #endif
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        #if DEBUG_TOOLS
        let range = editor.selectedRange()
        trace("CARET at \(range.location) len \(range.length) (was \(before.location) len \(before.length))")
        #endif
    }

    private func escape() {
        if surface.text.isEmpty { AppDelegate.shared?.closeSurface() } else { surface.clearField() }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let base = highlight ?? (step > 0 ? -1 : rows.count)
        surface.highlight = min(max(base + step, 0), rows.count - 1)
        return .handled
    }

    private func runReturn() { run(returnAction(text: surface.text, highlight: surface.highlight, mode: surface.mode)) }

    private func run(_ action: FieldAction) {
        guard model.pending == nil else { return }
        if case .ask(let prompt) = action {
            ask(prompt)
            return
        }
        Task { if await model.perform(action) { surface.clearField() } }
    }

    private func ask(_ prompt: String) {
        guard model.health.up else {
            model.refuse("ask", "Can't reach Mi TV")
            return
        }
        Task {
            switch await assistant.send(prompt) {
            case .started: surface.clearField()
            case .notice(let notice): model.flash(notice.text, error: notice.isError)
            case .failed: break           // the strip says "Couldn't finish."; the text stays for Return
            }
        }
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard tab == .tv else { return press.key == .escape ? { AppDelegate.shared?.closeSurface(); return .handled }() : .ignored }
        if NSApp.keyWindow?.firstResponder is NSTextView { return .ignored }
        if !press.modifiers.isDisjoint(with: [.command, .control, .option]) { return .ignored }
        switch press.key {
        case .upArrow: model.press("DPAD_UP")
        case .downArrow: model.press("DPAD_DOWN")
        case .leftArrow: model.press("DPAD_LEFT")
        case .rightArrow: model.press("DPAD_RIGHT")
        case .return: model.press("DPAD_CENTER")
        case .delete: model.press("BACK")
        case .escape: AppDelegate.shared?.closeSurface()
        case .space: model.press("MEDIA_PLAY_PAUSE")
        case .tab: surface.focusField()
        default:
            switch press.characters {
            case "[": model.nudge(-1)
            case "]": model.nudge(1)
            case ",": model.press("MEDIA_REWIND")
            case ".": model.press("MEDIA_FAST_FORWARD")
            case "/": surface.focusField()
            case let typed:
                guard typed.count == 1, let scalar = typed.unicodeScalars.first, scalar.value >= 32, scalar.value != 127
                else { return .ignored }
                surface.typeFromRemote(typed)
            }
        }
        return .handled
    }
}

// MARK: - App

/// Command+Q from a surface: logged, then the app quits. applicationWillTerminate stops the helper it started.
func quitCommandQ() {
    #if DEBUG_TOOLS
    trace("QUIT command-q")
    #endif
    NSApp.terminate(nil)
}

/// A borderless floating panel: the fallback when the status item is hidden (the notch, a crowded bar).
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Config.width, height: Config.height),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = content
    }
}

/// Menu bar glyph: a house holding a toggle switch. One static template image (macOS tints it), the same for every device.
enum RoomIcon {
    static func image(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let k = rect.width / 18
            let house = CGMutablePath()
            house.move(to: CGPoint(x: 9 * k, y: 16.2 * k))
            house.addLine(to: CGPoint(x: 16.3 * k, y: 9.8 * k))
            house.addLine(to: CGPoint(x: 16.3 * k, y: 3.2 * k))
            house.addLine(to: CGPoint(x: 1.7 * k, y: 3.2 * k))
            house.addLine(to: CGPoint(x: 1.7 * k, y: 9.8 * k))
            house.closeSubpath()
            ctx.setLineJoin(.round); ctx.setLineCap(.round)
            ctx.setStrokeColor(NSColor.black.cgColor); ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineWidth(1.4 * k)
            ctx.addPath(house)
            ctx.strokePath()
            ctx.setLineWidth(1.2 * k)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 5.2 * k, y: 5.4 * k, width: 7.6 * k, height: 4.2 * k),
                               cornerWidth: 2.1 * k, cornerHeight: 2.1 * k, transform: nil))
            ctx.strokePath()
            ctx.fillEllipse(in: CGRect(x: 9.3 * k, y: 5.9 * k, width: 3.2 * k, height: 3.2 * k))
            return true
        }
        image.isTemplate = true
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    static weak var shared: AppDelegate?
    let model = RemoteModel()
    let assistant = AssistantModel()
    let surface = SurfaceModel()
    let shortcut = ShortcutModel()
    var panel: FloatingPanel?
    var settingsWindow: NSWindow?
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var iconWatch: AnyCancellable?
    private var surfaceOpen = false
    private var clickMonitor: Any?
    /// "Keep Open" in the icon's right-click menu: the panel then stays until the icon or Command+W closes it.
    private var sticky: Bool { UserDefaults.standard.bool(forKey: "stickyPanel") }
    private var iconVisible = false
    private var lastPopoverClose = Date.distantPast

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        #if DEBUG_TOOLS
        applyPreviewAppearance()
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG_TOOLS
        if Launch.preview {
            startPreview()
            return
        }
        #endif
        HotKey.migrate()

        let controller = NSHostingController(rootView: root())
        controller.sizingOptions = []
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: Config.width, height: Config.height)
        popover.behavior = .transient
        popover.delegate = self

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(statusClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        iconWatch = model.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.updateIcon() }
        updateIcon()

        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, !self.sticky { self.closeSurface() } }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        HotKey.onPress = { [weak self] in self?.hotkeyPressed() }
        HotKey.registerSaved()
        updateIconVisibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.updateIconVisibility() }
        Task { await HelperProcess.shared.ensureRunning() }
    }

    func applicationWillTerminate(_ notification: Notification) { HelperProcess.shared.stop() }

    func root() -> RootView {
        RootView(model: model, assistant: assistant, surface: surface)
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let image = RoomIcon.image()
        image.accessibilityDescription = "Room remote"
        button.image = image
    }

    private func statusItemVisible() -> Bool {
        guard let button = statusItem?.button, let window = button.window else { return false }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        guard frame.width > 0, frame.height > 0 else { return false }
        if let screen = window.screen ?? NSScreen.main,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           frame.midX > left.maxX, frame.midX < right.minX {
            return false
        }
        return true
    }

    private func updateIconVisibility() { iconVisible = statusItemVisible() }

    @objc private func screensChanged() { updateIconVisibility() }

    func hotkeyPressed() {
        #if DEBUG_TOOLS
        trace("HOTKEY fired")
        #endif
        updateIconVisibility()
        if surfaceOpen { return closeSurface() }
        #if DEBUG_TOOLS
        trace("HOTKEY fired path=\(iconVisible ? "icon" : "panel")")
        #endif
        if iconVisible { showPopover(entry: "hotkey") } else { showPanel(entry: "hotkey") }
    }

    private func showPopover(entry: String) {
        guard let button = statusItem?.button else { return }
        surface.unfocusField()
        setOpen(true)
        popover.behavior = sticky ? .applicationDefined : .transient
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        #if DEBUG_TOOLS
        trace("OPEN entry=\(entry) focus=none")
        #endif
    }

    private func showPanel(entry: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        place(panel)
        surface.unfocusField()
        setOpen(true)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        #if DEBUG_TOOLS
        trace("OPEN entry=\(entry) focus=none")
        #endif
    }

    /// Centred horizontally on the display under the pointer, its top 8 pt below the visible top.
    func place(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: visible.midX - Config.width / 2, y: visible.maxY - 8 - Config.height,
                              width: Config.width, height: Config.height), display: false)
    }

    func makePanel() -> FloatingPanel {
        let host = NSHostingView(rootView: root().frame(width: Config.width, height: Config.height))
        let panel = FloatingPanel(content: host)
        panel.delegate = self
        return panel
    }

    func closeSurface() {
        guard surfaceOpen else { return }
        setOpen(false)
        popover.performClose(nil)
        panel?.orderOut(nil)
    }

    /// A click in any other app closes the panel (unless it is kept open).
    private func updateDismissMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        guard surfaceOpen, !sticky else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closeSurface() }
        }
    }

    private func setOpen(_ open: Bool) {
        surfaceOpen = open
        updateDismissMonitor()
        model.setSurfaceOpen(open || settingsWindow?.isVisible == true)
        assistant.setWatching(open)
    }

    /// Command+, and the icon's right-click menu. The Settings window is its own small window.
    func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 232),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Mi TV"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(shortcut: shortcut))
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        model.setSurfaceOpen(true)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu(from: sender)
        } else if surfaceOpen {
            closeSurface()
        } else if Date().timeIntervalSince(lastPopoverClose) > 0.3 {
            // A click on the icon closes a transient popover first; this stops it reopening at once.
            showPopover(entry: "icon")
        }
    }

    private func showMenu(from button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.addItem(item("Shortcut…", #selector(menuShortcut), ""))
        menu.addItem(item("Show Log", #selector(menuLog), ""))
        let keepOpen = item("Keep Open", #selector(menuSticky), "")
        keepOpen.state = sticky ? .on : .off
        menu.addItem(keepOpen)
        let login = item("Open at Login", #selector(menuLogin), "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("Quit Mi TV", #selector(menuQuit), "q"))
        if let event = NSApp.currentEvent { NSMenu.popUpContextMenu(menu, with: event, for: button) }
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    @objc private func menuShortcut() { openSettings() }
    @objc private func menuLog() { NSWorkspace.shared.open(Config.helperDirectory.appendingPathComponent("cam/tvd.log")) }
    @objc private func menuQuit() { NSApp.terminate(nil) }
    @objc private func menuSticky() { UserDefaults.standard.set(!sticky, forKey: "stickyPanel") }
    @objc private func menuLogin() {
        let service = SMAppService.mainApp
        do { if service.status == .enabled { try service.unregister() } else { try service.register() } } catch {}
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverClose = Date()
        if surfaceOpen { setOpen(false) }
    }

    /// The floating panel closes when it loses key status (a click elsewhere).
    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === panel { closeSurface() }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        shortcut.end()
        model.setSurfaceOpen(surfaceOpen)
    }
}

@main
struct TVRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    init() {
        #if DEBUG_TOOLS
        exitIfSelfTest()
        #endif
    }

    var body: some Scene {
        // Settings is a window of its own (AppDelegate.openSettings). This empty scene only satisfies App,
        // and its ⌘, menu item is rebound so it opens that window.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { AppDelegate.shared?.openSettings() }.keyboardShortcut(",", modifiers: .command)
                }
            }
    }
}
