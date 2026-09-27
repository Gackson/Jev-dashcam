import SwiftUI
import AppKit

struct PersistentDetailSplit<Preview: View, Detail: View>: View {
    @AppStorage("library.previewColumnWidth") private var savedWidth: Double = 300
    @State private var dragStart: CGFloat?
    @State private var draggingWidth: CGFloat?
    var isPresented: Bool = true
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let detail: () -> Detail

    private func constrained(_ width: CGFloat, available: CGFloat) -> CGFloat {
        let maximum = max(240, min(600, available - 389))
        return min(maximum, max(240, width.isFinite ? width : 300))
    }

    var body: some View {
        GeometryReader { geometry in
            let width = isPresented ? constrained(draggingWidth ?? CGFloat(savedWidth), available: geometry.size.width) : geometry.size.width
            HStack(spacing: 0) {
                preview().frame(width: width, height: geometry.size.height)
                if isPresented {
                ZStack {
                    Color.clear
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1)
                    Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 3, height: 28)
                }
                .frame(width: 9, height: geometry.size.height)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
                }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("detail-split"))
                    .onChanged { value in
                        if dragStart == nil { dragStart = width }
                        draggingWidth = constrained((dragStart ?? width) + value.translation.width, available: geometry.size.width)
                    }
                    .onEnded { _ in
                        savedWidth = Double(draggingWidth ?? width)
                        draggingWidth = nil; dragStart = nil
                    })
                .accessibilityElement()
                .accessibilityLabel("预览栏宽度")
                .accessibilityValue("\(Int(width)) 点")
                .accessibilityAdjustableAction { direction in
                    let adjustment: CGFloat = direction == .increment ? 20 : -20
                    savedWidth = Double(constrained(width + adjustment, available: geometry.size.width))
                }
                detail().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .coordinateSpace(name: "detail-split")
        }
    }
}
