import SwiftUI

struct ProjectDetail: View {
    let project: NoteProject
    @State private var selectedID: String?
    private var current: Note { project.notes.first { $0.id == selectedID } ?? project.cover }
    private var index: Int { project.notes.firstIndex { $0.id == current.id } ?? 0 }
    var body: some View {
        VStack(spacing: 0) {
            if project.notes.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("本项目 · \(project.frameCount) 张截图", systemImage: "photo.on.rectangle")
                            .help("下方详情、话题调整和删除仅针对当前截图。")
                        Spacer()
                        Button { selectedID = project.notes[index - 1].id } label: { Image(systemName: "chevron.left") }
                            .disabled(index == 0).accessibilityLabel("上一张截图")
                        Text("\(index + 1) / \(project.notes.count)").monospacedDigit()
                        Button { selectedID = project.notes[index + 1].id } label: { Image(systemName: "chevron.right") }
                            .disabled(index + 1 == project.notes.count).accessibilityLabel("下一张截图")
                    }.font(.caption).buttonStyle(.borderless)
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 10) {
                                ForEach(project.notes) { note in
                                    Button { selectedID = note.id } label: {
                                        VStack(spacing: 2) {
                                            if let frame = note.frames.first {
                                                ScreenshotView(frame: frame, maxPixelSize: 240)
                                                    .frame(width: 80, height: 46).clipped()
                                            } else { Image(systemName: "doc.text").frame(width: 80, height: 46) }
                                            Text(note.dateLabel).font(.caption2).lineLimit(1).frame(width: 80)
                                        }.padding(3)
                                            .background(current.id == note.id ? gardenGreen.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(current.id == note.id ? gardenGreen : .clear))
                                    }.buttonStyle(.plain).id(note.id).accessibilityLabel("查看组内截图：\(note.title)，\(note.dateLabel)")
                                }
                            }
                        }.onChange(of: selectedID) { _, id in
                            if let id { proxy.scrollTo(id) }
                        }
                    }
                    // A horizontal ScrollView otherwise accepts all available height
                    // and competes with the main detail ScrollView below it.
                    .frame(height: 70)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .fixedSize(horizontal: false, vertical: true)
                Divider()
            }
            NoteDetail(note: current, isProjectMember: project.notes.count > 1).id(current.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selectedID == nil { selectedID = project.cover.id } }
        .onChange(of: project.notes.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = ids.first }
        }
    }
}
