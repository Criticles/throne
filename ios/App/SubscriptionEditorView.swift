import SwiftUI

/// «Изм» для подписок: переименовать (то есть перенести её серверы в другую папку) или удалить.
struct SubscriptionEditorView: View {
    @EnvironmentObject private var store: ProfileStore
    @Environment(\.presentationMode) private var presentation

    @State private var drafts: [UUID: String] = [:]

    var body: some View {
        NavigationView {
            List {
                Section {
                    if store.subscriptions.isEmpty {
                        Text("подписок нет")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    ForEach(store.subscriptions) { subscription in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField(subscription.name, text: binding(for: subscription))
                                .font(.subheadline.weight(.medium))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                            HStack {
                                Text(subscription.count.description + " серверов")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button("Перенести", role: .destructive) {
                                    store.remove(subscription)
                                }
                                .font(.caption)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } footer: {
                    Text("Имя подписки — это название папки: переименование переносит её серверы в новую папку. Удаление убирает подписку вместе с серверами.")
                }
            }
            .navigationTitle("Подписки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") {
                        drafts = [:]
                        presentation.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        save()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func binding(for subscription: Subscription) -> Binding<String> {
        Binding(
            get: { drafts[subscription.id] ?? subscription.name },
            set: { drafts[subscription.id] = $0 }
        )
    }

    private func save() {
        for subscription in store.subscriptions {
            if let draft = drafts[subscription.id] {
                store.rename(subscription, to: draft)
            }
        }
        drafts = [:]
        presentation.wrappedValue.dismiss()
    }
}
