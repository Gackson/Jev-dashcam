import SwiftUI

struct CapturePreferencesSettings: View {
    @EnvironmentObject var store: NoteStore
    @State private var seconds = 60
    @State private var message = ""
    var body: some View {
        Section("采集与分组") {
            HStack {
                Text("切回同一窗口时合并的最长间隔")
                Spacer()
                TextField("秒", value: $seconds, format: .number)
                    .frame(width: 70).multilineTextAlignment(.trailing)
                Text("秒").foregroundStyle(.secondary)
            }
            Text("默认 60 秒，可设为 0–3600 秒；0 表示切走后不再续接原组。连续浏览同一窗口会始终归为一组，每张截图仍独立归类。修改适用于之后的窗口切换，已有分组保持不变。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(message).font(.caption).foregroundStyle(gardenGreen)
                Spacer()
                Button("保存分组设置") {
                    Task {
                        if await store.mutate("api/capture-preferences", body: ["windowReturnSeconds": seconds]) { message = "分组间隔已保存" }
                    }
                }.disabled(store.busy || !store.ready || !(0...3600).contains(seconds))
            }
            Text("待归类队列不会暂停采集。采集开启时，每 5 分钟批量检查一次，清理已保留超过 1 小时、仍在排队等待首次归类的截图（每批最多 500 份）。暂停采集时不清理；正在归类、归类失败、已归类及待整理资料均保留。")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear { seconds = store.capturePreferences.windowReturnSeconds }
    }
}
