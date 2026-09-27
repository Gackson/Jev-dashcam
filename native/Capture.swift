import AppKit
import ScreenCaptureKit
import Vision
import CoreGraphics

func emit(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
       var string = String(data: data, encoding: .utf8) {
        string += "\n"
        FileHandle.standardOutput.write(Data(string.utf8))
    }
}

func recognize(_ image: CGImage) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = true
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

func thumbnail(_ image: CGImage) -> [UInt8] {
    var pixels = [UInt8](repeating: 0, count: 96 * 64)
    pixels.withUnsafeMutableBytes { pointer in
        if let ctx = CGContext(data: pointer.baseAddress, width: 96, height: 64, bitsPerComponent: 8,
                               bytesPerRow: 96, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 96, height: 64))
        }
    }
    return pixels
}

func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 1 }
    return Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count * 255)
}

// Read only window metadata to ensure a different foreground window is never sampled.
func frontWindowInfo(pid: pid_t) -> [String: Any]? {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return windows.first { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
}

@main
struct Capture {
    @MainActor static func main() async {
        let args = CommandLine.arguments
        if args.contains("--check") {
            emit(["type": "permission", "granted": CGPreflightScreenCaptureAccess()])
            return
        }
        if args.contains("--list-windows") {
            guard CGPreflightScreenCaptureAccess() else {
                emit(["error": "需要屏幕录制权限才能读取窗口列表，也可以手动填写规则"]); return
            }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let windows: [[String: Any]] = content.windows.compactMap { window in
                    guard window.windowLayer == 0, let app = window.owningApplication,
                          app.bundleIdentifier != "ai.jevnote.mac", let title = window.title, !title.isEmpty else { return nil }
                    return ["id": String(window.windowID), "app": app.applicationName, "bundleID": app.bundleIdentifier, "title": title]
                }
                emit(["windows": windows])
            } catch { emit(["error": error.localizedDescription]) }
            return
        }
        if args.contains("--self-test") {
            // A bounded capture of our own synthetic window, never another app.
            guard CGPreflightScreenCaptureAccess() else {
                emit(["type": "permission", "granted": false]); return
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let window = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 860, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Jev Capture · Synthetic verification"
            window.backgroundColor = .white
            let label = NSTextField(wrappingLabelWithString: "AI notes and personal knowledge management\n\n自动收集信息，建立个人知识库。\n\nScreen capture, local OCR, topic classification.")
            label.font = NSFont.systemFont(ofSize: 26)
            label.textColor = .black
            label.frame = NSRect(x: 35, y: 35, width: 790, height: 290)
            window.contentView?.addSubview(label)
            window.orderFrontRegardless()
            do {
                try await Task.sleep(nanoseconds: 400_000_000)
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                    throw NSError(domain: "Jev", code: 2, userInfo: [NSLocalizedDescriptionKey: "测试窗口未出现在采集列表中"])
                }
                let config = SCStreamConfiguration()
                config.width = 1720; config.height = 764; config.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
                let text = try recognize(image)
                emit(["type": "self-test", "passed": text.contains("个人知识库") && text.contains("topic classification"), "text": text, "width": image.width, "height": image.height])
            } catch { emit(["type": "error", "message": error.localizedDescription]) }
            window.orderOut(nil)
            return
        }
        if let index = args.firstIndex(of: "--ocr"), args.count > index + 1 {
            do {
                guard let image = NSImage(contentsOfFile: args[index + 1])?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                else { throw NSError(domain: "Jev", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取图片"]) }
                emit(["type": "ocr", "text": try recognize(image)])
            } catch { emit(["type": "error", "message": error.localizedDescription]) }
            return
        }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            emit(["type": "permission", "granted": false])
            return
        }
        let output = args.count > 1 ? args[1] : "."
        let rulesPath = args.firstIndex(of: "--exclusions").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        let captureRunID = UUID().uuidString
        var previous: [UInt8] = []
        var previousWindow: CGWindowID = 0
        var dirtySince: Date? = Date()
        var lastOCR = Date.distantPast
        var lastText = ""
        var samples = 0
        var duplicates = 0
        emit(["type": "ready"])
        while !Task.isCancelled {
            do {
                // Capture only the foreground application's visible document window.
                // No keyboard text or mouse events are collected.
                guard let app = NSWorkspace.shared.frontmostApplication else {
                    emit(["type": "focus", "windowKey": ""])
                    try await Task.sleep(nanoseconds: 800_000_000); continue
                }
                let focusInfo = frontWindowInfo(pid: app.processIdentifier)
                let focusID = focusInfo?[kCGWindowNumber as String] as? UInt32
                let windowKey = focusID.map { "\(captureRunID):\(app.processIdentifier):\($0)" } ?? ""
                emit(["type": "focus", "windowKey": windowKey])
                let name = app.localizedName ?? "Unknown"
                if app.bundleIdentifier == "ai.jevnote.mac" {
                    emit(["type": "skipped", "app": name, "reason": "self"])
                    try await Task.sleep(nanoseconds: 800_000_000); continue
                }
                let excluded = ["com.apple.loginwindow", "com.apple.systempreferences", "com.agilebits.onepassword7", "com.1password.1password", "com.apple.Passwords"]
                if excluded.contains(app.bundleIdentifier ?? "") {
                    emit(["type": "skipped", "app": name, "reason": "excluded"])
                    try await Task.sleep(nanoseconds: 1_000_000_000); continue
                }
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                // Never fall back to a larger window behind the foreground window.
                guard let info = frontWindowInfo(pid: app.processIdentifier),
                      let frontID = info[kCGWindowNumber as String] as? UInt32, frontID == focusID,
                      let window = content.windows.first(where: { $0.windowID == frontID }),
                      window.frame.width > 220, window.frame.height > 160 else {
                    try await Task.sleep(nanoseconds: 800_000_000); continue
                }
                let title = info[kCGWindowName as String] as? String ?? window.title ?? name
                if title.localizedCaseInsensitiveContains("Jev-dashcam") {
                    emit(["type": "skipped", "app": name, "reason": "self"])
                    try await Task.sleep(nanoseconds: 800_000_000); continue
                }
                let rules = try WindowExclusion.load(path: rulesPath)
                if rules.contains(where: { $0.matches(app: name, bundleID: app.bundleIdentifier ?? "", title: title) }) {
                    previous = []; previousWindow = 0; dirtySince = Date(); lastText = ""
                    emit(["type": "skipped", "app": name, "reason": "window-excluded"])
                    try await Task.sleep(nanoseconds: 800_000_000); continue
                }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                      let currentInfo = frontWindowInfo(pid: app.processIdentifier),
                      currentInfo[kCGWindowNumber as String] as? UInt32 == window.windowID,
                      (currentInfo[kCGWindowName as String] as? String ?? title) == title else { continue }
                let configuration = SCStreamConfiguration()
                configuration.width = min(1920, Int(window.frame.width * 2))
                configuration.height = Int(Double(configuration.width) * window.frame.height / window.frame.width)
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration)
                // Settings and foreground app may change while ScreenCaptureKit is awaiting its frame.
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                      let currentInfo = frontWindowInfo(pid: app.processIdentifier),
                      currentInfo[kCGWindowNumber as String] as? UInt32 == window.windowID,
                      (currentInfo[kCGWindowName as String] as? String ?? title) == title else { continue }
                let latestRules = try WindowExclusion.load(path: rulesPath)
                guard !latestRules.contains(where: { $0.matches(app: name, bundleID: app.bundleIdentifier ?? "", title: title) }) else { continue }
                let current = thumbnail(image)
                let changed = window.windowID != previousWindow || difference(current, previous) > 0.012
                let now = Date()
                if changed && dirtySince == nil { dirtySince = now }
                let stable = !changed && dirtySince != nil
                let deadline = dirtySince.map { now.timeIntervalSince($0) >= 3 } ?? false
                let fallback = now.timeIntervalSince(lastOCR) >= 10
                samples += 1
                previous = current
                previousWindow = window.windowID
                if stable || deadline || fallback {
                    let text = try recognize(image)
                    lastOCR = now
                    dirtySince = nil
                    if text.count >= 20 && text != lastText {
                        lastText = text
                        let filename = UUID().uuidString.lowercased() + ".jpg"
                        let bitmap = NSBitmapImageRep(cgImage: image)
                        if let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.72]) {
                            try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(filename))
                            emit(["type": "capture", "windowKey": windowKey, "app": name, "bundleID": app.bundleIdentifier ?? "", "title": title, "text": text, "screenshot": filename,
                                  "reason": stable ? "stable" : (deadline ? "change" : "interval")])
                        }
                    } else { duplicates += 1 }
                }
                emit(["type": "tick", "samples": samples, "duplicates": duplicates, "app": name])
                try await Task.sleep(nanoseconds: 800_000_000)
            } catch {
                emit(["type": "error", "message": error.localizedDescription])
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
