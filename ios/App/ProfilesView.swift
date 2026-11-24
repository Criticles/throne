import SwiftUI

/// Главный экран: состояние туннеля, папки подписок и список серверов.
/// Пинг не висит в каждой строке: у сервера есть кнопка, результат появляется по нажатию.
struct ProfilesView: View {
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var engine: DevEngine
    @EnvironmentObject private var prefs: Prefs

    @State private var folder: String? = nil
    @State private var query = ""
    @State private var probeLine = ""
    @State private var showAdd = false
    @State private var addText = ""
    @State private var addTitle = ""

    private var rowsByID: [UUID: DevEngine.BulkRow] {
        var map: [UUID: DevEngine.BulkRow] = [:]
        for row in engine.bulk { map[row.id] = row }
        return map
    }

    private var visible: [Profile] {
        let filtered = store.profiles.filter { profile in
            let inFolder = folder == nil || (profile.group ?? ProfileStore.manualFolder) == folder
            guard inFolder else { return false }
            guard !query.isEmpty else { return true }
            return profile.name.localizedCaseInsensitiveContains(query)
                || (profile.badge ?? profile.kind.title).localizedCaseInsensitiveContains(query)
        }
        let map = rowsByID
        switch prefs.sortOrder {
        case .name:
            return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .kind:
            return filtered.sorted {
                ($0.badge ?? $0.kind.title).localizedCaseInsensitiveCompare($1.badge ?? $1.kind.title) == .orderedAscending
            }
        case .ping:
            return filtered.sorted { ping($0, map) < ping($1, map) }
        case .country:
            return filtered.sorted { country($0, map) < country($1, map) }
        }
    }

    /// Серверов в папке / сколько из них отвечает.
    private var counters: (all: Int, alive: Int) {
        let map = rowsByID
        let alive = visible.filter { map[$0.id]?.result?.ok == true }.count
        return (visible.count, alive)
    }

    var body: some View {
        NavigationView {
            List {
                connectionSection
                folderSection
                serverSection
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
        if engine.running { return "нажмите «пинг» у сервера, чтобы увидеть страну и задержку" }
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
                          bulk: rowsByID[profile.id],
                          busy: engine.bulkRunning) {
                    Task { await check(profile) }
                }
                .contentShape(Rectangle())
                .onTapGesture { store.select(profile.id) }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        store.delete(profile)
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                    Button {
                        store.select(profile.id)
                        Task { await toggle() }
                    } label: {
                        Label("Подключить", systemImage: "power")
                    }
                    .tint(.green)
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
                        Label("Пинг", systemImage: "waveform.path.ecg")
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
            HStack(spacing: 8) {
                Text(folder ?? "Все серверы")
                Text("\(counters.all)/\(counters.alive)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                if engine.bulkRunning {
                    ProgressView().scaleEffect(0.7)
                }
                HeaderButton(icon: "waveform.path.ecg", tint: Theme.accent) {
                    Task { await engine.checkAll(profiles: visible) }
                }
                .disabled(engine.bulkRunning || visible.isEmpty)
                HeaderButton(icon: "arrow.clockwise", tint: Theme.accent) {
                    Task { await refreshCurrent() }
                }
                .disabled(store.subscriptions.isEmpty || store.loading)
                Menu {
                    Picker("Сортировка", selection: $prefs.sortOrder) {
                        ForEach(Prefs.SortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.caption.weight(.semibold))
                        .frame(width: 26, height: 26)
                }
            }
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

    private func ping(_ profile: Profile, _ map: [UUID: DevEngine.BulkRow]) -> Int {
        map[profile.id]?.result?.millis ?? Int.max
    }

    private func country(_ profile: Profile, _ map: [UUID: DevEngine.BulkRow]) -> String {
        map[profile.id]?.result?.countryCode ?? "ZZ"
    }

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

    /// Обновляем подписку выбранной папки, а если выбрано «Все» — все подписки.
    private func refreshCurrent() async {
        if let name = folder, let subscription = store.subscriptions.first(where: { $0.name == name }) {
            await store.refresh(subscription)
        } else {
            await refreshAll()
        }
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
        if let result = rowsByID[profile.id]?.result {
            probeLine = result.summary
        }
    }

    /// Поделиться можно только тем профилем, у которого есть share-ссылка.
    private func shareLink(_ profile: Profile) -> String? {
        let text = profile.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.contains("://") ? text : nil
    }
}

/// Маленькая кнопка в заголовке секции: только иконка, чтобы не отнимать место у названия.
struct HeaderButton: View {
    let icon: String
    var tint: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundColor(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))
        }
        .buttonStyle(.borderless)
    }
}

/// Строка списка: имя сервера, протокол и кнопка пинга. Результат — только после нажатия.
struct ServerRow: View {
    let profile: Profile
    let selected: Bool
    let active: Bool
    let bulk: DevEngine.BulkRow?
    let busy: Bool
    let ping: () -> Void

    private var result: ProbeResult? { bulk?.result }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundColor(selected ? Theme.accent : Color(uiColor: .tertiaryLabel))
                .padding(.top, 3)

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

                HStack(spacing: 6) {
                    ProtocolBadge(text: profile.badge ?? profile.kind.title)
                    if let result {
                        Text(result.shortSummary)
                            .font(.caption2.weight(.medium))
                            .foregroundColor(result.ok ? Theme.pingColor(result.millis) : .red)
                            .lineLimit(1)
                    } else if let note = bulk?.note {
                        Text(note)
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .lineLimit(2)
                    }
                }
            }

            Spacer(minLength: 4)

            Button(action: ping) {
                VStack(spacing: 2) {
                    if let bulk, !bulk.done {
                        ProgressView().scaleEffect(0.6).frame(width: 30, height: 26)
                    } else {
                        Image(systemName: result == nil ? "waveform.path.ecg" : "arrow.clockwise")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Theme.accent)
                            .frame(width: 30, height: 26)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(uiColor: .tertiarySystemFill)))
                    }
                }
            }
            .buttonStyle(.borderless)
            .disabled(busy)
            .accessibilityLabel("Пинг")
        }
        .padding(.vertical, 5)
    }
}
