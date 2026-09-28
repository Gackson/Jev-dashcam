import SwiftUI

struct TopicEditor: View {
    @EnvironmentObject var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    let topic: Topic
    @State private var name = ""
    @State private var description = ""
    @FocusState private var focused: Bool
    private var valid: Bool {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return !title.isEmpty && title.count <= 60 && description.count <= 1000
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("编辑话题").font(.title2.weight(.semibold))
            Text("已有资料的分类保持不变，新增资料按修改后的话题信息分类。")
                .font(.callout).foregroundStyle(.secondary)
            TextField("话题标题", text: $name).textFieldStyle(.roundedBorder).focused($focused)
            HStack {
                Text("简介").font(.headline)
                Spacer()
                Text("\(description.count) / 1000").font(.caption).foregroundStyle(description.count > 1000 ? .red : .secondary)
            }
            TextEditor(text: $description).font(.body).padding(6).frame(height: 150)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityLabel("话题简介")
            if let error = store.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存修改") {
                    Task {
                        if await store.mutate("api/topics/\(topic.id)", method: "PATCH", body: ["name": name, "description": description]) { dismiss() }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!valid || store.busy || !store.ready)
            }
        }.padding(24).frame(width: 500).tint(gardenGreen)
            .onAppear { name = topic.name; description = topic.description; store.error = nil; focused = true }
    }
}
