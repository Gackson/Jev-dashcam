import SwiftUI

struct ScreenshotPreview: View {
    @EnvironmentObject var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    let frame: Frame
    @State private var image: NSImage?
    @State private var finished = false
    @State private var scale: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Label("截图预览", systemImage: "photo") .font(.headline)
                Spacer()
                Button { scale = max(0.25, scale / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }
                    .accessibilityLabel("缩小截图").disabled(scale <= 0.25)
                Text("\(Int(scale * 100))%") .monospacedDigit().frame(width: 48)
                    .accessibilityLabel("缩放比例 \(Int(scale * 100))%")
                Button { scale = min(8, scale * 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                    .accessibilityLabel("放大截图").disabled(scale >= 8)
                Button("适应窗口") { scale = 1 }
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }.buttonStyle(.borderless).padding(16)
            Divider()
            GeometryReader { geometry in
                if let image {
                    let fit = min((geometry.size.width - 32) / image.size.width, (geometry.size.height - 32) / image.size.height)
                    let zoom = min(8, max(0.25, scale * pinch))
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: image.size.width * fit * zoom, height: image.size.height * fit * zoom)
                            .padding(16)
                            .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { scale = scale == 1 ? 2 : 1 }
                            .accessibilityLabel("放大查看来源截图")
                    }
                    .gesture(MagnificationGesture().updating($pinch) { value, state, _ in state = value }
                        .onEnded { scale = min(8, max(0.25, scale * $0)) })
                } else if finished {
                    ContentUnavailableView("截图文件不存在", systemImage: "photo.badge.exclamationmark", description: Text("原始截图可能已移动或删除。"))
                } else {
                    ProgressView("正在加载截图…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.background(Color.black.opacity(0.04))
            Text("双击切换放大 · 触控板捏合缩放 · 滚动查看细节 · Esc 关闭")
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }.frame(width: 900, height: 660).tint(gardenGreen)
        .task(id: frame.id) {
            finished = false
            let loaded = await store.screenshot(frame, maxPixelSize: 16384)
            guard !Task.isCancelled else { return }
            image = loaded; finished = true
        }
    }
}
