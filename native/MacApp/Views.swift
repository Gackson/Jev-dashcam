import SwiftUI
import AppKit

let gardenGreen = Color(red: 0.28, green: 0.43, blue: 0.34)

struct LibraryView: View {
    @EnvironmentObject var store: NoteStore
    @State private var editingTopic: Topic?
    @State private var showingTopicDescription = false
    @State private var deletingTopic: Topic?
    @State private var copiedTopicID: String?
    @State private var collapsedGroups: Set<String> = []
    var body: some View {
        NavigationSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    sidebarRow("全部资料", id: "all", symbol: "tray.full", count: store.records.count)
                    sidebarRow("待整理", id: "unmatched", symbol: "tray", count: store.records.filter { $0.labels.isEmpty }.count)
                    sidebarRow("归类失败", id: "errors", symbol: "exclamationmark.circle", count: store.records.filter { $0.status == "error" }.count)
                        .contextMenu {
                            Button("重试全部失败归类") { Task { await store.retryFailed() } }
                                .disabled(store.busy || !store.ready || !store.records.contains { $0.status == "error" })
                        }
                    Text("关注的话题").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.top, 20).padding(.bottom, 4)
                    ForEach(store.topics) { topic in
                        sidebarRow(topic.name, id: topic.id, symbol: "number", count: store.records.filter { $0.labels.contains(topic.id) }.count, tint: topic.tint)
                            .contextMenu {
                                Button("编辑话题…") { editingTopic = topic }
                                Button("移除话题…", role: .destructive) { deletingTopic = topic }
                            }
                    }
                    Button { store.sheet = .topic } label: { Label("添加话题", systemImage: "plus") }
                        .buttonStyle(.plain).foregroundStyle(gardenGreen).padding(12)
                        .disabled(!store.ready || store.busy)
                }.padding(10)
            }
            .onMoveCommand { direction in
                let ids = ["all", "unmatched", "errors"] + store.topics.map(\.id)
                guard let index = ids.firstIndex(of: store.filter ?? "all") else { return }
                if direction == .down { store.filter = ids[min(index + 1, ids.count - 1)] }
                if direction == .up { store.filter = ids[max(index - 1, 0)] }
            }
            .navigationTitle("Dashcam")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
            .safeAreaInset(edge: .bottom) { collector.padding(16) }
        } detail: {
            GeometryReader { geometry in
            VStack(spacing: 0) {
                topicHeader
                LibraryControls()
                Divider()
                    PersistentDetailSplit(isPresented: store.selected != nil) {
                        libraryGrid
                    } detail: {
                        if let note = store.selected {
                        VStack(spacing: 0) {
                            HStack {
                                Text("资料详情").font(.callout).foregroundStyle(.secondary)
                                Spacer()
                                Button { store.selection = nil } label: {
                                    Image(systemName: "xmark")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("关闭详情")
                                .help("关闭详情，返回瀑布流（Esc）")
                                .keyboardShortcut(.cancelAction)
                            }.padding(.horizontal, 20).padding(.vertical, 12)
                            Divider()
                            ProjectDetail(project: note).id(note.id)
                        }.frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
            .searchable(text: $store.search, prompt: "搜索标题、文字或来源")
        }
        .navigationSplitViewStyle(.balanced)
        .tint(gardenGreen)
        .frame(minWidth: 980, minHeight: 640)
        .toolbar {
            ToolbarItemGroup {
                Button { store.toggleCapture() } label: {
                    Label(store.status.running ? "Pause Recording" : "Start Recording", systemImage: store.status.running ? "pause.fill" : "record.circle")
                        .labelStyle(.titleAndIcon)
                }.disabled(!store.ready || store.busy)
                Menu {
                    Button("手动录入…") { store.sheet = .note }
                    Button("体验示例资料") { Task { await store.loadDemo() } }.disabled(store.busy || !store.ready)
                    Divider()
                    Button("导出资料…") { store.export() }
                    Button("在 Finder 中查看数据") { store.openData() }
                    SettingsLink { Text("设置…") }
                } label: { Label("更多操作", systemImage: "ellipsis.circle") }
            }
        }
        .overlay {
            if !store.ready {
                VStack(spacing: 18) {
                    Image(systemName: "leaf.fill").font(.system(size: 36)).foregroundStyle(gardenGreen)
                    Text("Dashcam").font(.title.weight(.semibold))
                    if let failure = store.startupError {
                        Text(failure).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                        Button("重新启动") { store.start() }.buttonStyle(.borderedProminent)
                    } else { ProgressView(store.migratingStorage ? "正在迁移并校验资料…" : "正在打开你的知识花园…") }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(.regularMaterial)
            }
        }
        .sheet(item: $editingTopic) { topic in TopicEditor(topic: topic).environmentObject(store) }
        .sheet(item: $store.sheet) { sheet in EditorView(kind: sheet).environmentObject(store) }
        .sheet(item: $store.previewFrame) { frame in ScreenshotPreview(frame: frame).environmentObject(store) }
        .alert("操作未完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("好") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .alert("Dashcam", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("好") { store.notice = nil }
        } message: { Text(store.notice ?? "") }
        .confirmationDialog("移除「\(deletingTopic?.name ?? "")」？资料仍会保留。", isPresented: Binding(get: { deletingTopic != nil }, set: { if !$0 { deletingTopic = nil } })) {
            Button("移除话题", role: .destructive) {
                if let topic = deletingTopic { Task {
                    if await store.mutate("api/topics/\(topic.id)", method: "DELETE"), store.filter == topic.id { store.filter = "all" }
                } }
                deletingTopic = nil
            }
        }
        .task { store.start() }
        .onChange(of: store.filter) { _, _ in
            store.selection = nil
            copiedTopicID = nil
            showingTopicDescription = false
        }
        .onChange(of: store.organization.grouping) { _, _ in collapsedGroups.removeAll() }
        .onChange(of: store.projects.map(\.id)) { _, ids in
            if let selected = store.selection, !ids.contains(selected) { store.selection = nil }
        }
    }
    var topicHeader: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                if let topic = store.selectedTopic {
                    Button { showingTopicDescription.toggle() } label: {
                        HStack(spacing: 6) {
                            Text(topic.name).font(.title2.weight(.semibold)).lineLimit(2)
                            Image(systemName: "info.circle").font(.callout).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain).help("查看话题简介").accessibilityLabel("查看话题简介：\(topic.name)")
                        .popover(isPresented: $showingTopicDescription) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(topic.name).font(.headline).textSelection(.enabled)
                                ScrollView {
                                    Text(topic.description.isEmpty ? "尚未填写简介" : topic.description)
                                        .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                }.frame(maxHeight: 220)
                                HStack {
                                    Spacer()
                                    Button("编辑话题…") { showingTopicDescription = false; editingTopic = topic }
                                }
                            }.padding(20).frame(width: 360)
                        }
                } else {
                    Text(store.heading).font(.title2.weight(.semibold))
                }
                Text("\(store.projects.count) 个项目 · \(store.filtered.count) 份资料" + (hasFilters ? " / 共 \(store.scopedRecords.count) 份" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let topic = store.selectedTopic {
                Button {
                    if store.copyTopicPrompt(topic) { copiedTopicID = topic.id }
                } label: {
                    Label("copy prompt", systemImage: copiedTopicID == topic.id ? "checkmark" : "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("copy prompt")
                .help("复制本主题完整 context 的读取 Prompt")
                .popover(isPresented: Binding(get: { copiedTopicID == topic.id }, set: { if !$0 { copiedTopicID = nil } })) {
                    VStack(alignment: .leading, spacing: 7) {
                        Label("Prompt 已复制", systemImage: "checkmark.circle.fill").font(.headline)
                        Text("可粘贴给其他 Agent，以获取本主题完整 context。")
                        Text("Agent 需能读取本机文件；远程使用时请一并提供资料快照和截图。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(16).frame(width: 340, alignment: .leading)
                    .task { try? await Task.sleep(for: .seconds(4)); copiedTopicID = nil }
                }
            }
            if store.filter == "errors" {
                Button("重试全部失败归类", systemImage: "arrow.clockwise") { Task { await store.retryFailed() } }
                    .disabled(store.busy || !store.ready || !store.records.contains { $0.status == "error" })
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    var hasFilters: Bool { !store.search.isEmpty || store.organization.activeCount > 0 }

    var libraryGrid: some View {
        GeometryReader { gridGeometry in
        Group {
            if store.filtered.isEmpty {
                VStack {
                    VStack(spacing: 14) {
                        Image(systemName: !hasFilters ? "leaf" : "magnifyingglass")
                            .font(.system(size: 38, weight: .light)).foregroundStyle(.tertiary)
                        Text(hasFilters ? "没有符合条件的资料" : store.filter == "errors" ? "没有归类失败的资料" : store.selectedTopic != nil ? "这个话题还没有资料" : "让看过的，成为你的。")
                            .font(.title2.weight(.semibold))
                        Text(hasFilters ? "试试其他来源、日期或关键词。" : store.filter == "errors" ? "后续归类失败的资料会出现在这里。" : store.selectedTopic != nil ? "开始记录或手动录入，相关资料会自动归入本话题。" : "手动录入一段文字，或查看示例了解自动归类。")
                            .foregroundStyle(.secondary)
                        if hasFilters {
                            Button("清除筛选与搜索") {
                                store.organization.source = nil
                                store.organization.dateRange = .all
                                store.search = ""
                            }
                        } else if store.filter != "errors" {
                            HStack {
                                Button("手动录入") { store.sheet = .note }
                                Button("体验示例资料") { Task { await store.loadDemo() } }.disabled(store.busy || !store.ready)
                            }.padding(.top, 4)
                            Text("示例包含 4 份合成文字资料，由 Jev 归类；已有示例会直接打开。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24).padding(.top, 70)
                    .frame(maxWidth: .infinity)
                    Spacer(minLength: 0)
                }
            } else {
                ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(store.organization.projectSections(store.projects)) { section in
                            VStack(alignment: .leading, spacing: 14) {
                                if store.organization.grouping != .none {
                                    Button {
                                        if !collapsedGroups.insert(section.id).inserted { collapsedGroups.remove(section.id) }
                                    } label: {
                                        HStack {
                                            Image(systemName: collapsedGroups.contains(section.id) ? "chevron.right" : "chevron.down")
                                            Text(section.title).font(.headline).lineLimit(2)
                                            Text("\(section.projects.count)").foregroundStyle(.secondary).monospacedDigit()
                                            Spacer()
                                        }.contentShape(Rectangle())
                                    }.buttonStyle(.plain).accessibilityLabel("\(section.title)，\(section.projects.count) 份资料，\(collapsedGroups.contains(section.id) ? "已折叠" : "已展开")")
                                }
                                if !collapsedGroups.contains(section.id) {
                                    LazyWaterfall(items: section.projects, width: max(1, gridGeometry.size.width - 40)) { note in
                                            NoteRow(project: note, topics: store.topics)
                                                .padding(14)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(store.selection == note.id ? gardenGreen.opacity(0.09) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(store.selection == note.id ? gardenGreen : Color.primary.opacity(0.08), lineWidth: store.selection == note.id ? 2 : 1))
                                                .contentShape(RoundedRectangle(cornerRadius: 12))
                                                .onTapGesture { store.selection = store.selection == note.id ? nil : note.id }
                                                .modifier(ProjectActions(project: note))
                                                .id(note.id)
                                    }
                                }
                            }
                        }
                    }.padding(20)
                }
                .id(store.filter ?? "all")
                .task(id: "\(store.selection != nil):\(Int(gridGeometry.size.width)):\(store.organization.grouping.rawValue)") {
                    guard let selected = store.selection,
                          let section = store.organization.projectSections(store.projects).first(where: { $0.projects.contains { $0.id == selected } }) else { return }
                    collapsedGroups.remove(section.id)
                    // Selection identity is intentionally not a task trigger: while
                    // details are open, switching cards must preserve scroll position.
                    // Opening details / relayout still resolves the new column anchor.
                    await Task.yield()
                    guard !Task.isCancelled, store.selection == selected else { return }
                    scrollProxy.scrollTo(selected, anchor: .center)
                }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    func sidebarRow(_ title: String, id: String, symbol: String, count: Int, tint: Color? = nil) -> some View {
        let selected = (store.filter ?? "all") == id
        return Button { store.filter = id } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(selected ? gardenGreen : (tint ?? .primary)).frame(width: 18)
                Text(title).lineLimit(1).fontWeight(selected ? .semibold : .regular)
                Spacer(minLength: 4)
                Text("\(count)").foregroundStyle(selected ? gardenGreen.opacity(0.8) : Color.secondary).monospacedDigit()
            }
            .foregroundStyle(selected ? gardenGreen : .primary)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(selected ? gardenGreen.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title)，\(count) 份资料")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
    var collector: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { store.toggleCapture() } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        Circle().fill(store.status.running ? gardenGreen : Color.secondary).frame(width: 7, height: 7)
                        Text(store.status.running ? "正在留意新内容" : "采集已暂停").font(.callout.weight(.medium))
                        Spacer()
                    }
                    Text(store.status.message).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!store.ready || store.busy)
            .help(store.status.running ? "点击暂停录制" : "点击开始录制")
            .accessibilityLabel(store.status.running ? "暂停录制" : "开始录制")
            .accessibilityValue(store.status.message)
            if let error = store.status.error {
                Text(error).font(.caption).foregroundStyle(.orange)
                Button("打开屏幕录制设置") { store.openPermissions() }.font(.caption)
            }
            if store.status.queue > 0 { ProgressView("\(store.status.queue) 份资料正在归类").controlSize(.small).font(.caption) }
            if !store.status.modelConfigured {
                SettingsLink { Label("配置 TypeSafe API Key", systemImage: "key") }.font(.caption)
            }
            Divider()
            Label("资料保存在此 Mac", systemImage: "internaldrive").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct NoteRow: View {
    @EnvironmentObject var store: NoteStore
    let project: NoteProject
    var note: Note { project.cover }
    let topics: [Topic]
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(note.app, systemImage: note.kind == "capture" ? "macwindow" : "doc.text").lineLimit(1)
                Spacer()
                if note.kind == "demo" { Text("示例") }
                if project.notes.contains(where: { $0.status == "error" }) { Image(systemName: "exclamationmark.circle").foregroundStyle(.orange) }
                if project.notes.contains(where: { ["pending", "processing"].contains($0.status) }) { ProgressView().controlSize(.mini) }
            }.font(.caption).foregroundStyle(.secondary)
            Button { store.selection = store.selection == project.id ? nil : project.id } label: {
                Text(note.title).font(.headline).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(store.selection == project.id ? "取消选中：\(note.title)" : "查看资料详情：\(note.title)")
            if let frame = note.frames.first {
                ZStack(alignment: .bottomTrailing) {
                    Button { store.selection = store.selection == project.id ? nil : project.id } label: {
                        ScreenshotView(frame: frame, maxPixelSize: 640)
                            .frame(maxWidth: .infinity)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityLabel(store.selection == project.id ? "取消选中截图：\(note.title)" : "查看截图详情：\(note.title)").help(store.selection == project.id ? "再次点击取消选中，返回瀑布流" : "点击查看资料详情")
                    Button { store.previewFrame = frame } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.caption)
                            .padding(9).background(.regularMaterial, in: Circle())
                    }
                    .buttonStyle(.plain).padding(8)
                    .accessibilityLabel("放大截图：\(note.title)").help("直接放大截图")
                    if project.frameCount > 1 {
                        VStack {
                            HStack {
                                Label("\(project.frameCount) 张截图", systemImage: "photo.on.rectangle")
                                    .font(.caption).padding(6).background(.regularMaterial, in: Capsule())
                                Spacer()
                            }
                            Spacer()
                        }.padding(8).allowsHitTesting(false)
                    }
                }
            } else {
                Label(note.kind == "capture" ? "暂无截图" : "文字资料 · 点开查看", systemImage: note.kind == "capture" ? "photo" : "doc.text")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 10)
            }
            HStack(spacing: 5) {
                ForEach(topics.filter { project.labels.contains($0.id) }.prefix(2)) { topic in
                    Text(topic.name).font(.caption2).lineLimit(1).padding(.horizontal, 7).padding(.vertical, 3).background(topic.tint.opacity(0.14), in: Capsule())
                }
                Spacer(minLength: 0)
                Text(note.dateLabel).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }.padding(.vertical, 10)
    }
}

struct ScreenshotView: View {
    @EnvironmentObject var store: NoteStore
    let frame: Frame
    let maxPixelSize: Int
    @State private var image: NSImage?
    @State private var finished = false
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().accessibilityLabel("来源截图")
            } else {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04))
                    .aspectRatio(1.6, contentMode: .fit)
                    .overlay {
                        if finished {
                            Label("截图文件不存在", systemImage: "photo.badge.exclamationmark")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "photo").foregroundStyle(.tertiary)
                        }
                    }
            }
        }
        .task(id: "\(store.directory.path):\(frame.image):\(maxPixelSize)") {
            finished = false
            let loaded = await store.screenshot(frame, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return }
            image = loaded; finished = true
        }
    }
}

struct NoteDetail: View {
    @EnvironmentObject var store: NoteStore
    let note: Note
    var isProjectMember = false
    @State private var confirmDelete = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(note.app, systemImage: "doc.text").foregroundStyle(.secondary)
                        Spacer()
                        Text(note.stateLabel).font(.caption).foregroundStyle(note.status == "error" ? .orange : .secondary)
                    }
                    Text(note.title).font(.system(size: 27, weight: .semibold)).textSelection(.enabled)
                    Text(note.dateLabel + (note.kind == "demo" ? " · 合成示例" : "")).font(.caption).foregroundStyle(.secondary)
                    if let url = URL(string: note.url), ["https", "http"].contains(url.scheme ?? "") {
                        Link(destination: url) { Label("打开原始来源", systemImage: "arrow.up.right") }.font(.callout)
                    }
                }
                if !note.frames.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        Text("来源截图 · \(note.frames.count)").font(.headline)
                        ForEach(note.frames) { frame in
                            VStack(alignment: .leading, spacing: 10) {
                                Button { store.previewFrame = frame } label: {
                                    ScreenshotView(frame: frame, maxPixelSize: 1920)
                                        .frame(maxWidth: .infinity)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(alignment: .bottomTrailing) {
                                            Label("放大查看", systemImage: "arrow.up.left.and.arrow.down.right")
                                                .font(.caption).padding(8).background(.regularMaterial, in: Capsule()).padding(10)
                                        }
                                }.buttonStyle(.plain).accessibilityLabel("放大查看截图").help("点击放大查看原始截图")
                                Text(frame.time.replacingOccurrences(of: "T", with: " ").prefix(19))
                                    .font(.caption).foregroundStyle(.secondary)
                                DisclosureGroup("此截图的 OCR 文字") {
                                    Text(frame.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                                }.font(.caption)
                            }
                        }
                    }
                }
                if let error = note.error {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                        Button("重试此资料归类") { Task { await store.retryFailed(ids: [note.id]) } }.disabled(store.busy)
                    }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                }
                if !store.topics.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("相关话题").font(.headline)
                        ForEach(store.topics) { topic in
                            Toggle(isOn: Binding(get: { note.labels.contains(topic.id) }, set: { value in
                                Task { await store.mutate("api/records/\(note.id)", method: "PATCH", body: ["topicId": topic.id, "matched": value]) }
                            })) {
                                HStack {
                                    Text(topic.name)
                                    Spacer()
                                    if note.manual[topic.id] != nil { Text("手动调整").foregroundStyle(.secondary).font(.caption) }
                                    if let score = note.scores[topic.id] { Text(score, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                                }
                            }.toggleStyle(.checkbox).disabled(store.busy)
                        }
                        Text("勾选话题可调整归类；百分比为 Jev 的相关性判断。").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Divider()
                DisclosureGroup(note.kind == "capture" ? "OCR 识别文字" : "文字内容") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            if note.kind == "capture" {
                                Text("识别文字仅供检索参考，请以截图为准。").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(note.text, forType: .string) } label: {
                                Label("复制文字", systemImage: "doc.on.doc")
                            }.buttonStyle(.borderless)
                        }
                        Text(note.text).font(.system(size: 14)).lineSpacing(7).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.padding(.top, 12)
                }
                Divider()
                HStack {
                    Text(note.model ?? "尚未完成模型判断").font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button(isProjectMember ? "删除当前截图…" : "删除资料…", role: .destructive) { confirmDelete = true }.buttonStyle(.borderless)
                }
            }.padding(30).frame(maxWidth: 850)
                .frame(maxWidth: .infinity)
        }
        .confirmationDialog("删除这份资料及其截图？此操作无法撤销。", isPresented: $confirmDelete) {
            Button("删除资料", role: .destructive) { Task {
                await store.mutate("api/records/\(note.id)", method: "DELETE")
            } }
        }
    }
}

