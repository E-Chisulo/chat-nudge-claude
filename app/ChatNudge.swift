// Chat Nudge: a menu-bar app that tells you when a Claude chat has finished,
// shows a short brief, lets you reply with an instruction, and keeps nudging
// (louder each time) until you deal with it.
//
// It reads and writes plain files under ~/.claude/nudge, which the chat-nudge
// mod inside each Claude chat keeps up to date:
//   pending/<session>.json  a chat that finished and is waiting on you
//   replies/<session>.txt   your reply; the mod submits it into the chat
//
// Build with ./build.sh (see README.md).

import AppKit
import CoreGraphics
import ServiceManagement
import SwiftUI
import UserNotifications

let claudeBundleID = "com.anthropic.claudefordesktop"

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let root = home.appendingPathComponent(".claude/nudge")
    static let pending = root.appendingPathComponent("pending")
    static let replies = root.appendingPathComponent("replies")
    static let sessions = home.appendingPathComponent(
        "Library/Application Support/Claude/claude-code-sessions")

    static func pendingFile(_ sid: String) -> URL { pending.appendingPathComponent("\(sid).json") }
    static func replyFile(_ sid: String) -> URL { replies.appendingPathComponent("\(sid).txt") }
}

// MARK: - Model

struct PendingFile: Codable, Equatable {
    var sessionId: String
    var hostSessionId: String?
    var cwd: String?
    var finishedAt: Double
    var durationMs: Double?
    var reason: String?
    var asked: String?
    var brief: String?
    var question: String?
    var answer: String?
}

struct Waiting: Identifiable, Equatable {
    let key: String
    var file: PendingFile
    var title = ""
    var project = ""
    var nagCount = 0
    var nextNagAt = Date.distantPast
    var snoozedUntil: Date?
    var sendingSince: Date?
    var sendingText = ""

    var id: String { key }
    var hostId: String { file.hostSessionId ?? "" }
    var finished: Date { Date(timeIntervalSince1970: file.finishedAt / 1000) }
    var isSnoozed: Bool { snoozedUntil.map { Date() < $0 } ?? false }
}

func ago(_ date: Date) -> String {
    let s = max(0, Int(Date().timeIntervalSince(date)))
    if s < 60 { return "just now" }
    if s < 3600 { return "\(s / 60) min ago" }
    let m = (s % 3600) / 60
    return m == 0 ? "\(s / 3600) h ago" : "\(s / 3600) h \(m) min ago"
}

func clip(_ s: String, _ n: Int) -> String {
    s.count <= n ? s : String(s.prefix(n - 1)) + "…"
}

// MARK: - The desktop app's own session records (titles, archive flag, focus)

enum Sessions {
    struct Info {
        var title: String?
        var archived = false
    }

    private static var pathCache: [String: URL] = [:]

