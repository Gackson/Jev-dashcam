import Foundation
import AppKit
import Combine

@main
struct NativePerformanceTests {
    @MainActor static func main() async throws {
        let store = NoteStore()
        let snapshot = Snapshot(topics: [], records: [], status: .empty, events: [])
        var notifications = 0
        var recordNotifications = 0
        let observer = store.objectWillChange.sink { notifications += 1 }
        let recordsObserver = store.$records.dropFirst().sink { _ in recordNotifications += 1 }
        for _ in 0..<100 { store.apply(snapshot) }
        precondition(notifications == 0, "Idle polls must not invalidate the UI")
        var status = CollectorStatus.empty
        status.samples = 1
        store.apply(Snapshot(topics: [], records: [], status: status, events: []))
        precondition(notifications == 1 && recordNotifications == 0, "Capture heartbeat must not republish records")
        let item = Note(id: "test", title: "Test", app: "Test", url: "", text: "Synthetic text", frames: [], scores: [:], manual: [:], labels: [], status: "pending", error: nil, model: nil, updated: "2026-09-27T00:00:00.000Z", kind: "manual")
        let changed = Snapshot(topics: [], records: [item], status: status, events: [])
        store.apply(changed)
        precondition(recordNotifications == 1 && store.records.count == 1, "Changed records must still reach the UI")
        for _ in 0..<100 { store.apply(changed) }
        precondition(recordNotifications == 1)
        observer.cancel(); recordsObserver.cancel()

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jev-performance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("screenshots"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3200, pixelsHigh: 2000, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        memset(bitmap.bitmapData!, 160, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let filename = "abcd-1234.jpg"
        try bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])!.write(to: root.appendingPathComponent("screenshots/\(filename)"))
        let pipeline = ScreenshotPipeline()
        let first = await pipeline.image(directory: root, filename: filename, maxPixelSize: 640)
        precondition(first?.width == 640 && first?.height == 400)
        let second = await pipeline.image(directory: root, filename: filename, maxPixelSize: 640)
        precondition(first === second, "Warm image requests must reuse the decoded image")
        let count = await pipeline.decodeCount
        precondition(count == 1, "Repeated requests must not decode again")
        _ = await pipeline.image(directory: root, filename: filename, maxPixelSize: 1920)
        _ = await pipeline.image(directory: root, filename: filename, maxPixelSize: 16384)
        let thumbnail = await pipeline.image(directory: root, filename: filename, maxPixelSize: 640)
        precondition(thumbnail === first, "Opening a large image must not discard thumbnail cache")
        let invalid = await pipeline.image(directory: root, filename: "../outside.jpg", maxPixelSize: 640)
        let missing = await pipeline.image(directory: root, filename: "ffff.jpg", maxPixelSize: 640)
        precondition(invalid == nil && missing == nil)
        print("Passed: 200 unchanged polls cause zero extra record publications; heartbeat publishes only status; changed records publish; image decoding off main thread; thumbnail cache survives large previews; safe missing/invalid images.")
    }
}
