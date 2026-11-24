import SwiftUI

/// Главный экран: подключение, быстрый сервер, папки и список серверов.
struct ProfilesView: View {
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var engine: DevEngine
    @EnvironmentObject private var prefs: Prefs
    @EnvironmentObject private var traffic: TrafficMonitor

    @State private var folder: String? = nil
    @State private var query = ""
    @State private var probeLine = ""
    @State private var showAdd = false
    @State private var addText = ""
    @State private var addTitle = ""
    @State private var showScanner = false
    @State private var qrProfile: Profile?
    @State private var noteProfile: Profile?
    @State private var noteText = ""
    @State private var detailsProfile: Profile?
    @State private var showSubscriptions = false
    @State private var showLog = false

    @StateObject private var stats = TrafficStatsStore.shared

    // MARK: - Данные

    private var rowsByID: [UUID: DevEngine.BulkRow] {
        var map: [UUID: DevEngine.BulkRow] = [:]
        for row in engine.bulk { map[row.id] = row }
        return map
    }

    private var visible: [Profile] {
        var filtered: [Profile] = []
        for profile in store.profiles {
            let inFolder = folder == nil || (profile.group ?? ProfileStore.manualFolder) == folder
            guard inFolder else { continue }
            if query.isEmpty {
                filtered.append(profile)
            } else if profile.name.localizedCaseInsensitiveContains(query)
                        || (profile.badge ?? profile.kind.title).localizedCaseInsensitiveContains(query) {
                filtered.append(profile)
            }
        }
        let map = rowsByID
        var ordered = filtered
        switch prefs.sortOrder {
        case .name:
            ordered.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .kind:
            ordered.sort {
                ($0.badge ?? $0.kind.title).localizedCaseInsensitiveCompare($1.badge ?? $1.kind.title) == .orderedAscending
            }
        case .ping:
            ordered.sort { ping($0, map) < ping($1, map) }
        case .country:
            ordered.sort { country($0, map) < country($1, map) }
        }
        if prefs.favoriteFirst {
            ordered.sort { $0.favorite && !$1.favorite }
        }
        return ordered
    }

    private var aliveCount: Int {
        let map = rowsByID
        var count = 0
        for profile in visible where map[profile.id]?.result?.ok == true { count += 1 }
        return count
    }

    private var fastest: Profile? {
        var best: Profile?
        var bestMillis = Int.max
        let map = rowsByID
        for profile in visible {
            guard let millis = map[profile.id]?.result?.millis else { continue }
            if millis < bestMillis {
                bestMillis = millis
                best = profile
            }
        }
        return best
    }

    private var activeRow: DevEngine.BulkRow? {
        guard let id = store.selectedID else { return nil }
        return rowsByID[id]
    }

    private var selectedTraffic: (up: Int64, down: Int64) {
        guard let selected = store.selected else { return (0, 0) }
        return stats.total(profile: selected.name)
    }