    private static func subdirs(_ url: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    private static func allFiles() -> [URL] {
        var out: [URL] = []
        for account in subdirs(Paths.sessions) {
            for org in subdirs(account) {
                let files = (try? FileManager.default.contentsOfDirectory(
                    at: org, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                out += files.filter {
                    $0.lastPathComponent.hasPrefix("local_") && $0.pathExtension == "json"
                }
            }
        }
        return out
    }

    static func file(for hostId: String) -> URL? {
        if let u = pathCache[hostId], FileManager.default.fileExists(atPath: u.path) { return u }
        for account in subdirs(Paths.sessions) {
            for org in subdirs(account) {
                let u = org.appendingPathComponent("\(hostId).json")
                if FileManager.default.fileExists(atPath: u.path) {
                    pathCache[hostId] = u
                    return u
                }
            }
        }
        return nil
    }

    static func info(_ hostId: String) -> Info {
        guard !hostId.isEmpty, let u = file(for: hostId),
            let data = try? Data(contentsOf: u),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return Info() }
        let title = (json["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Info(title: title, archived: json["isArchived"] as? Bool ?? false)
    }

    /// The chat the desktop app shows right now: the one focused most recently.
    static func focusedHostId() -> String {
        let files = allFiles().map { url -> (URL, Double) in
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return (url, m.timeIntervalSince1970 * 1000)
        }.sorted { $0.1 > $1.1 }

        var best = ("", 0.0)
        let pattern = try! NSRegularExpression(pattern: #""lastFocusedAt":(\d+)"#)
        for (url, modified) in files {
            // A file is rewritten when its chat is focused, so nothing modified
            // before the best focus time found so far can beat it.
            if modified < best.1 { break }
            guard let handle = FileHandle(forReadingAtPath: url.path) else { continue }
            let head = String(decoding: handle.readData(ofLength: 4096), as: UTF8.self)
            try? handle.close()
            let range = NSRange(head.startIndex..., in: head)
            if let m = pattern.firstMatch(in: head, range: range),
                let r = Range(m.range(at: 1), in: head), let v = Double(head[r]), v > best.1
            {
                best = (url.deletingPathExtension().lastPathComponent, v)
            }
        }
        return best.0
    }
}

// MARK: - Store: loads what's waiting, nags, sends replies

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var items: [Waiting] = []
    @Published var notificationsAllowed = true
    @Published var pausedUntil: Date?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var nagMinutes: Int {
        didSet { defaults.set(nagMinutes, forKey: "nagMinutes") }
    }
    @Published var speak: Bool {
        didSet { defaults.set(speak, forKey: "speak") }
    }

    private let defaults = UserDefaults.standard
    private let center = UNUserNotificationCenter.current()
    private var dismissed: Set<String>
    private var timer: Timer?
    private var panel: NSPanel?

    /// After this many nags a sound and a spoken line join in.
    let loudFrom = 2
    /// After this many the floating window comes up and stays until handled.
    let windowFrom = 3
    /// Chats older than this stop being tracked.
    let maxAge: TimeInterval = 24 * 3600

    var interval: TimeInterval { TimeInterval(nagMinutes * 60) }
    var isPaused: Bool { pausedUntil.map { Date() < $0 } ?? false }

    init() {
        nagMinutes = defaults.object(forKey: "nagMinutes") as? Int ?? 5
        speak = defaults.object(forKey: "speak") as? Bool ?? true
        dismissed = Set(defaults.stringArray(forKey: "dismissed") ?? [])
    }

    func start() {
        try? FileManager.default.createDirectory(at: Paths.pending, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: Paths.replies, withIntermediateDirectories: true)
        registerCategories()
        center.requestAuthorization(options: [.alert, .sound, .badge]) { ok, _ in
            Task { @MainActor in Store.shared.notificationsAllowed = ok }
        }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            Task { @MainActor in Store.shared.tick() }
        }
    }

    func refreshPermission() {
        center.getNotificationSettings { s in
            let ok = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            Task { @MainActor in Store.shared.notificationsAllowed = ok }
        }
    }

    // MARK: tick

    private func loadPending() -> [PendingFile] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: Paths.pending, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(PendingFile.self, from: data)
        }
    }

    func tick() {
        let now = Date()
        let old = Dictionary(items.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var next: [Waiting] = []
        var live = Set<String>()

        for f in loadPending() {
            let key = "\(f.sessionId):\(Int(f.finishedAt))"
            live.insert(key)
            if dismissed.contains(key) { continue }
            let info = Sessions.info(f.hostSessionId ?? "")
            let finished = Date(timeIntervalSince1970: f.finishedAt / 1000)
            if info.archived || now.timeIntervalSince(finished) > maxAge {
                try? FileManager.default.removeItem(at: Paths.pendingFile(f.sessionId))
                continue
            }
            var w = old[key] ?? Waiting(key: key, file: f)
            w.file = f
            w.project = URL(fileURLWithPath: f.cwd ?? "").lastPathComponent
            w.title = info.title ?? (w.project.isEmpty ? "Claude chat" : w.project)
            next.append(w)
        }

        // Forget notifications of chats you answered (the mod removed the file).
        for (key, w) in old where !next.contains(where: { $0.key == key }) {
            clearNotifications(key, upTo: w.nagCount)
            // Gone while your reply was still unread: the chat ended or was
            // cleaned up before picking it up. Don't lose the reply.
            if w.sendingSince != nil,
                FileManager.default.fileExists(atPath: Paths.replyFile(w.file.sessionId).path)
            {
                fallback(w)
            }
        }
        if !dismissed.isSubset(of: live) {
            dismissed.formIntersection(live)
            defaults.set(Array(dismissed), forKey: "dismissed")
        }

        // Replies the chat never picked up: its engine isn't running.
        for i in next.indices {
            guard let since = next[i].sendingSince, now.timeIntervalSince(since) > 15 else { continue }
            if FileManager.default.fileExists(atPath: Paths.replyFile(next[i].file.sessionId).path) {
                fallback(next[i])
            }
            next[i].sendingSince = nil
            next[i].nextNagAt = now.addingTimeInterval(interval)
        }

        if let p = pausedUntil, now >= p { pausedUntil = nil }
        if !isPaused {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == claudeBundleID
            let idle = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            let watching = front && idle < 120 ? Sessions.focusedHostId() : ""

            for i in next.indices {
                var w = next[i]
                guard w.sendingSince == nil, !w.isSnoozed, now >= w.nextNagAt else { continue }
                if !w.hostId.isEmpty && w.hostId == watching {
                    // You're looking at this chat right now: hold off.
                    w.nextNagAt = now.addingTimeInterval(interval)
                } else {
                    nag(w)
                    w.nagCount += 1
                    w.snoozedUntil = nil
                    w.nextNagAt = now.addingTimeInterval(interval)
                }
                next[i] = w
            }
        }

        items = next.sorted { $0.file.finishedAt > $1.file.finishedAt }
        if !items.contains(where: needsWindow) { hidePanel() }
    }

    private func needsWindow(_ w: Waiting) -> Bool {
        w.nagCount > windowFrom && !w.isSnoozed && w.sendingSince == nil
    }

    // MARK: nagging

    private func nag(_ w: Waiting) {
        let level = w.nagCount
        let c = UNMutableNotificationContent()
        if level == 0 {
            c.title = (w.file.reason == "error" ? "Stopped · " : "Done · ") + w.title
        } else {
            c.title = "Still waiting (\(ago(w.finished))) · \(w.title)"
        }
        if let q = w.file.question, !q.isEmpty {
            c.subtitle = "Asks: \(q)"
        } else if !w.project.isEmpty && w.project != w.title {
            c.subtitle = w.project
        }
        c.body = (w.file.brief?.isEmpty == false ? w.file.brief! : "Finished.")
        c.sound = .default
        c.categoryIdentifier = "NUDGE"
        c.threadIdentifier = w.key
        c.userInfo = ["key": w.key]
        clearNotifications(w.key, upTo: level)
        center.add(UNNotificationRequest(identifier: "\(w.key)#\(level)", content: c, trigger: nil))

        // The app's own sound on every nudge, not only the system chime, which
        // is short and easy to miss. It gets louder and longer as it escalates.
        ring(level: level)
        if level >= loudFrom && speak { say("Claude is still waiting on \(clip(w.title, 60))") }
        if level >= windowFrom { showPanel() }
    }

    private func ring(level: Int) {
        let name: String
        let times: Int
        switch level {
        case 0: (name, times) = ("Glass", 1)
        case 1: (name, times) = ("Glass", 2)
        default: (name, times) = ("Submarine", 3)
        }
        for i in 0..<times {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9 * Double(i)) {
                NSSound(named: NSSound.Name(name))?.play()
            }
        }
    }

    /// The "Test" button: a sample nudge at full volume, so you know what to listen for.
    func testAlert() {
        inform("This is a nudge", "When a chat finishes you'll get this, then louder ones until you answer.")
        ring(level: loudFrom)
        if speak { say("Claude is still waiting on your chat") }
    }

    private func say(_ text: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = [text]
        try? p.run()
    }

    private func clearNotifications(_ key: String, upTo n: Int) {
        let ids = (0...max(n, 0)).map { "\(key)#\($0)" }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    private func registerCategories() {
        let reply = UNTextInputNotificationAction(
            identifier: "REPLY", title: "Reply…", options: [],
            textInputButtonTitle: "Send", textInputPlaceholder: "Tell Claude what to do next")
        let open = UNNotificationAction(identifier: "OPEN", title: "Open chat", options: [.foreground])
        let snooze = UNNotificationAction(identifier: "SNOOZE", title: "Snooze 15 min", options: [])
        let done = UNNotificationAction(identifier: "DONE", title: "Got it", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "NUDGE", actions: [reply, open, snooze, done], intentIdentifiers: [],
                options: [])
        ])
    }

