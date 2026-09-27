import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: NoteStore?
    func applicationWillTerminate(_ notification: Notification) { store?.stop() }
}

@main
struct JevDashcamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = NoteStore()
    var body: some Scene {
        Window("Jev-dashcam", id: "library") {
            LibraryView().environmentObject(store)
                .onAppear { delegate.store = store }
        }
        .defaultSize(width: 1240, height: 800)
        .commands { LibraryCommands(store: store) }
        Settings { SettingsView().environmentObject(store) }
        MenuBarExtra("Jev-dashcam", systemImage: store.status.running ? "leaf.fill" : "leaf") {
            MenuContent().environmentObject(store)
        }
    }
}

struct LibraryCommands: Commands {
    @ObservedObject var store: NoteStore
    @Environment(\.openWindow) private var openWindow
    func present(_ sheet: EditorSheet) {
        openWindow(id: "library")
        NSApp.activate(ignoringOtherApps: true)
        store.sheet = sheet
    }
    var body: some Commands {
            CommandGroup(replacing: .newItem) {
                Button("手动录入…") { present(.note) }.keyboardShortcut("n").disabled(!store.ready)
                Button("创建话题…") { present(.topic) }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!store.ready)
                Divider()
                Button("导出资料…") { store.export() }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!store.ready)
            }
            CommandMenu("采集") {
                Button(store.status.running ? "暂停采集" : "开始采集…") {
                    if store.status.running { store.toggleCapture() } else { present(.capture) }
                }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(!store.ready)
                Button("重试失败归类") { Task { await store.mutate("api/retry") } }.disabled(!store.ready)
            }
    }
}

struct MenuContent: View {
    @EnvironmentObject var store: NoteStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(store.status.running ? "Jev-dashcam · 正在采集" : "Jev-dashcam · 已暂停")
        Button("打开 Jev-dashcam") { openWindow(id: "library"); NSApp.activate(ignoringOtherApps: true) }
        Button(store.status.running ? "暂停采集" : "开始采集…") {
            if !store.status.running { openWindow(id: "library"); NSApp.activate(ignoringOtherApps: true) }
            store.toggleCapture()
        }.disabled(!store.ready)
        Divider()
        SettingsLink { Text("设置…") }
        Button("退出 Jev-dashcam") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
