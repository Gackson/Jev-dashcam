import SwiftUI

struct WindowExclusionSettings: View {
    @EnvironmentObject var store: NoteStore
    @State private var adding = false
    var body: some View {
        Section("排除特定窗口") {
            Text("这些窗口前置时，不截图、不识别文字、不记录。切换到其他窗口后自动继续。")
                .font(.caption).foregroundStyle(.secondary)
            if store.windowExclusions.isEmpty {
                Text("尚未添加排除窗口").foregroundStyle(.secondary)
            }
            ForEach(store.windowExclusions) { rule in
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(rule.app).fontWeight(.medium)
                        Text("\(rule.match == "contains" ? "标题包含" : "标题完全匹配")：\(rule.title)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button("移除") {
                        Task { await store.saveWindowExclusions(store.windowExclusions.filter { $0.id != rule.id }) }
                    }.disabled(store.busy)
                }
            }
            Button("添加排除窗口…", systemImage: "plus") { adding = true }.disabled(!store.ready || store.busy)
        }
        .sheet(isPresented: $adding) { WindowExclusionEditor().environmentObject(store) }
    }
}

struct WindowExclusionEditor: View {
    @EnvironmentObject var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var windows: [AvailableWindow] = []
    @State private var selected = ""
    @State private var app = ""
    @State private var bundleID = ""
    @State private var title = ""
    @State private var match = "exact"
    @State private var loading = false
    @State private var message: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("添加排除窗口").font(.title2.bold())
            Text("选择已打开的窗口，或手动填写来源 App 和窗口标题。规则会在保存后立即生效。")
                .foregroundStyle(.secondary)
            HStack {
                Picker("当前窗口", selection: $selected) {
                    Text("手动填写").tag("")
                    ForEach(windows) { window in
                        Text("\(window.app) · \(window.title)").lineLimit(1).tag(window.id)
                    }
                }
                Button("刷新") { Task { await reload() } }.disabled(loading)
            }
            .onChange(of: selected) { _, value in
                if let window = windows.first(where: { $0.id == value }) {
                    app = window.app; bundleID = window.bundleID; title = window.title
                } else { app = ""; bundleID = ""; title = "" }
            }
            TextField("来源 App", text: $app, prompt: Text("例如 Safari"))
                .disabled(!selected.isEmpty)
            TextField("窗口标题", text: $title, prompt: Text("输入需要排除的标题"))
            Picker("匹配方式", selection: $match) {
                Text("标题完全匹配").tag("exact")
                Text("标题包含关键词").tag("contains")
            }.pickerStyle(.segmented)
            Text(match == "exact" ? "仅排除此 App 下标题完全相同的窗口。标题变化后将恢复记录。" : "排除此 App 下标题包含上述关键词的窗口，区分大小写。")
                .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存排除规则") {
                    Task {
                        let rule = WindowExclusion(id: UUID().uuidString, app: app.trimmingCharacters(in: .whitespacesAndNewlines), bundleID: bundleID, title: title, match: match)
                        if await store.saveWindowExclusions(store.windowExclusions + [rule]) { dismiss() }
                        else { message = store.error ?? "保存失败，请重试" }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(store.busy || app.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 550).tint(gardenGreen)
            .task { await reload() }
    }
    private func reload() async {
        loading = true; defer { loading = false }
        do { windows = try await store.availableWindows(); message = nil }
        catch { message = error.localizedDescription }
    }
}