    private func inform(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: actions

    private func index(_ key: String) -> Int? { items.firstIndex { $0.key == key } }

    func sendReply(_ key: String, _ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let i = index(key) else { return }
        let sid = items[i].file.sessionId
        let tmp = Paths.replies.appendingPathComponent(".\(sid).tmp")
        do {
            try t.write(to: tmp, atomically: false, encoding: .utf8)
            guard rename(tmp.path, Paths.replyFile(sid).path) == 0 else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            inform("Couldn't send your reply", "Writing to ~/.claude/nudge/replies failed.")
            return
        }
        items[i].sendingSince = Date()
        items[i].sendingText = t
        clearNotifications(key, upTo: items[i].nagCount)
        if !items.contains(where: needsWindow) { hidePanel() }
    }

    /// The chat's engine isn't running, so open it and leave the reply on the clipboard.
    private func fallback(_ w: Waiting) {
        try? FileManager.default.removeItem(at: Paths.replyFile(w.file.sessionId))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(w.sendingText, forType: .string)
        openChat(w)
        inform(
            "Your reply is on the clipboard",
            "\(w.title) wasn't running, so it's open now. Paste with ⌘V and press Return.")
    }

    private func openChat(_ w: Waiting) {
        if !w.hostId.isEmpty, let url = URL(string: "claude://code/continue?session=\(w.hostId)") {
            NSWorkspace.shared.open(url)
        } else if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) {
            NSWorkspace.shared.openApplication(at: app, configuration: .init())
        }
    }

