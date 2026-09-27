import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO

struct Topic: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    let color: String
    var tint: Color {
        switch color {
        case "peach": return .orange
        case "blue": return .blue
        case "lavender": return .purple
        case "yellow": return .yellow
        default: return .green
        }
    }
}
struct Frame: Codable, Identifiable, Equatable {
    let image: String
    let time: String
    let text: String
    var id: String { image }
}
struct Note: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let app: String
    let url: String
    let text: String
    let frames: [Frame]
    let scores: [String: Double]
    let manual: [String: Bool]
    let labels: [String]
    let status: String
    let error: String?
    let model: String?
    let updated: String
    let kind: String
    var session_id: String? = nil
    var stateLabel: String {
        switch status {
        case "processing": return "正在归类"
        case "pending": return "等待归类"
        case "error": return "归类失败"
        case "unmatched": return "待整理"
        default: return "已归类"
        }
    }
    var dateLabel: String {
        NoteDateCache.label(updated)
    }
}
extension ISO8601DateFormatter {
    static let jev: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
struct CollectorStatus: Decodable, Equatable {
    var capture: String
    var message: String
    var app: String
    var samples: Int
    var duplicates: Int
    var error: String?
    var queue: Int
    var modelConfigured: Bool
    var model: String
    var helperReady: Bool
    var running: Bool { capture == "running" || capture == "starting" }
    static let empty = CollectorStatus(capture: "paused", message: "准备好后，开始收集你的灵感", app: "", samples: 0, duplicates: 0, queue: 0, modelConfigured: false, model: "jev-latest", helperReady: false)
}
struct Activity: Decodable, Identifiable, Equatable { let id: String; let message: String; let type: String; let time: String }
struct CapturePreferences: Codable, Equatable { var windowReturnSeconds: Int = 60 }
struct Snapshot: Decodable { let topics: [Topic]; let records: [Note]; let status: CollectorStatus; let events: [Activity]; var windowExclusions: [WindowExclusion]? = nil; var capturePreferences: CapturePreferences? = nil }
struct AppError: LocalizedError { let message: String; var errorDescription: String? { message } }
enum EditorSheet: String, Identifiable { case topic, note, capture; var id: String { rawValue } }

@MainActor
final class NoteStore: ObservableObject {
    @Published var topics: [Topic] = []
    @Published var records: [Note] = []
    @Published var status = CollectorStatus.empty
    @Published var events: [Activity] = []
    @Published var windowExclusions: [WindowExclusion] = []
    @Published var capturePreferences = CapturePreferences()
    @Published var ready = false
    @Published var starting = false
    @Published var error: String?
    @Published var startupError: String?
    @Published var sheet: EditorSheet?
    @Published var filter: String? = "all"
    @Published var selection: String?
    @Published var search = ""
    @Published var busy = false
    @Published var notice: String?
    @Published var previewFrame: Frame?
    @Published var organization = LibraryOrganization()
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var timer: Task<Void, Never>?
    private var startDeadline: Task<Void, Never>?
    private var stdoutBuffer = Data()
    private var endpoint: URL?
    private var token = ""
    private var refreshing = false
    let directory: URL

    init() {
        if let override = ProcessInfo.processInfo.environment["JEV_APP_DATA_DIR"] {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jev Note", isDirectory: true)
        }
    }
    var scopedRecords: [Note] {
        records.filter { note in
            let category = filter ?? "all"
            let matches = category == "all" || (category == "unmatched" && note.labels.isEmpty) || (category == "errors" && note.status == "error") || note.labels.contains(category)
            return matches
        }
    }
    var filtered: [Note] {
        scopedRecords.filter { note in
            organization.matches(note) && (search.isEmpty || "\(note.title)\n\(note.text)\n\(note.app)".localizedCaseInsensitiveContains(search))
        }
    }
    var heading: String {
        switch filter {
        case "all", nil: return "全部资料"
        case "unmatched": return "待整理"
        case "errors": return "归类失败"
        default: return topics.first { $0.id == filter }?.name ?? "资料库"
        }
    }
    var projects: [NoteProject] { NoteProject.collect(filtered) }
    var selected: NoteProject? { projects.first { $0.id == selection } }
    var selectedTopic: Topic? { topics.first { $0.id == filter } }

