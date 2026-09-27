import Foundation

@main struct ExclusionTests {
    static func main() throws {
        let rule = WindowExclusion(id: "one", app: "Browser", bundleID: "test.browser", title: "Private", match: "exact")
        precondition(rule.matches(app: "Browser", bundleID: "test.browser", title: "Private"))
        precondition(!rule.matches(app: "Browser", bundleID: "test.browser", title: "Public"))
        precondition(!rule.matches(app: "Browser", bundleID: "another.browser", title: "Private"))
        precondition(!rule.matches(app: "Browser", bundleID: "test.browser", title: "Private 2"))
        let keyword = WindowExclusion(id: "two", app: "Browser", bundleID: "", title: "Private", match: "contains")
        precondition(keyword.matches(app: "Browser", bundleID: "test.browser", title: "Private 2"))
        precondition(!keyword.matches(app: "Other", bundleID: "test.browser", title: "Private 2"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode([rule]).write(to: file, options: .atomic)
        let loaded = try WindowExclusion.load(path: file.path)
        precondition(loaded == [rule])
        try Data("invalid".utf8).write(to: file, options: .atomic)
        do { _ = try WindowExclusion.load(path: file.path); fatalError("Invalid rules must block capture") } catch {}
        print("Native window exclusion matching and fail-closed loading passed")
    }
}
