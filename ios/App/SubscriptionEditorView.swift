import SwiftUI

/// «Изм»: папки серверов и подписки. Здесь же переименование уже созданных папок —
/// даже если папка создана вручную и подписки в ней нет.
struct SubscriptionEditorView: View {
    @EnvironmentObject private var store: ProfileStore
    @Environment(\.presentationMode) private var presentation

    @State private var addURL = ""
    @State private var addName = ""
    /// Один лист на экран: iOS 15 держит только последний `.sheet` из цепочки.
    private enum Sheet: Identifiable {
        case add
        case settings(Folder)
        case scanner

        var id: String {
            switch self {
            case .add: return "add"
            case .settings(let folder): return "settings-\(folder.id.uuidString)"
            case .scanner: return "scanner"
            }
        }
    }

    @State private var sheet: Sheet?

    var body: some View {
        NavigationView {
            content
        }
        .navigationViewStyle(.stack)
        .sheet(item: $sheet) { item in
            switch item {
            case .add:
                addSheet
            case .settings(let folder):
                SubscriptionSettingsView(folderID: folder.id)
            case .scanner:
                NavigationView {
                    QRScannerView { code in
                        sheet = nil
                        addURL = code
                    }
                }
                .navigationViewStyle(.stack)
            }
        }
    }

    private var content: some View {
        List {
            Section {
                if store.folders.isEmpty {
                    Text("папок нет — нажмите + или добавьте подписку")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(store.folders) { folder in
                    Button {
                        sheet = .settings(folder)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(folder.name)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(.primary)
                                Text(subtitle(for: folder))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            store.deleteFolder(folder.id)
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                }
            } footer: {
                Text("Нажатие — имя папки и настройки подписки. Свайп влево — удалить папку вместе с серверами. Одинаковые названия разрешены.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Папки и подписки").font(.headline)
            }
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    presentation.wrappedValue.dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    sheet = .add
                } label: {
                    Image(systemName: "plus")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    presentation.wrappedValue.dismiss()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Theme.accent)
                }
            }
        }
    }

    private func subtitle(for folder: Folder) -> String {
        let servers = String(store.count(in: folder.id)) + " серверов"
        guard let subscription = store.subscription(in: folder.id) else {
            return servers + " · папка без подписки"
        }
        var parts = [servers, subscription.autoUpdate ? "автообновление" : "подписка"]
        if subscription.url.isEmpty { parts = [servers] }
        return parts.joined(separator: " · ")
    }

    private var addSheet: some View {
        NavigationView {
            Form {
                Section {
                    TextField("https://…/sub/<токен>", text: $addURL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                    TextField("Имя папки", text: $addName)
                } footer: {
                    Text("Каждый импорт создаёт папку: имя можно оставить любым, даже совпадающим с другой папкой.")
                }
                Section {
                    Button {
                        let text = (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { addURL = text }
                    } label: {
                        Label("Взять из буфера обмена", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        // Второй лист поверх первого iOS 15 не открывает: закрываем и ждём.
                        sheet = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { sheet = .scanner }
                    } label: {
                        Label("Сканировать QR", systemImage: "qrcode.viewfinder")
                    }
                } footer: {
                    Text("QR подписки или сервера — то же, что ссылка в поле выше.")
                }
            }
            .navigationTitle("Новая подписка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { sheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") {
                        let url = addURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        let typed = addName.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Каждый импорт — своя папка: имя можно оставить и таким же, как у другой.
                        let base = typed.isEmpty ? ProfileStore.folderName(for: url) : typed
                        let folder = store.addFolder(name: base)
                        sheet = nil
                        Task { await store.importFromURL(url, folderID: folder.id) }
                        addURL = ""
                        addName = ""
                    }
                    .disabled(addURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// Настройки папки: имя (правится здесь), подписка внутри — автообновление, ссылка, QR, удаление.
struct SubscriptionSettingsView: View {
    @EnvironmentObject private var store: ProfileStore
    @Environment(\.presentationMode) private var presentation

    let folderID: UUID

    @State private var name = ""
    @State private var autoUpdate = true
    @State private var hours = 12
    @State private var loaded = false
    @State private var showQR = false

    private var folder: Folder? {
        store.folder(folderID)
    }

    private var subscription: Subscription? {
        store.subscription(in: folderID)
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Имя папки", text: $name)
                        .autocapitalization(.none)
                    if let subscription {
                        Toggle("Автообновление", isOn: $autoUpdate)
                        if autoUpdate {
                            Stepper("Каждые " + String(hours) + " ч", value: $hours, in: 1...72)
                        }
                        HStack {
                            Text("Серверов")
                            Spacer()
                            Text(String(store.count(in: folderID)))
                                .foregroundColor(.secondary)
                        }
                        if subscription.updated != nil {
                            HStack {
                                Text("Обновлено")
                                Spacer()
                                Text(Self.formatter.string(from: subscription.updated ?? Date()))
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        Text("Папка без подписки: серверы можно добавить в неё при импорте.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Папка")
                } footer: {
                    Text("Переименование меняет только подпись: серверы остаются в этой папке. Одинаковые имена разрешены.")
                }

                if let current = subscription {
                    Section {
                        Button {
                            UIPasteboard.general.string = current.url
                        } label: {
                            Label("Скопировать ссылку", systemImage: "doc.on.doc")
                        }
                        Button {
                            UIPasteboard.general.string = Self.deepLink(current.url)
                        } label: {
                            Label("Скопировать для Throne", systemImage: "link.badge.plus")
                        }
                        Button {
                            showQR = true
                        } label: {
                            Label("Показать QR", systemImage: "qrcode")
                        }
                        Button {
                            Task { await store.refresh(current) }
                        } label: {
                            Label("Обновить сейчас", systemImage: "arrow.clockwise")
                        }
                    } header: {
                        Text("Подписка")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        if let current = subscription {
                            store.remove(current)
                        } else {
                            store.deleteFolder(folderID)
                        }
                        presentation.wrappedValue.dismiss()
                    } label: {
                        Label(subscription == nil ? "Удалить папку" : "Удалить подписку и папку",
                              systemImage: "trash")
                    }
                }
            }
            .navigationTitle(folder?.name ?? "Папка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { presentation.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Theme.accent)
                    }
                }
            }
            .sheet(isPresented: $showQR) {
                if let current = subscription {
                    QRCodeSheet(title: "QR подписки", text: current.url)
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                name = folder?.name ?? ""
                autoUpdate = subscription?.autoUpdate ?? true
                hours = subscription?.intervalHours ?? 12
            }
        }
        .navigationViewStyle(.stack)
    }

    private func save() {
        store.renameFolder(folderID, to: name)
        if let current = subscription {
            store.setAutoUpdate(autoUpdate, intervalHours: hours, for: current)
        }
        presentation.wrappedValue.dismiss()
    }

    private static func deepLink(_ link: String) -> String {
        let encoded = link.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? link
        return "throne://import?url=" + encoded
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()
}
