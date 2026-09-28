import SwiftUI

struct CapturePreferencesSettings: View {
    @EnvironmentObject var store: NoteStore
    @State private var seconds = 60
    @State private var message = ""
    @State private var hours = "1"
    @State private var keepForever = false
    private var validRetention: Bool { keepForever || (Int(hours).map { (1...720).contains($0) } ?? false) }
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
            Divider()
            Toggle("未分类内容一直保留", isOn: $keepForever)
            HStack {
                Text("未分类内容保留时长")
                Spacer()
                TextField("小时", text: $hours).frame(width: 70).multilineTextAlignment(.trailing)
                    .disabled(keepForever)
                Text("小时").foregroundStyle(.secondary)
            }
            Text("默认 1 小时，可设为 1–720 小时。仅清理等待首次分类的截图；时长从采集时间计算，修改后在下一次定期检查时生效。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(message).font(.caption).foregroundStyle(gardenGreen)
                Spacer()
                Button("保存采集设置") {
                    Task {
                        if await store.mutate("api/capture-preferences", body: ["windowReturnSeconds": seconds, "pendingRetentionHours": keepForever ? 0 : (Int(hours) ?? 1)]) { message = "采集设置已保存" }
                    }
                }.disabled(store.busy || !store.ready || !(0...3600).contains(seconds) || !validRetention)
            }
            Text("待归类队列不会暂停采集。采集开启时，每 5 分钟批量检查一次，按设置的保留时长清理仍在排队等待首次归类的截图（每批最多 500 份）。暂停采集时不清理；正在归类、归类失败、已归类及待整理资料均保留。")
                .font(.caption).foregroundStyle(.secondary)
        }.onAppear {
            seconds = store.capturePreferences.windowReturnSeconds
            let retention = store.capturePreferences.pendingRetentionHours
            keepForever = retention == 0; hours = String(max(1, retention))
        }
    }
}
