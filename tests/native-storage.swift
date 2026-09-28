import AppKit

@main struct StorageTests {
    @MainActor static func waitForService(_ store: NoteStore) async throws {
        for _ in 0..<150 {
            if store.ready { return }
            if let error = store.startupError { throw AppError(message: error) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw AppError(message: "test service startup timeout")
    }
    @MainActor static func main() async throws {
        // This executable runs in its own fixture bundle, so preferences and data
        // are isolated from the installed app. Exercise the actual bundled service.
        precondition(Bundle.main.bundleIdentifier == "ai.jevnote.storage-tests")
        UserDefaults.standard.removeObject(forKey: StorageLocation.preferenceKey)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dashcam-native-storage-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target"), rejected = root.appendingPathComponent("occupied")
        defer {
            UserDefaults.standard.removeObject(forKey: StorageLocation.preferenceKey)
            try? FileManager.default.removeItem(at: root)
        }
        setenv("JEV_APP_DATA_DIR", source.path, 1)
        let store = NoteStore()
        store.start()
        try await waitForService(store)
        let imported = await store.mutate("api/import", body: ["title": "Fixture", "text": "Saved text", "app": "Storage test"])
        precondition(imported)
        let preferencesSaved = await store.mutate("api/capture-preferences", body: ["windowReturnSeconds": 120, "pendingRetentionHours": 24])
        precondition(preferencesSaved)
        let ids = store.records.map(\.id)
        precondition(ids.count == 1)
        try FileManager.default.createDirectory(at: rejected, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: rejected.appendingPathComponent("keep.txt"))
        await store.moveStorage(to: rejected)
        guard store.ready && store.directory.path == source.path && store.storageError != nil else {
            throw AppError(message: "rejection state: ready=\(store.ready), source=\(source.path), actual=\(store.directory.path), error=\(store.storageError ?? "none"), startup=\(store.startupError ?? "none")")
        }
        await store.moveStorage(to: target)
        precondition(store.ready && store.storageError == nil)
        precondition(store.directory.path == target.resolvingSymlinksInPath().standardizedFileURL.path)
        precondition(store.records.map(\.id) == ids && store.capturePreferences.pendingRetentionHours == 24)
        precondition(FileManager.default.fileExists(atPath: source.appendingPathComponent("jev.sqlite").path))
        precondition(!store.status.running)
        try await store.stopAndWait()
        unsetenv("JEV_APP_DATA_DIR")
        let reopened = NoteStore()
        precondition(reopened.directory.path == store.directory.path)
        reopened.start(); try await waitForService(reopened); await reopened.refresh()
        precondition(reopened.records.map(\.id) == ids)
        try await reopened.stopAndWait()
        // A disconnected custom location must not be replaced with an empty DB.
        let offline = root.appendingPathComponent("offline")
        try FileManager.default.moveItem(at: target, to: offline)
        let disconnected = NoteStore()
        disconnected.start()
        for _ in 0..<50 {
            if disconnected.startupError != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(disconnected.startupError != nil && !disconnected.ready)
        precondition(!FileManager.default.fileExists(atPath: target.path))
        try FileManager.default.moveItem(at: offline, to: target)
        disconnected.start(); try await waitForService(disconnected)
        try await disconnected.stopAndWait()
        print("Passed: native relocation, occupied destination rejection, saved location after restart, full record preservation, capture paused, and missing-drive recovery.")
    }
}
