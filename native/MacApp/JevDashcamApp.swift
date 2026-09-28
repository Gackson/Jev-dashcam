import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: NoteStore?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        store?.migratingStorage == true ? .terminateCancel : .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { store?.stop() }
}

@main
struct JevDashcamApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = NoteStore()
    var body: some Scene {
        Window("Dashcam", id: "library") {
            LibraryView().environmentObject(store)
                .onAppear { delegate.store = store }
        }
        .defaultSize(width: 1240, height: 800)
        .commands { LibraryCommands(store: store) }
        Settings { SettingsView().environmentObject(store) }
        MenuBarExtra("Dashcam", systemImage: store.status.running ? "leaf.fill" : "leaf") {
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
                Button(store.status.running ? "Pause Recording" : "Start Recording…") {
                    if store.status.running { store.toggleCapture() } else { present(.capture) }
                }.keyboardShortcut("p", modifiers: [.command, .shift]).disabled(!store.ready)
            }
    }
}

struct MenuContent: View {
    @EnvironmentObject var store: NoteStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(store.status.running ? "Dashcam · 正在采集" : "Dashcam · 已暂停")
        Button("打开 Dashcam") { openWindow(id: "library"); NSApp.activate(ignoringOtherApps: true) }
        Button(store.status.running ? "Pause Recording" : "Start Recording…") {
            if !store.status.running { openWindow(id: "library"); NSApp.activate(ignoringOtherApps: true) }
            store.toggleCapture()
        }.disabled(!store.ready)
        Divider()
        SettingsLink { Text("设置…") }
        Button("退出 Dashcam") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