    func copyTopicPrompt(_ topic: Topic) -> Bool {
        do {
            let context = TopicAgentContext(topic: topic, records: records, directory: directory)
            let file = try context.write(to: directory.appendingPathComponent("agent-context", isDirectory: true))
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(context.prompt(file: file), forType: .string) else {
                throw AppError(message: "无法写入剪贴板，请重试。")
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func start() {
        guard process == nil else { return }
        starting = true; startupError = nil; stdoutBuffer = Data()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard let resources = Bundle.main.resourceURL else { throw AppError(message: "应用资源不完整，请重新构建 App。") }
            let child = Process()
            child.executableURL = resources.appendingPathComponent("runtime/node")
            child.arguments = [resources.appendingPathComponent("service/server.mjs").path]
            child.currentDirectoryURL = directory
            token = UUID().uuidString + UUID().uuidString
            var environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "HOME": NSHomeDirectory(), "TMPDIR": NSTemporaryDirectory()]
            environment["PORT"] = "0"
            environment["JEV_DATA_DIR"] = directory.path
            environment["JEV_ENV_FILE"] = directory.appendingPathComponent(".env").path
            environment["JEV_DESKTOP_TOKEN"] = token
            child.environment = environment
            let incoming = Pipe(), outgoing = Pipe()
            child.standardInput = incoming; child.standardOutput = outgoing
            // Do not persist API keys or captured content in logs.
            child.standardError = FileHandle.nullDevice
            input = incoming; output = outgoing
            outgoing.fileHandleForReading.readabilityHandler = { [weak self, weak child] handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                Task { @MainActor in
                    guard let self, self.process === child else { return }
                    self.receive(data)
                }
            }
            child.terminationHandler = { [weak self] child in
                Task { @MainActor in
                    guard let self, self.process === child else { return }
                    self.stop()
                    self.startupError = "本地服务已停止（\(child.terminationStatus)）。资料已保存在此 Mac，请重新启动服务。"
                }
            }
            process = child
            try child.run()
            startDeadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled, let self, !self.ready else { return }
                self.stop(); self.startupError = "本地服务启动超时，请重试。"
            }
        } catch {
            stop(); startupError = "无法启动 Jev-dashcam：\(error.localizedDescription)"
        }
    }
    private func receive(_ data: Data) {
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: 10) {
            let line = stdoutBuffer.prefix(upTo: newline)
            stdoutBuffer.removeSubrange(...newline)
            guard let info = try? JSONSerialization.jsonObject(with: line) as? [String: Any], info["type"] as? String == "ready", let port = info["port"] as? Int else { continue }
            endpoint = URL(string: "http://127.0.0.1:\(port)")
            ready = true; starting = false; startDeadline?.cancel()
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refresh()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }
    func stop() {
        timer?.cancel(); timer = nil; startDeadline?.cancel(); startDeadline = nil
        output?.fileHandleForReading.readabilityHandler = nil
        try? input?.fileHandleForWriting.close()
        let child = process; process = nil
        if child?.isRunning == true { child?.terminate() }
        input = nil; output = nil; endpoint = nil; ready = false; starting = false
    }
    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        guard let endpoint else { throw AppError(message: "本地服务尚未就绪") }
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = method; request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw AppError(message: info?["error"] as? String ?? "本地服务请求失败")
        }
        return data
    }
    func refresh() async {
        guard !refreshing, ready else { return }
        refreshing = true; defer { refreshing = false }
        do {
            let data = try await request("api/state")
            let snapshot = try await Task.detached(priority: .utility) {
                try JSONDecoder().decode(Snapshot.self, from: data)
            }.value
            guard !Task.isCancelled, ready else { return }
            apply(snapshot)
        } catch { if !Task.isCancelled && ready { self.error = error.localizedDescription } }
    }
    func apply(_ snapshot: Snapshot) {
        // @Published emits even for equal values. Avoid rebuilding the whole library
        // on every poll when only the capture heartbeat (or nothing) changed.
        if topics != snapshot.topics { topics = snapshot.topics }
        if records != snapshot.records { records = snapshot.records }
        if status != snapshot.status { status = snapshot.status }
        if events != snapshot.events { events = snapshot.events }
        if let preferences = snapshot.capturePreferences, capturePreferences != preferences { capturePreferences = preferences }
        if let rules = snapshot.windowExclusions, windowExclusions != rules { windowExclusions = rules }
    }
    @discardableResult
    func mutate(_ path: String, method: String = "POST", body: [String: Any] = [:]) async -> Bool {
        guard !busy else { return false }
        busy = true; defer { busy = false }
        do {
            let data = try await request(path, method: method, body: body)
            let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if result?["skipped"] as? Bool == true { throw AppError(message: "文字太少，请至少输入 10 个字。") }
            if result?["duplicate"] as? Bool == true { notice = "这份内容已经收集过，已保留原资料。" }
            await refresh()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func availableWindows() async throws -> [AvailableWindow] {
        struct Response: Decodable { let windows: [AvailableWindow] }
        return try JSONDecoder().decode(Response.self, from: await request("api/windows")).windows
    }
    func saveWindowExclusions(_ rules: [WindowExclusion]) async -> Bool {
        let rows = rules.map { ["id": $0.id, "app": $0.app, "bundleID": $0.bundleID, "title": $0.title, "match": $0.match] }
        return await mutate("api/window-exclusions", body: ["rules": rows])
    }
    func toggleCapture() {
        if status.running { Task { await mutate("api/capture/stop") } }
        else { sheet = .capture }
    }
    func export() {
        Task {
            do {
                let data = try await request("api/export")
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "Jev-dashcam 资料.json"
                panel.allowedContentTypes = [.json]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try data.write(to: url, options: .atomic)
                notice = "资料已导出。完整备份请同时复制数据目录中的截图。"
            } catch { self.error = error.localizedDescription }
        }
    }
    func openData() { NSWorkspace.shared.open(directory) }
    func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
    func screenshot(_ frame: Frame, maxPixelSize: Int = 1600) async -> NSImage? {
        guard let decoded = await ScreenshotPipeline.shared.image(directory: directory, filename: frame.image, maxPixelSize: maxPixelSize), !Task.isCancelled else { return nil }
        return NSImage(cgImage: decoded, size: NSSize(width: decoded.width, height: decoded.height))
    }
}
