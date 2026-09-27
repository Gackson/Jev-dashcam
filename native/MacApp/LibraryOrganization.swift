import Foundation

enum LibraryGrouping: String, CaseIterable, Identifiable {
    case none = "不分组", app = "按来源 App", day = "按日期", hour = "按小时"
    var id: String { rawValue }
}
enum LibraryDateRange: String, CaseIterable, Identifiable {
    case all = "全部时间", today = "今天", week = "最近 7 天", month = "最近 30 天", custom = "自定义日期"
    var id: String { rawValue }
}
struct LibrarySection: Identifiable {
    let id: String
    let title: String
    let notes: [Note]
}
struct LibraryOrganization {
    var grouping: LibraryGrouping = .none
    var source: String? = nil
    var dateRange: LibraryDateRange = .all
    var startDate = Date()
    var endDate = Date()
    var activeCount: Int { (source == nil ? 0 : 1) + (dateRange == .all ? 0 : 1) }
    var summary: String { [source, dateRange == .all ? nil : dateRange.rawValue].compactMap { $0 }.joined(separator: " · ") }

    func matches(_ note: Note, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard source == nil || source == note.app else { return false }
        guard dateRange != .all else { return true }
        guard let date = note.captureDate else { return false }
        let today = calendar.startOfDay(for: now)
        let start: Date
        let end: Date
        if dateRange == .custom {
            start = calendar.startOfDay(for: min(startDate, endDate))
            end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(startDate, endDate)))!
        } else {
            let days = dateRange == .week ? 6 : dateRange == .month ? 29 : 0
            start = calendar.date(byAdding: .day, value: -days, to: today)!
            end = calendar.date(byAdding: .day, value: 1, to: today)!
        }
        return date >= start && date < end
    }

    func projectSections(_ projects: [NoteProject], calendar: Calendar = .current) -> [ProjectSection] {
        let byCover = Dictionary(uniqueKeysWithValues: projects.map { ($0.cover.id, $0) })
        return sections(projects.map(\.cover), calendar: calendar).map { section in
            ProjectSection(id: section.id, title: section.title, projects: section.notes.compactMap { byCover[$0.id] })
        }
    }

    func sections(_ notes: [Note], calendar: Calendar = .current) -> [LibrarySection] {
        if grouping == .none { return [LibrarySection(id: "all", title: "", notes: notes)] }
        if grouping == .app {
            return Dictionary(grouping: notes, by: \.app).sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
                .map { LibrarySection(id: "app:\($0.key)", title: $0.key, notes: $0.value) }
        }
        let grouped = Dictionary(grouping: notes) { note in
            note.captureDate.map {
                grouping == .hour ? (calendar.dateInterval(of: .hour, for: $0)?.start ?? $0) : calendar.startOfDay(for: $0)
            } ?? .distantPast
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = grouping == .hour ? "yyyy年M月d日 HH:mm" : "yyyy年M月d日"
        return grouped.sorted { $0.key > $1.key }.map {
            LibrarySection(id: "\(grouping == .hour ? "hour" : "day"):\($0.key.timeIntervalSince1970)", title: $0.key == .distantPast ? "日期未知" : formatter.string(from: $0.key), notes: $0.value)
        }
    }
}

extension Note {
    var captureDate: Date? {
        let raw = frames.first?.time ?? updated
        return NoteDateCache.date(raw)
    }
}

// Small, bounded caches avoid repeated Foundation date parsing in every body pass.
enum NoteDateCache {
    private static let dates = NSCache<NSString, NSDate>()
    private static let labels = NSCache<NSString, NSString>()
    static func date(_ raw: String) -> Date? {
        if let date = dates.object(forKey: raw as NSString) { return date as Date }
        guard let value = ISO8601DateFormatter.jev.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) else { return nil }
        dates.countLimit = 4096
        dates.setObject(value as NSDate, forKey: raw as NSString)
        return value
    }
    static func label(_ raw: String) -> String {
        let key = "\(raw):\(TimeZone.current.identifier):\(Locale.current.identifier)" as NSString
        if let label = labels.object(forKey: key) { return label as String }
        guard let date = date(raw) else { return raw }
        let label = date.formatted(date: .abbreviated, time: .shortened)
        labels.countLimit = 4096
        labels.setObject(label as NSString, forKey: key)
        return label
    }
}

// A project is one browsing session. Its constituent records remain independent
// for classification, corrections, deletion, filtering and agent exports.
struct NoteProject: Identifiable {
    let id: String
    let notes: [Note]
    var cover: Note { notes[0] }
    var frameCount: Int { notes.reduce(0) { $0 + $1.frames.count } }
    var labels: Set<String> { Set(notes.flatMap(\.labels)) }
    static func collect(_ notes: [Note]) -> [NoteProject] {
        var order: [String] = []
        var members: [String: [Note]] = [:]
        for note in notes {
            let key = note.kind == "capture" ? note.session_id.map { "session:" + $0 } ?? note.id : note.id
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(note)
        }
        return order.map { NoteProject(id: $0, notes: members[$0]!) }
    }
}
struct ProjectSection: Identifiable {
    let id: String
    let title: String
    let projects: [NoteProject]
}
