import SwiftUI

struct LibraryControls: View {
    @EnvironmentObject var store: NoteStore
    @State private var showFilters = false
    var body: some View {
        HStack(spacing: 16) {
            Menu {
                Picker("分组方式", selection: $store.organization.grouping) {
                    ForEach(LibraryGrouping.allCases) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Label(store.organization.grouping == .none ? "分组" : store.organization.grouping.rawValue, systemImage: "rectangle.3.group")
            }.fixedSize()
            Button { showFilters.toggle() } label: {
                Label(store.organization.activeCount == 0 ? "筛选" : "筛选 · \(store.organization.activeCount)", systemImage: "line.3.horizontal.decrease")
            }
            .popover(isPresented: $showFilters) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("筛选资料").font(.headline)
                        Spacer()
                        Button("完成") { showFilters = false }
                    }
                    Picker("来源 App", selection: $store.organization.source) {
                        Text("全部来源").tag(String?.none)
                        ForEach(Array(Set(store.records.map(\.app))).sorted(), id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    Picker("时间范围", selection: $store.organization.dateRange) {
                        ForEach(LibraryDateRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    if store.organization.dateRange == .custom {
                        DatePicker("开始日期", selection: $store.organization.startDate, displayedComponents: .date)
                        DatePicker("结束日期", selection: $store.organization.endDate, displayedComponents: .date)
                        Text("包含开始和结束当天，按本机时区筛选。").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("找到 \(store.filtered.count) 份资料").foregroundStyle(.secondary)
                        Spacer()
                        Button("清除筛选") { clearFilters() }.disabled(store.organization.activeCount == 0)
                    }
                }.padding(20).frame(width: 350)
            }
            if store.organization.activeCount > 0 {
                Text(store.organization.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Button("清除筛选") { clearFilters() }.font(.caption).fixedSize()
            }
            Spacer(minLength: 0)
        }.buttonStyle(.borderless).padding(.horizontal, 20).padding(.vertical, 10)
    }
    private func clearFilters() {
        store.organization.source = nil
        store.organization.dateRange = .all
    }
}
