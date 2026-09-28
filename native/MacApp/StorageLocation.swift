import AppKit
import SwiftUI

enum StorageLocation {
    static let preferenceKey = "libraryStoragePath"
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dashcam", isDirectory: true)
    }
    static var legacyDirectory: URL {
        defaultDirectory.deletingLastPathComponent().appendingPathComponent("Jev Note", isDirectory: true)
    }
    static func transfer(from source: URL, to destination: URL, validateOnly: Bool = false) async throws {
        guard let resources = Bundle.main.resourceURL else { throw AppError(message: "应用资源不完整。") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let child = Process(), output = Pipe()
            child.executableURL = resources.appendingPathComponent("runtime/node")
            child.arguments = [resources.appendingPathComponent("service/storage-migration.mjs").path, source.path, destination.path] + (validateOnly ? ["--validate"] : [])
            child.standardOutput = output
            child.standardError = FileHandle.nullDevice
            child.terminationHandler = { process in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if process.terminationStatus == 0, result?[validateOnly ? "to" : "directory"] as? String != nil { continuation.resume() }
                else { continuation.resume(throwing: AppError(message: result?["error"] as? String ?? "迁移未完成，原位置的资料仍保留。")) }
            }
            do { try child.run() }
            catch { continuation.resume(throwing: error) }
        }
    }
}

struct StorageSettings: View {
    @EnvironmentObject var store: NoteStore
    var body: some View {
        Section("本地存储") {
            Text(store.directory.path).font(.callout).textSelection(.enabled)
            HStack {
                Button("更改存储位置…") { store.chooseStorageLocation() }
                    .disabled(store.busy || store.starting || store.migratingStorage)
                Button("在 Finder 中查看") { store.openData() }.disabled(store.migratingStorage)
            }
            Text("选择或新建一个空文件夹。已有资料、截图和设置会一并迁移；期间暂停录制，完成后可手动继续。原文件夹保留为迁移时的备份，后续资料仅写入新位置。")
                .font(.caption).foregroundStyle(.secondary)
            if store.migratingStorage {
                HStack { ProgressView().controlSize(.small); Text("正在迁移并校验资料，请稍候…") }.font(.callout)
            }
            if let message = store.storageMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let error = store.storageError { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}