    func open(_ key: String) {
        guard let i = index(key) else { return }
        openChat(items[i])
        // Opening isn't answering: the nagging pauses for one round, then resumes.
        items[i].nextNagAt = Date().addingTimeInterval(interval)
        clearNotifications(key, upTo: items[i].nagCount)
        hidePanel()
    }

    func snooze(_ key: String, minutes: Int) {
        guard let i = index(key) else { return }
        let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        items[i].snoozedUntil = until
        items[i].nextNagAt = until
        clearNotifications(key, upTo: items[i].nagCount)
        if !items.contains(where: needsWindow) { hidePanel() }
    }

    func dismiss(_ key: String) {
        guard let i = index(key) else { return }
        clearNotifications(key, upTo: items[i].nagCount)
        dismissed.insert(key)
        defaults.set(Array(dismissed), forKey: "dismissed")
        items.remove(at: i)
        if !items.contains(where: needsWindow) { hidePanel() }
    }

    /// Sample chats for `--snapshot`; never called in normal use.
    func showSamples() {
        let now = Date().timeIntervalSince1970 * 1000
        func sample(_ n: Int, _ title: String, _ project: String, _ mins: Double, _ brief: String, _ q: String) -> Waiting {
            var w = Waiting(
                key: "sample\(n)",
                file: PendingFile(
                    sessionId: "sample\(n)", hostSessionId: "", cwd: "/Users/x/\(project)",
                    finishedAt: now - mins * 60_000, durationMs: nil, reason: "answer",
                    asked: "Add a dark mode toggle to the settings page and keep the choice after a reload",
                    brief: brief, question: q, answer: brief))
            w.title = title
            w.project = project
            w.nagCount = n == 1 ? 4 : 0
            return w
        }
        items = [
            sample(0, "Dark mode for the settings page", "my-app", 0.2,
                   "Added the toggle and saved the choice in local storage. Tested in Safari and Chrome, both keep it after a reload.",
                   "Should it follow the system setting by default?"),
            sample(1, "Fix the flaky login test", "api", 23,
                   "The test was racing the session cookie. Added a wait on the redirect and it passed 50 runs in a row. Nothing committed yet.", ""),
        ]
    }

