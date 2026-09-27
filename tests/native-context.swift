import Foundation

@main
struct TopicContextTests {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("jev-context-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let topic = Topic(id: "t_test", name: "研究话题", description: "关注目标", color: "sage")
        func note(_ id: String, labels: [String], manual: [String: Bool] = [:], app: String = "测试来源", date: String = "2026-09-27T01:00:00.000Z") -> Note {
            Note(id: id, title: "资料 \(id)", app: app, url: "https://example.com", text: "识别文字",
                 frames: [Frame(image: "abcd-1234.jpg", time: date, text: "逐帧文字")],
                 scores: [topic.id: 0.95], manual: manual, labels: labels, status: "classified", error: nil,
                 model: "jev-latest", updated: "2026-09-27T01:00:00.000Z", kind: "capture")
        }
        let store = NoteStore()
        store.topics = [topic]
        store.records = [note("included", labels: [topic.id]), note("manually-excluded", labels: [], manual: [topic.id: false]), note("unrelated", labels: ["t_other"])]
        store.filter = topic.id
        store.search = "search-hides-everything"
        precondition(store.filtered.isEmpty)
        let context = TopicAgentContext(topic: topic, records: store.records, directory: root)
        precondition(context.records.map(\.id) == ["included"], "Exports the full topic using effective labels, independently of search")
        let path = try context.write(to: root.appendingPathComponent("agent-context"))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        let records = object["records"] as! [[String: Any]]
        precondition(records.count == 1 && records[0]["text"] as? String == "识别文字")
        precondition((records[0]["frames"] as! [[String: Any]])[0]["image"] as? String == "abcd-1234.jpg")
        precondition(object["screenshotsDirectory"] as? String == root.appendingPathComponent("screenshots").path)
        let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as! NSNumber
        precondition(permissions.intValue == 0o600)
        precondition(context.prompt(file: path).contains(path.path))
        precondition(context.prompt(file: path).contains("全部 1 份资料"))
        precondition(context.prompt(file: path).contains("不读取密钥配置"))
        let empty = TopicAgentContext(topic: topic, records: [], directory: root)
        _ = try empty.write(to: root.appendingPathComponent("agent-context"))
        let updated = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        precondition((updated["records"] as! [Any]).isEmpty, "Copy again refreshes the snapshot without stale records")
        let invalid = Topic(id: "../outside", name: "Invalid", description: "", color: "sage")
        do {
            _ = try TopicAgentContext(topic: invalid, records: [], directory: root).write(to: root)
            fatalError("Unsafe topic path must be rejected")
        } catch {}
        var groupedA = note("session-a", labels: [topic.id])
        var groupedB = note("session-b", labels: ["other-topic"])
        groupedA.session_id = "window-visit"
        groupedB.session_id = "window-visit"
        let sessionOptions = LibraryOrganization()
        let projects = NoteProject.collect([groupedA, groupedB, note("legacy", labels: [])])
        precondition(projects.count == 2 && projects[0].notes.count == 2 && projects[0].frameCount == 2)
        precondition(sessionOptions.sections([groupedA, groupedB]).count == 1, "Default layout has no presentation grouping")
        precondition(sessionOptions.projectSections(projects)[0].projects.count == 2, "A session occupies one card, not a section of cards")
        var newCapture = note("latest", labels: [topic.id])
        newCapture.session_id = "window-visit"
        precondition(NoteProject.collect([newCapture, groupedA, groupedB])[0].id == projects[0].id, "Project selection survives a changing cover")
        precondition(NoteProject.collect([note("legacy1", labels: []), note("legacy2", labels: [])]).count == 2, "Same titles/apps without window identity remain separate")
        for grouping in LibraryGrouping.allCases {
            var organization = LibraryOrganization(); organization.grouping = grouping
            let arranged = organization.projectSections(projects).flatMap(\.projects)
            precondition(arranged.count == 2 && arranged.first { $0.id == projects[0].id }?.notes.count == 2, "Presentation grouping must not split projects")
        }
        store.search = ""; store.records = [groupedA, groupedB]
        precondition(store.projects.first?.notes.map(\.id) == ["session-a"], "Projects never bring other-topic screenshots into a topic")
        store.selection = store.projects[0].id
        precondition(store.selected?.notes.count == 1)
        store.records = [newCapture, groupedA, groupedB]
        precondition(store.selected?.notes.count == 2 && store.selected?.id == projects[0].id)
        precondition(TopicAgentContext(topic: topic, records: store.records, directory: root).records.count == 2)
        print("Passed: one session per project card, stable selection, independent topics/exports, outer presentation groups and legacy isolation.")
        var options = LibraryOrganization()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let now = ISO8601DateFormatter.jev.date(from: "2026-09-27T04:00:00.000Z")!
        let today = note("today", labels: [topic.id], app: "Safari", date: "2026-09-26T16:00:00.000Z")
        let yesterday = note("yesterday", labels: [topic.id], app: "Chrome", date: "2026-09-26T15:59:59.999Z")
        let weekStart = note("week", labels: [], app: "Safari", date: "2026-09-20T16:00:00.000Z")
        let beforeWeek = note("old", labels: [], app: "Safari", date: "2026-09-20T15:59:59.999Z")
        options.dateRange = .today
        precondition(options.matches(today, now: now, calendar: calendar))
        precondition(!options.matches(yesterday, now: now, calendar: calendar), "Uses local midnight, not UTC or last 24 hours")
        options.dateRange = .week
        precondition(options.matches(weekStart, now: now, calendar: calendar))
        precondition(!options.matches(beforeWeek, now: now, calendar: calendar))
        options.source = "Safari"
        precondition(!options.matches(yesterday, now: now, calendar: calendar), "Source and date combine with AND")
        options.dateRange = .custom
        options.startDate = now
        options.endDate = calendar.date(byAdding: .day, value: -1, to: now)!
        options.source = nil
        precondition(options.matches(today, calendar: calendar) && options.matches(yesterday, calendar: calendar), "Custom bounds include both days and tolerate reversed dates")
        options.grouping = .app
        let samples = [today, yesterday, weekStart, beforeWeek]
        let appGroups = options.sections(samples, calendar: calendar)
        precondition(appGroups.count == 2 && appGroups.first?.title == "Chrome")
        precondition(Set(appGroups.flatMap(\.notes).map(\.id)) == Set(samples.map(\.id)), "Grouping preserves every individual record without combining classifications")
        options.grouping = .day
        let dayGroups = options.sections(samples, calendar: calendar)
        precondition(dayGroups.count == 4 && dayGroups.first?.notes.first?.id == "today")
        options.grouping = .hour
        let hourEnd = note("hour-end", labels: [], date: "2026-09-26T16:59:59.999Z")
        let nextHour = note("next-hour", labels: [], date: "2026-09-26T17:00:00.000Z")
        let nextDay = note("next-day", labels: [], date: "2026-09-27T16:00:00.000Z")
        let hourGroups = options.sections([today, hourEnd, nextHour, nextDay], calendar: calendar)
        precondition(hourGroups.count == 3, "Hours on different days must not combine")
        precondition(hourGroups.map(\.title) == ["2026年9月28日 00:00", "2026年9月27日 01:00", "2026年9月27日 00:00"], "Hour labels and order use local time")
        precondition(hourGroups.last?.notes.map(\.id) == ["today", "hour-end"], "Both ends of the same hour share a display group while records remain independent")
        store.search = ""
        store.organization.source = "nonexistent"
        precondition(store.filtered.isEmpty && store.scopedRecords.count == 2)
        precondition(TopicAgentContext(topic: topic, records: store.records, directory: root).records.count == 2, "Display filters never narrow the full topic context")
        print("Passed: source/date filter intersections, local day/week/hour boundaries, custom inclusive dates, app/day/hour groups preserve records, and filters do not affect topic context.")
        print("Passed: topic scope, manual exclusion, search independence, screenshot references, private file permissions, refreshed and empty snapshots, prompt paths, and path validation.")
    }
}
