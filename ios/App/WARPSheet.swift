import SwiftUI

/// Создание WARP: регистрация аккаунта Cloudflare и профиль AmneziaWG с junk-параметрами.
/// Эндпоинт можно сменить — на этой сети отдельные адреса периодически перестают отвечать.
struct WARPSheet: View {
    @EnvironmentObject private var store: ProfileStore
    @Environment(\.presentationMode) private var presentation

    @State private var busy = false
    @State private var status = "WARP регистрируется в Cloudflare и подключается через AmneziaWG"
    @State private var error = ""
    @State private var endpointIndex = 0
    @State private var created: Profile?

    private var endpoint: String { WARPCreator.endpoints[endpointIndex] }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: "circle.grid.cross")
                            .foregroundColor(Theme.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(created == nil ? "WARP не создан" : "WARP готов")
                                .font(.subheadline.weight(.semibold))
                            Text(status)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer(minLength: 6)
                        if busy { ProgressView() }
                    }
                } header: {
                    Text("Состояние")
                }

                Section {
                    // .navigationLink есть только с iOS 16, а проект собирается с 15.0.
                    Picker("Эндпоинт", selection: $endpointIndex) {
                        ForEach(Array(WARPCreator.endpoints.enumerated()), id: \.offset) { index, item in
                            Text(item).tag(index)
                        }
                    }
                } header: {
                    Text("Эндпоинт")
                } footer: {
                    Text("Список проверен на этой сети: все адреса поднимали туннель через узел HEL. Если один перестал работать — выбери другой.")
                }

                Section {
                    Button {
                        Task { await create() }
                    } label: {
                        HStack {
                            Text(created == nil ? "Создать WARP" : "Создать ещё один WARP")
                            Spacer()
                            if busy { ProgressView() }
                        }
                    }
                    .disabled(busy)

                    if let created {
                        Button {
                            Task { await rotate(created) }
                        } label: {
                            Label("Сменить эндпоинт у этого WARP", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(busy)
                    }
                }

                if !error.isEmpty {
                    Section {
                        Text(error).font(.caption).foregroundColor(Theme.accent)
                    }
                }
            }
            .navigationTitle("WARP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") { presentation.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func create() async {
        busy = true
        error = ""
        status = "регистрирую аккаунт…"
        do {
            let account = try await WARPCreator.register()
            let payload = WARPCreator.payload(account: account, endpoint: endpoint)
            let profile = store.addWARP(payload: payload, endpoint: endpoint, folderID: nil)
            created = profile
            store.select(profile.id)
            status = "профиль создан · эндпоинт " + endpoint
        } catch {
            self.error = error.localizedDescription
            status = "не получилось"
        }
        busy = false
    }

    private func rotate(_ profile: Profile) async {
        busy = true
        error = ""
        // Ключи берём из текущего профиля: аккаунт уже зарегистрирован, менять его не нужно.
        guard let account = WARPCreator.account(from: profile.payload) else {
            error = "не удалось прочитать ключи профиля"
            busy = false
            return
        }
        endpointIndex = (endpointIndex + 1) % WARPCreator.endpoints.count
        let payload = WARPCreator.payload(account: account, endpoint: endpoint)
        store.updateWARP(profile: profile, payload: payload, endpoint: endpoint)
        status = "эндпоинт сменён на " + endpoint
        busy = false
    }
}
