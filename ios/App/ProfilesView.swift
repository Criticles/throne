import SwiftUI

/// Главный экран: состояние туннеля, папки подписок и список серверов.
struct ProfilesView: View {
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var engine: DevEngine

    @State private var folder: String? = nil
    @State private var query = ""
    @State private var probeLine = ""
    @State private var showAdd = false
    @State private var addText = ""
    @State private var addTitle = ""

    private var visible: [Profile] {
        store.profiles.filter { profile in
            let inFolder = folder == nil || (profile.group ?? ProfileStore.manualFolder) == folder
            guard inFolder else { return false }
            guard !query.isEmpty else { return true }
            return profile.name.localizedCaseInsensitiveContains(query)
                || (profile.badge ?? profile.kind.title).localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationView {
            List {
                connectionSection
                folderSection
                serverSection
                actionsSection
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Сервер или протокол")
            .navigationTitle("Серверы")
            .toolbar { toolbarContent }
            .sheet(isPresented: $showAdd) { addSheet }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Состояние

    private var connectionSection: some View {
        Section {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(engine.running ? (engine.activeName ?? "подключено") : "Не подключено")
                        .font(.headline)
                        .lineLimit(2)
                    if let profile = store.selected {
                        ProtocolBadge(text: profile.badge ?? profile.kind.title)
                    }
                    Text(statusLine)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
                PowerButton(on: engine.running, busy: engine.bulkRunning) {
                    Task { await toggle() }
                }
                .disabled(engine.bulkRunning)
            }
            .padding(.vertical, 6)

            if engine.transportOnly {
                Label("только транспорт: VK и SRTP подняты, туннеля нет",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            if let error = engine.lastError, !engine.running {
                Text(error).font(.caption).foregroundColor(.red)
            }
        }
    }

    private var statusLine: String {
        if !probeLine.isEmpty { return probeLine }
        if engine.running { return "проверьте выход: «Проверить» на строке сервера или «Проверить все»" }
        if store.selected == nil { return "добавьте подписку кнопкой +" }
        return "нажмите кнопку питания, чтобы поднять туннель"
    }

    private var folderSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FolderChip(title: "Все", count: store.profiles.count, selected: folder == nil) {
                        folder = nil
                    }
                    ForEach(store.folders, id: \.self) { name in
                        FolderChip(title: name, count: store.count(in: name), selected: folder == name) {
                            folder = name
                        }
                    }
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 2)
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private var serverSection: some View {
        Section {
            if visible.isEmpty {
                Text(store.profiles.isEmpty
                     ? "пока пусто. Кнопка + сверху: ссылка подписки, буфер обмена или отдельная vless://"
                     : "в этой папке ничего не нашлось")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(visible) { profile in
                ServerRow(profile: profile,
                          selected: store.selectedID == profile.id,
                          active: engine.running && engine.activeName == profile.name,
                          bulk: bulkRow(for: profile))
                    .contentShape(Rectangle())
                    .onTapGesture { store.select(profile.id) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            store.delete(profile)
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                        Button {
                            Task { await check(profile) }
                        } label: {
                            Label("Проверить", systemImage: "waveform.path.ecg")
                        }
                        .tint(.orange)
                    }
                    .contextMenu {
                        Button {
                            store.select(profile.id)
                            Task { await toggle() }
                        } label: {
                            Label("Подключиться", systemImage: "power")
                        }
                        Button {
                            Task { await check(profile) }
                        } label: {
                            Label("Проверить выход", systemImage: "waveform.path.ecg")
                        }
                        if let link = shareLink(profile) {
                            Button {
                                UIPasteboard.general.string = link
                            } label: {
                                Label("Скопировать ссылку", systemImage: "doc.on.doc")
                            }
                        }
                        Divider()
                        Button(role: .destructive) {
                            store.delete(profile)
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
            }
        } header: {
            HStack {
                Text(folder ?? "Все серверы")
                Spacer()
                if engine.bulkRunning {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Text("\(visible.count)")
                }
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                Task { await engine.checkAll(profiles: visible) }
            } label: {
                Label(engine.bulkRunning ? "Проверяю…" : "Проверить все (\(visible.count))",
                      systemImage: "waveform.path.ecg")
            }
            .disabled(engine.bulkRunning || visible.isEmpty)

            if let subscription = store.subscriptions.first(where: { $0.name == folder }) {
                Button {
                    Task { await store.refresh(subscription) }
                } label: {
                    Label(store.loading ? "Обновляю…" : "Обновить подписку", systemImage: "arrow.clockwise")
                }
                .disabled(store.loading)
            }
        } footer: {
            Text("Проверка поднимает серверы по очереди и снимает IP, страну и задержку. WireTurn авторизуется в VK, поэтому в серии их не больше 8.")
        }
    }

    // MARK: - Кнопки сверху

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    addText = ""
                    addTitle = ""
                    showAdd = true
                } label: {
                    Label("Подписка по ссылке", systemImage: "link")
                }
                Button {
                    importClipboard()
                } label: {
                    Label("Импорт из буфера", systemImage: "doc.on.clipboard")
                }
                if !store.subscriptions.isEmpty {
                    Divider()
                    Button {
                        Task { await refreshAll() }
                    } label: {
                        Label("Обновить все подписки", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                Divider()
                Button(role: .destructive) {
                    store.removeAll()
                    folder = nil
                    probeLine = ""
                } label: {
                    Label("Удалить все серверы", systemImage: "trash")
                }
            } label: {
                Image(systemName: "plus.circle.fill").font(.title3)
            }
        }
    }

    private var addSheet: some View {
        NavigationView {
            Form {
                Section {
                    TextField("https://…/sub/<токен>", text: $addText)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                    TextField("Имя папки (необязательно)", text: $addTitle)
                } header: {
                    Text("Ссылка подписки")
                } footer: {
                    Text("В ссылке есть токен доступа: она остаётся только на этом устройстве.")
                }
                Section {
                    Button("Взять из буфера обмена") { importClipboard() }
                }
            }
            .navigationTitle("Новая подписка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { showAdd = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") { addSubscription() }
                        .disabled(addText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Действия

    private func addSubscription() {
        let input = addText.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = addTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        showAdd = false
        Task {
            if input.lowercased().hasPrefix("http") {
                await store.importFromURL(input, name: name.isEmpty ? nil : name)
            } else {
                store.importFromText(input)
            }
            if !name.isEmpty { folder = name }
        }
    }

    private func importClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            probeLine = "буфер обмена пуст"
            return
        }
        showAdd = false
        Task { await store.importAny(text) }
    }

    private func refreshAll() async {
        for subscription in store.subscriptions {
            await store.refresh(subscription)
        }
    }

    private func toggle() async {
        if engine.running {
            engine.stop()
            probeLine = ""
            return
        }
        guard let profile = store.selected else {
            probeLine = "сначала выберите сервер"
            return
        }
        engine.start(profile: profile)
        guard engine.running, !engine.transportOnly else { return }
        if !engine.isListening() {
            probeLine = "ядро не слушает \(engine.socksAddress)"
            return
        }
        probeLine = "проверяю выход…"
        let result = await Probe.timed(port: engine.proxyPort, timeout: 15)
        probeLine = result?.summary ?? "нет связи — смотрите журнал"
    }

    private func check(_ profile: Profile) async {
        await engine.check(profile: profile)
        if let result = bulkRow(for: profile)?.result {
            probeLine = result.summary
        }
    }

    private func bulkRow(for profile: Profile) -> DevEngine.BulkRow? {
        engine.bulk.first { $0.id == profile.id }
    }

    /// Поделиться можно только тем профилем, у которого есть share-ссылка.
    private func shareLink(_ profile: Profile) -> String? {
        let text = profile.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.contains("://") ? text : nil
    }
}

/// Строка списка: имя сервера, протокол, задержка и последний результат проверки.
struct ServerRow: View {
    let profile: Profile
    let selected: Bool
    let active: Bool
    let bulk: DevEngine.BulkRow?

    private var millis: Int? { bulk?.result?.millis }

    private var detail: String? {
        guard let bulk else { return nil }
        if let result = bulk.result {
            if result.ok {
                let parts = [result.ip, result.country].compactMap { $0 }
                return parts.isEmpty ? nil : parts.joined(separator: " · ")
            }
            return result.error
        }
        return bulk.note
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundColor(selected ? Theme.accent : Color(uiColor: .tertiaryLabel))
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if active {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                            .foregroundColor(Theme.accent)
                    }
                }
                ProtocolBadge(text: profile.badge ?? profile.kind.title)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundColor(bulk?.result?.ok == false ? .red : .secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 3) {
                Text(Theme.pingText(millis))
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .foregroundColor(Theme.pingColor(millis))
                if let bulk, !bulk.done {
                    ProgressView().scaleEffect(0.6)
                }
            }
        }
        .padding(.vertical, 5)
    }
}
