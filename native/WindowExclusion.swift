import Foundation

struct WindowExclusion: Codable, Identifiable, Equatable {
    let id: String
    let app: String
    let bundleID: String
    let title: String
    let match: String

    func matches(app candidateApp: String, bundleID candidateBundle: String, title candidateTitle: String) -> Bool {
        let sameApp = bundleID.isEmpty ? app == candidateApp : bundleID == candidateBundle
        guard sameApp, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return match == "contains" ? candidateTitle.contains(title) : candidateTitle == title
    }

    static func load(path: String?) throws -> [WindowExclusion] {
        guard let path else { return [] }
        // An unreadable rules file must stop capture, not silently disable exclusions.
        return try JSONDecoder().decode([WindowExclusion].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
}

struct AvailableWindow: Decodable, Identifiable {
    let id: String
    let app: String
    let bundleID: String
    let title: String
}
