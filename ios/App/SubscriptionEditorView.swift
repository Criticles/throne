import SwiftUI

/// «Изм»: подписки — добавить, переставить (долгое нажатие), настроить (нажатие).
struct SubscriptionEditorView: View {
    @EnvironmentObject private var store: ProfileStore
    @Environment(\.presentationMode) private var presentation

    @State private var addURL = ""
    @State private var addName = ""
    @State private var showAdd = false
    @State private var editItem: Subscription?
    @State private var qrItem: Subscription?

    var body: some View {
        NavigationView {
            content
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showAdd) { addSheet }
        .sheet(item: $editItem) { subscription in
            SubscriptionSettingsView(subscription: subscription)
        }
    }

    private var content: some View {
        List {
            Section {
                if store.subscriptions.isEmpty {
                    Text("подписок нет — нажмите +")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(store.subscriptions) { subscription in
                    Button {
                        editItem = subscription
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(store.folderName(for: subscription))
                                    .font(.subheadline.weight(.medium))
                                    .foregroundColor(.primary)
                                Text(String(subscription.count) + " серверов"
                                     + (subscription.autoUpdate ? " · автообновление" : ""))
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
                }
                .onMove { source, destination in
                    store.moveSubscription(from: source, to: destination)
                }
                .onDelete { offsets in
                    let victims = offsets.map { store.subscriptions[$0] }
                    for subscription in victims { store.remove(subscription) }
                }
            } footer: {
                Text("Нажатие — настройки подписки. Свайп влево — удалить.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Подписки").font(.headline)
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
                    showAdd = true
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

    private var addSheet: some View {
        NavigationView {
            Form {
                Section {
                    TextField("https://…/sub/<токен>", text: $addURL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                    TextField("Имя папки", text: $addName)
                }
            }
            .navigationTitle("Новая подписка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { showAdd = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") {
                        let url = addURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        let typed = addName.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Каждый импорт — своя папка: имя можно оставить и таким же, как у другой.
                        let base = typed.isEmpty ? ProfileStore.folderName(for: url) : typed
                        let folder = store.addFolder(name: base)
                        showAdd = false
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
/// Настройки одной подписки: имя папки, автообновление, интервал, поделиться, удалить.
struct SubscriptionSettingsView: View {
    @EnvironmentObject private var store: ProfileStore
    @Environment(\.presentationMode) private var presentation

    let subscription: Subscription

    @State private var name = ""
    @State private var autoUpdate = true
    @State private var hours = 12
    @State private var loaded = false
    @State private var showQR = false

    private var current: Subscription {
        store.subscriptions.first { $0.id == subscription.id } ?? subscription
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Имя папки", text: $name)
                        .autocapitalization(.none)
                    Toggle("Автообновление", isOn: $autoUpdate)
                    if autoUpdate {
                        Stepper("Каждые " + String(hours) + " ч", value: $hours, in: 1...72)
                    }
                } header: {
                    Text("Подписка")
                } footer: {
                    Text("Имя — подпись папки: серверы остаются на месте, меняется только название. Одинаковые имена разрешены.")
                }

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
                }

                Section {
                    Button(role: .destructive) {
                        store.remove(current)
                        presentation.wrappedValue.dismiss()
                    } label: {
                        Label("Удалить подписку", systemImage: "trash")
                    }
                }
            }
            .navigationTitle(store.folderName(for: current))
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
                QRCodeSheet(title: "QR подписки", text: current.url)
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                name = store.folderName(for: current)
                autoUpdate = current.autoUpdate
                hours = current.intervalHours
            }
        }
        .navigationViewStyle(.stack)
    }

    private func save() {
        store.rename(current, to: name)
        store.setAutoUpdate(autoUpdate, intervalHours: hours, for: current)
        presentation.wrappedValue.dismiss()
    }

    private static func deepLink(_ link: String) -> String {
        let encoded = link.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? link
        return "throne://import?url=" + encoded
    }
}
