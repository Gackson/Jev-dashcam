import SwiftUI

struct ProjectActions: ViewModifier {
    @EnvironmentObject var store: NoteStore
    let project: NoteProject
    @State private var deletingIDs: [String] = []
    @State private var confirmDelete = false
    private var members: [Note] { store.members(of: project) }
    private var isGroup: Bool { members.count > 1 }

    func body(content: Content) -> some View {
        content.contextMenu {
            if isGroup {
                Text("整组操作 · \(members.count) 份资料").font(.caption)
            }
            Menu("归类话题") {
                if store.topics.isEmpty { Text("请先在侧栏添加话题") }
                ForEach(store.topics) { topic in
                    let count = members.filter { $0.labels.contains(topic.id) }.count
                    let all = !members.isEmpty && count == members.count
                    Button {
                        let ids = members.map(\.id)
                        Task { await store.mutate("api/records/batch", body: ["action": "classify", "ids": ids, "topicId": topic.id, "matched": !all]) }
                    } label: {
                        Label(topic.name + (count > 0 && !all ? "（部分）" : ""), systemImage: all ? "checkmark" : count > 0 ? "minus" : "number")
                    }.disabled(store.busy || !store.ready || members.isEmpty)
                }
            }
            if members.contains(where: { $0.status == "error" }) {
                Button("重试此项目的失败归类") {
                    Task { await store.retryFailed(ids: members.filter { $0.status == "error" }.map(\.id)) }
                }.disabled(store.busy || !store.ready)
            }
            Divider()
            Button(isGroup ? "删除资料组…" : "删除资料…", role: .destructive) {
                deletingIDs = members.map(\.id)
                confirmDelete = true
            }.disabled(store.busy || !store.ready || members.isEmpty)
        }
        .confirmationDialog(deletingIDs.count > 1 ? "删除整组 \(deletingIDs.count) 份资料及其截图？包含当前筛选下隐藏的组内资料，此操作无法撤销。" : "删除这份资料及其截图？此操作无法撤销。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(deletingIDs.count > 1 ? "删除整组" : "删除资料", role: .destructive) {
                let ids = deletingIDs
                Task { await store.mutate("api/records/batch", body: ["action": "delete", "ids": ids]) }
            }
            Button("取消", role: .cancel) {}
        }
    }
}
