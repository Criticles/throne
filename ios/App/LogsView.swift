import SwiftUI

/// Единый журнал: импорт подписки и логи ядра в одном потоке.
/// Экспорт отдаёт файл в системный лист «Поделиться» — оттуда он уезжает в Файлы или мессенджер.
struct LogsView: View {
    @ObservedObject private var logs = LogStore.shared
    @State private var exportItem: ExportFile?
    @State private var follow = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Показываем хвост: один `Text` на весь журнал подвисал, и новые строки
                // не появлялись, пока список не очистишь.
                Text(logs.tail(600).isEmpty ? "пусто" : logs.tail(600))
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                Color.clear.frame(height: 1).id("bottom")
            }
            .background(Color(uiColor: .secondarySystemBackground))
            .onChange(of: logs.text) { _ in
                guard follow else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .onAppear {
                logs.flush()
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            .navigationTitle("Журнал")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            follow.toggle()
                        } label: {
                            Label(follow ? "Не следить за концом" : "Следить за концом",
                                  systemImage: follow ? "arrow.down.to.line.alt" : "arrow.down.to.line")
                        }
                        Button {
                            export()
                        } label: {
                            Label("Экспорт в txt", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            UIPasteboard.general.string = logs.tail(2000)
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