    func pause(hours: Double) { pausedUntil = Date().addingTimeInterval(hours * 3600); hidePanel() }
    func resume() { pausedUntil = nil }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            inform("Couldn't change Open at Login", error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: floating window

    private func showPanel() {
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 520),
                styleMask: [.titled, .closable, .resizable, .utilityWindow],
                backing: .buffered, defer: false)
            p.title = "Claude is waiting on you"
            p.level = .floating
            p.isFloatingPanel = true
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: WaitingList(store: self, inWindow: true))
            panel = p
        }
        guard let p = panel, !p.isVisible else { return }
        if let screen = NSScreen.main?.visibleFrame {
            p.setFrameTopLeftPoint(NSPoint(x: screen.maxX - 440, y: screen.maxY - 20))
        }
        p.orderFrontRegardless()
    }

    private func hidePanel() { panel?.orderOut(nil) }
}

// MARK: - Views

struct WaitingList: View {
    @ObservedObject var store: Store
    var inWindow = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(store.items.isEmpty ? "Chat Nudge" : "\(store.items.count) waiting on you")
                    .font(.headline)
                Spacer()
                if store.isPaused, let p = store.pausedUntil {
                    Text("Paused until \(p.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !store.notificationsAllowed {
                HStack {
                    Image(systemName: "bell.slash").foregroundStyle(.orange)
                    Text("Notifications are off for Chat Nudge.").font(.caption)
                    Spacer()
                    Button("Settings") {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }.font(.caption)
                }
            }
            if store.items.isEmpty {
                Text("No chats waiting. You'll hear from me when one finishes.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(store.items) { ItemCard(store: store, item: $0) }
                    }
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(key: ListHeight.self, value: g.size.height)
                        })
                }
                // The menu window sizes itself to its content's minimum, and a
                // ScrollView's minimum is nearly nothing: give it the list's
                // own height, up to a cap.
                .frame(height: inWindow ? nil : min(max(listHeight, 60), 480))
                .onPreferenceChange(ListHeight.self) { listHeight = $0 }
            }
            if !inWindow {
                Divider()
                Footer(store: store)
            }
        }
        .padding(14)
        // One fixed width in the menu (a min-width wrapper let the window
        // shrink below the content and clip both sides).
        .frame(width: inWindow ? nil : 400)
        .frame(minWidth: inWindow ? 380 : nil, maxWidth: inWindow ? .infinity : nil, alignment: .topLeading)
    }

    @State private var listHeight: CGFloat = 0
}

struct ListHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ItemCard: View {
    @ObservedObject var store: Store
    let item: Waiting
    @State private var draft = ""
    @State private var expanded = false