struct EditorView: View {
    @EnvironmentObject var store: NoteStore
    @Environment(\.dismiss) var dismiss
    let kind: EditorSheet
    @State private var title = ""
    @State private var text = ""
    @State private var url = ""
    @FocusState private var focused: Bool
    var valid: Bool { kind == .capture || (kind == .topic ? !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= 60 : text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 10 && text.count <= 100000) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(kind == .topic ? "最近，你在关注什么？" : kind == .note ? "把好内容留下来" : "开启你的收集助手", systemImage: kind == .capture ? "macwindow" : "leaf").font(.title2.weight(.semibold))
            if kind == .capture {
                Text("Jev 会留意前台窗口的变化，在内容稳定后提取文字。").foregroundStyle(.secondary)
                Label("截图与原文保存在这台 Mac。", systemImage: "internaldrive")
                Label("识别文字会发送至 TypeSafe，用于话题归类。", systemImage: "sparkles")
                Label("可随时暂停；跳过 Dashcam 和已知密码应用。", systemImage: "pause.circle")
                Text("首次使用需要 macOS 屏幕录制授权。关闭主窗口后采集会继续，菜单栏可暂停；退出 App 会停止采集。").font(.callout).foregroundStyle(.secondary)
            } else {
                Text(kind == .topic ? "描述你的关注目标，Jev 会帮你留意相关内容。" : "粘贴至少 10 个字，Jev 会匹配你关注的话题。").foregroundStyle(.secondary)
                TextField(kind == .topic ? "话题名称" : "标题（可选）", text: $title).textFieldStyle(.roundedBorder).focused($focused)
                Text(kind == .topic ? "具体关注什么（可选）" : "原文").font(.headline)
                TextEditor(text: $text).font(.body).padding(5).frame(height: kind == .topic ? 120 : 220).background(.background).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                if kind == .note { TextField("来源链接（可选）", text: $url).textFieldStyle(.roundedBorder) }
            }
            if let error = store.error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(kind == .topic ? "创建话题" : kind == .note ? "收集并归类" : "Start Recording") {
                    Task {
                        let path = kind == .topic ? "api/topics" : kind == .note ? "api/import" : "api/capture/start"
                        let body: [String: Any] = kind == .topic ? ["name": title, "description": text] : kind == .note ? ["title": title, "text": text, "url": url] : [:]
                        if await store.mutate(path, body: body) { dismiss() }
                    }
                }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(!valid || store.busy || !store.ready)
            }
        }.padding(28).frame(width: 520).tint(gardenGreen)
            .onAppear { store.error = nil; focused = true }
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: NoteStore
    @State private var key = ""
    @State private var model = "jev-latest"
    @State private var message = ""
    var body: some View {
        Form {
            Section("Jev 归类") {
                LabeledContent("状态", value: store.status.modelConfigured ? "API Key 已配置" : "尚未配置 API Key")
                SecureField("TypeSafe API Key", text: $key, prompt: Text(store.status.modelConfigured ? "留空保留现有密钥" : "输入 API Key"))
                TextField("模型", text: $model)
                HStack {
                    Text("密钥仅保存在本机应用数据目录，文件仅当前用户可读写。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("保存") {
                        Task {
                            var body: [String: Any] = ["model": model]
                            if !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body["apiKey"] = key }
                            if await store.mutate("api/settings", body: body) { key = ""; message = "设置已保存" }
                        }
                    }.disabled(store.busy || !store.ready)
                }
                if !message.isEmpty { Text(message).foregroundStyle(gardenGreen) }
                if let error = store.error { Text(error).foregroundStyle(.red) }
            }
            CapturePreferencesSettings()
            WindowExclusionSettings()
            StorageSettings()
            Section("采集与导出") {
                Button("打开屏幕录制权限设置") { store.openPermissions() }
                Text("允许 Dashcam 录制屏幕后，请退出并重新打开 App。采集始终由你手动开启。").font(.caption).foregroundStyle(.secondary)
                Button("导出资料为 JSON…") { store.export() }.disabled(!store.ready)
            }
            Section { Text("Dashcam \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版") · macOS 原生版\n文字识别在本机完成，归类文字发送至 TypeSafe。").font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped).padding(8).frame(width: 620, height: 680).tint(gardenGreen)
            .onAppear { model = store.status.model }
    }
}
