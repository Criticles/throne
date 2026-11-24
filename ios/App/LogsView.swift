import SwiftUI

/// Единый журнал: импорт подписки и логи ядра в одном потоке.
/// Экспорт отдаёт файл в системный лист «Поделиться» — оттуда он уезжает в Файлы или мессенджер.
struct LogsView: View {
    @StateObject private var logs = LogStore.shared
    @State private var exportItem: ExportFile?

    var body: some View {
        ScrollView {
            Text(logs.text.isEmpty ? "пусто" : logs.text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .navigationTitle("Журнал")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        export()
                    } label: {
                        Label("Экспорт в txt", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.string = logs.text
                    } label: {
                        Label("Скопировать всё", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        logs.clear()
                    } label: {
                        Label("Очистить", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $exportItem) { item in
            ShareSheet(items: [item.url])
        }
    }

    private func export() {
        let stamp = Self.fileStamp.string(from: Date())
        let name = "throne-log-" + stamp + ".txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let text = logs.text.isEmpty ? "журнал пуст\n" : logs.text
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            exportItem = ExportFile(url: url)
        } catch {
            logs.append("экспорт не удался: " + error.localizedDescription)
        }
    }

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter
    }()
}

struct ExportFile: Identifiable {
    let id = UUID()
    let url: URL
}