    private func send() {
        store.sendReply(item.key, draft)
        draft = ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.title).font(.system(.body, weight: .semibold)).lineLimit(1)
                Spacer()
                Text(ago(item.finished)).font(.caption).foregroundStyle(.secondary)
            }
            if !item.project.isEmpty && item.project != item.title {
                Text(item.project).font(.caption).foregroundStyle(.secondary)
            }
            if let asked = item.file.asked, !asked.isEmpty {
                Text("You asked: \(asked)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Text(item.file.brief ?? "Finished.").font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let q = item.file.question, !q.isEmpty {
                Label(q, systemImage: "questionmark.bubble").font(.callout.weight(.medium))
                    .foregroundStyle(.orange)
            }
            if expanded, let a = item.file.answer, !a.isEmpty {
                ScrollView {
                    Text(a).font(.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 160)
            }
            if item.sendingSince != nil {
                Label("Sent. Waiting for the chat to pick it up…", systemImage: "paperplane")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    TextField("Reply with an instruction…", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(send)
                    Button("Send", action: send)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            HStack(spacing: 14) {
                Button("Open chat") { store.open(item.key) }
                Menu("Snooze") {
                    Button("15 minutes") { store.snooze(item.key, minutes: 15) }
                    Button("1 hour") { store.snooze(item.key, minutes: 60) }
                    Button("3 hours") { store.snooze(item.key, minutes: 180) }
                }
                .menuStyle(.borderlessButton).tint(.accentColor).fixedSize()
                Button("Got it") { store.dismiss(item.key) }
                Spacer()
                if item.file.answer?.isEmpty == false {
                    Button(expanded ? "Less" : "Full reply") { expanded.toggle() }
                }
            }
            .buttonStyle(.link).font(.caption).controlSize(.small)
            if item.isSnoozed, let s = item.snoozedUntil {
                Text("Snoozed until \(s.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 8).stroke(
                item.nagCount > store.loudFrom ? Color.orange.opacity(0.7) : Color.secondary.opacity(0.2)))
    }
}

struct Footer: View {
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Nag every", selection: $store.nagMinutes) {
                    ForEach([2, 5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                }.fixedSize()
                Spacer()
                Toggle("Speak", isOn: $store.speak).toggleStyle(.checkbox)
                Button("Test") { store.testAlert() }
            }
            HStack {
                Toggle(
                    "Open at login",
                    isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) })
                ).toggleStyle(.checkbox)
                Spacer()
                if store.isPaused {
                    Button("Resume") { store.resume() }
                } else {
                    Menu("Pause") {
                        Button("1 hour") { store.pause(hours: 1) }
                        Button("3 hours") { store.pause(hours: 3) }
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .font(.caption)
        .controlSize(.small)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            // Renders the menu with sample chats to a PNG and quits, to check layout.
            let out = args[i + 1]
            Task { @MainActor in renderSnapshot(to: out) }
            return
        }
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in Store.shared.start() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in Store.shared.refreshPermission() }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let key = response.notification.request.content.userInfo["key"] as? String ?? ""
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText ?? ""
        Task { @MainActor in
            let store = Store.shared
            switch action {
            case "REPLY": store.sendReply(key, text)
            case "SNOOZE": store.snooze(key, minutes: 15)
            case "DONE": store.dismiss(key)
            case "OPEN", UNNotificationDefaultActionIdentifier: store.open(key)
            default: break
            }
            completionHandler()
        }
    }
}

@MainActor
func renderSnapshot(to path: String) {
    let store = Store.shared
    store.showSamples()
    let host = NSHostingView(
        rootView: WaitingList(store: store)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.borderless],
        backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .darkAqua)
    window.backgroundColor = .windowBackgroundColor
    window.contentView = host
    // Let the preference pass settle the list height before measuring.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
        let size = host.fittingSize
        print("menu content size: \(Int(size.width)) x \(Int(size.height)) pt")
        window.setContentSize(size)
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        exit(0)
    }
}

@main
struct ChatNudgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject private var store = Store.shared

    private var waiting: Int { store.items.filter { !$0.isSnoozed }.count }

    var body: some Scene {
        MenuBarExtra {
            WaitingList(store: store)
        } label: {
            Image(systemName: waiting > 0 ? "bell.badge.fill" : "bell")
            if waiting > 0 { Text("\(waiting)") }
        }
        .menuBarExtraStyle(.window)
    }
}