    var body: some View {
        NavigationView {
            List {
                connectionSection
                fastestSection
                folderSection
                serverSection
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Сервер или протокол")
            .navigationTitle("Серверы")
            .toolbar { toolbarContent }
            .sheet(isPresented: $showAdd) { addSheet }
            .sheet(isPresented: $showScanner) { scannerSheet }
            .sheet(isPresented: $showSubscriptions) { SubscriptionEditorView() }
            .sheet(isPresented: $showLog) { NavigationView { LogsView() } }
            .sheet(item: $qrProfile) { profile in
                QRCodeSheet(title: "QR сервера", text: shareLink(profile) ?? profile.payload)
            }
            .sheet(item: $noteProfile) { profile in
                noteSheet(for: profile)
            }
            .sheet(item: $detailsProfile) { profile in
                ServerDetailsView(profile: profile)
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Подключение

    private var connectionSection: some View {
        Section {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.selected?.name ?? "Не подключено")
                        .font(.headline)
                        .lineLimit(2)
                    if let profile = store.selected {
                        ProtocolBadge(text: profile.badge ?? profile.kind.title)
                    }
                    Text(connectionLine)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Text("↑ " + Self.size(selectedTraffic.up) + " · ↓ " + Self.size(selectedTraffic.down)
                         + (engine.running ? " · " + Self.duration(engine.uptime) : ""))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 0)
                PowerButton(on: engine.running, busy: engine.bulkRunning) {
                    Task { await toggle() }
                }
                .disabled(engine.bulkRunning)
            }
            .padding(.vertical, 6)

            if let error = engine.lastError, !engine.running, !error.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                    Spacer(minLength: 0)
                    Button("Журнал") { showLog = true }
                        .font(.caption)
                }
            }
        }
    }

    /// Пинг и страна активного сервера вместо «Подключено».
    private var connectionLine: String {
        if !probeLine.isEmpty { return probeLine }
        if let result = activeRow?.result, result.ok {
            let country = Probe.countryName(code: result.countryCode, fallback: result.country) ?? ""
            let millis = result.millis.map { String($0) + " мс" } ?? ""
            let ip = result.ip ?? ""
            return [country, ip, millis].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if engine.running { return "нажмите «Пинг», чтобы узнать страну и задержку" }
        return "не подключено"
    }

    // MARK: - Быстрый сервер

    private var fastestSection: some View {
        Section {
            if let fastest, let result = rowsByID[fastest.id]?.result, result.ok {
                VStack(alignment: .leading, spacing: 7) {
                    Button {
                        Task { await connect(fastest) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "bolt.horizontal.circle.fill")
                            Text("Подключиться к быстрому").font(.subheadline.weight(.semibold))
                            Spacer()
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent))
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 6) {
                        Text(fastest.name).font(.caption.weight(.medium)).lineLimit(1)
                        ProtocolBadge(text: fastest.badge ?? fastest.kind.title)
                    }
                    HStack(spacing: 6) {
                        Text(Probe.countryName(code: result.countryCode, fallback: result.country) ?? "—")
                            .font(.caption2)
                        Text((result.millis.map { String($0) + " мс" } ?? ""))
                            .font(.caption2.weight(.medium))
                            .foregroundColor(Theme.pingColor(result.millis))
                    }
                }
                .padding(.vertical, 2)
            } else {
                Text("быстрый сервер появится после проверки — нажмите «Пинг всех»")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Папки и кнопки

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

    private var controlsSection: some View {
        Section {
            HStack(spacing: 8) {
                PlaqueButton(title: "Пинг всех", icon: "waveform.path.ecg") {
                    Task { await checkAll() }
                }
                .disabled(engine.bulkRunning || visible.isEmpty)

                PlaqueButton(title: "Скорость", icon: "speedometer") {
                    Task { await speedAll() }
                }
                .disabled(engine.bulkRunning || engine.speedRunning != nil || visible.isEmpty)

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

                Spacer()

                if engine.bulkRunning || engine.speedRunning != nil {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Text(String(visible.count) + "/" + String(aliveCount))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } footer: {
            Text("Трафик за всё время: ↑ " + Self.size(selectedTraffic.up) + " · ↓ " + Self.size(selectedTraffic.down))
        }
    }

    private var serverSection: some View {
        Section {
            if visible.isEmpty {
                Text(store.profiles.isEmpty
                     ? "пока пусто — нажмите + сверху"
                     : "в этой папке ничего не нашлось")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(visible) { profile in
                row(profile)
            }
        } header: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(folder ?? "Все серверы")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(String(visible.count) + "/" + String(aliveCount))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 4)
                    HeaderButton(icon: "xmark", tint: .secondary) {
                        engine.stop()
                        traffic.stop()
                        probeLine = ""
                    }
                    .disabled(!engine.running && !engine.bulkRunning && engine.speedRunning == nil)
                    HeaderButton(icon: "waveform.path.ecg", tint: Theme.accent) {
                        Task { await checkAll() }
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
                Text("Трафик за всё время: ↑ " + Self.size(selectedTraffic.up) + " · ↓ " + Self.size(selectedTraffic.down))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func row(_ profile: Profile) -> some View {
        ServerRow(profile: profile,
                  selected: store.selectedID == profile.id,
                  bulk: rowsByID[profile.id],
                  speed: engine.speed[profile.id],
                  busy: engine.bulkRunning || engine.speedRunning != nil,
                  onPing: { Task { await engine.check(profile: profile) } })
            .contentShape(Rectangle())
            .onTapGesture { store.select(profile.id) }
            .onLongPressGesture { detailsProfile = profile }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button(role: .destructive) {
                    store.delete(profile)
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
                Button {
                    Task { await connect(profile) }
                } label: {
                    Label("Подключить", systemImage: "power")
                }
                .tint(.green)
            }
            .swipeActions(edge: .leading) {
                Button {
                    store.toggleFavorite(profile)
                } label: {
                    Label(profile.favorite ? "Убрать" : "В избранное", systemImage: "star")
                }
                .tint(.yellow)
            }
            .contextMenu {
                Button { detailsProfile = profile } label: {
                    Label("Сведения", systemImage: "info.circle")
                }
                Button { Task { await connect(profile) } } label: {
                    Label("Подключиться", systemImage: "power")
                }
                Button { Task { await engine.check(profile: profile) } } label: {
                    Label("Пинг", systemImage: "waveform.path.ecg")
                }
                Button { Task { await engine.measureSpeed(profile: profile) } } label: {
                    Label("Скорость", systemImage: "speedometer")
                }
                Button { store.toggleFavorite(profile) } label: {
                    Label(profile.favorite ? "Убрать из избранного" : "В избранное",
                          systemImage: profile.favorite ? "star.slash" : "star")
                }
                Button {
                    noteText = profile.userNote ?? ""
                    noteProfile = profile
                } label: {
                    Label(profile.userNote == nil ? "Добавить заметку" : "Изменить заметку",
                          systemImage: "text.bubble")
                }
                if shareLink(profile) != nil {
                    Button { UIPasteboard.general.string = shareLink(profile) } label: {
                        Label("Скопировать ссылку", systemImage: "doc.on.doc")
                    }
                    Button { UIPasteboard.general.string = deepLink(for: profile) } label: {
                        Label("Скопировать для Throne", systemImage: "link.badge.plus")
                    }
                    Button { qrProfile = profile } label: {
                        Label("Показать QR", systemImage: "qrcode")
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

    // MARK: - Тулбар

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button("Изм") { showSubscriptions = true }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button { addText = ""; addTitle = ""; showAdd = true } label: {
                    Label("Подписка по ссылке", systemImage: "link")
                }
                Button { importClipboard() } label: {
                    Label("Импорт из буфера", systemImage: "doc.on.clipboard")
                }
                Button { showScanner = true } label: {
                    Label("Сканировать QR", systemImage: "qrcode.viewfinder")
                }
                if !store.subscriptions.isEmpty {
                    Divider()
                    Button { Task { await refreshAll() } } label: {
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

    // MARK: - Шторки

    private var addSheet: some View {
        NavigationView {
            Form {
                Section {
                    TextField("https://…/sub/<токен>", text: $addText)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                    TextField("Имя папки", text: $addTitle)
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

    private var scannerSheet: some View {
        NavigationView {
            QRScannerView { code in
                showScanner = false
                Task { await store.importAny(code) }
            }
            .ignoresSafeArea()
            .navigationTitle("Наведите камеру на QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { showScanner = false }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func noteSheet(for profile: Profile) -> some View {
        NavigationView {
            Form {
                Section {
                    TextEditor(text: $noteText).frame(minHeight: 120)
                }
            }
            .navigationTitle("Заметка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { noteProfile = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        store.setNote(noteText, for: profile)
                        noteProfile = nil
                    }
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

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func duration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let hours = minutes / 60
        if hours > 0 { return String(hours) + " ч " + String(minutes % 60) + " мин" }
        if minutes > 0 { return String(minutes) + " мин" }
        return String(seconds) + " с"
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

    private func connect(_ profile: Profile) async {
        store.select(profile.id)
        engine.start(profile: profile, pool: store.profiles)
        if engine.running, !engine.transportOnly {
            traffic.start(profile: profile.name)
            probeLine = "определяю выход…"
            await engine.probeActive(profile: profile)
            probeLine = ""
        } else {
            probeLine = engine.lastError ?? ""
        }
    }

    private func toggle() async {
        if engine.running {
            engine.stop()
            traffic.stop()
            probeLine = ""
            return
        }
        guard let profile = store.selected else {
            probeLine = "сначала выберите сервер"
            return
        }
        await connect(profile)
    }

    private func checkAll() async {
        await engine.checkAll(profiles: visible)
        guard prefs.autoFastest, let fastest else { return }
        store.select(fastest.id)
    }

    /// Тест скорости по всем серверам папки — по очереди, каждый требует своего туннеля.
    private func speedAll() async {
        for profile in visible {
            await engine.measureSpeed(profile: profile)
        }
    }

    private func shareLink(_ profile: Profile) -> String? {
        let text = profile.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.contains("://") ? text : nil
    }

    private func deepLink(for profile: Profile) -> String {
        let link = shareLink(profile) ?? profile.payload
        let encoded = link.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? link
        return "throne://import?url=" + encoded
    }
}

/// Строка списка: название, бейдж протокола и пинг с результатом.
struct ServerRow: View {
    let profile: Profile
    let selected: Bool
    let bulk: DevEngine.BulkRow?
    let speed: DevEngine.SpeedResult?
    let busy: Bool
    let onPing: () -> Void

    private var result: ProbeResult? { bulk?.result }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundColor(selected ? Theme.accent : Color(uiColor: .tertiaryLabel))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.subheadline.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if profile.favorite {
                        Image(systemName: "star.fill").font(.caption2).foregroundColor(.yellow)
                    }
                }

                HStack(spacing: 6) {
                    ProtocolBadge(text: profile.badge ?? profile.kind.title)
                    if let note = profile.userNote {
                        Text(note).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    }
                }

                HStack(spacing: 8) {
                    PlaqueButton(title: "Пинг", icon: "waveform.path.ecg", action: onPing)
                    if let result {
                        Text(result.shortSummary)
                            .font(.caption2.weight(.medium))
                            .foregroundColor(result.ok ? Theme.pingColor(result.millis) : .red)
                            .lineLimit(1)
                    } else if let ip = bulk?.result?.ip {
                        Text(ip).font(.caption2).foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .disabled(busy)

                if let speed {
                    Text(String(format: "↓ %.1f · ↑ %.1f Мбит/с", speed.downMbps, speed.upMbps))
                        .font(.caption2)
                        .foregroundColor(.green)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
