import SwiftUI

/// Единый журнал: импорт подписки и логи ядра в одном потоке.
struct LogsView: View {
    @StateObject private var logs = LogStore.shared

    var body: some View {
        NavigationView {
            ScrollView {
                Text(logs.text.isEmpty ? "пусто" : logs.text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(uiColor: .secondarySystemBackground))
            .navigationTitle("Журнал")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
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
        }
        .navigationViewStyle(.stack)
    }
}
