import SwiftUI

/// Главный экран: подключение, быстрый сервер, папки и список серверов.
struct ProfilesView: View {
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var engine: DevEngine
    @EnvironmentObject private var prefs: Prefs
    @EnvironmentObject private var traffic: TrafficMonitor

    @State private var folderID: UUID? = nil
    @State private var query = ""
    @State private var probeLine = ""
    /// Один лист на экран: iOS 15 держит только последний `.sheet` из цепочки, остальные
    /// молча не открываются.
    private enum Sheet: Identifiable {
        case add, scanner, subscriptions, log, newFolder
        case qr(Profile), note(Profile), details(Profile)

        var id: String {
            switch self {
            case .add: return "add"
            case .scanner: return "scanner"
            case .subscriptions: return "subscriptions"
            case .log: return "log"
            case .newFolder: return "newFolder"
            case .qr(let profile): return "qr-\(profile.id.uuidString)"
            case .note(let profile): return "note-\(profile.id.uuidString)"
            case .details(let profile): return "details-\(profile.id.uuidString)"
            }
        }
    }

    @State private var sheet: Sheet?
    @State private var addText = ""
    @State private var addTitle = ""
    @State private var createFolder = true
    @State private var noteText = ""
    @State private var folderName = ""
    /// Куда класть новую подписку, когда выбрано «в существующую папку».
    @State private var targetFolderID: UUID?

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
            let inFolder = folderID == nil || profile.folderID == folderID
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

    /// Один размер шрифта на все названия сразу.
    ///
    /// Если самое длинное название не помещается в строку, уменьшаем шрифт у всего списка —
    /// иначе названия в соседних строках выглядят по-разному. Считаем по реальной ширине
    /// текста, а не по числу символов: кириллица и эмодзи флагов меряются по-разному.
    private var nameFontSize: CGFloat {
        let base: CGFloat = 15
        // Экран минус отступы строки (16+16), кружок выбора (18), отступы HStack и колонка пинга.
        let available = UIScreen.main.bounds.width - 32 - 18 - 10 - 6 - ServerRow.pillWidth
        guard available > 60 else { return base }
        let font = UIFont.systemFont(ofSize: base, weight: .medium)
        var needed = base
        for profile in visible {
            let width = (profile.name as NSString).size(withAttributes: [.font: font]).width
            guard width > available else { continue }
            needed = min(needed, base * available / width)
        }
        // Ниже 12,5 pt текст перестаёт читаться, поэтому дальше не уменьшаем: слишком длинное
        // имя обрезается многоточием (одна строка), а целиком видно в подробностях по долгому нажатию.
        return max(12.5, (needed * 10).rounded(.down) / 10)
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
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Сервер или протокол")
            .navigationTitle("Серверы")
            .toolbar { toolbarContent }
            .sheet(item: $sheet) { item in
                switch item {
                case .add:
                    addSheet
                case .newFolder:
                    newFolderSheet
                case .scanner:
                    scannerSheet
                case .subscriptions:
                    SubscriptionEditorView()
                case .log:
                    NavigationView { LogsView() }
                case .qr(let profile):
                    QRCodeSheet(title: "QR сервера", text: shareLink(profile) ?? profile.payload)
                case .note(let profile):
                    noteSheet(for: profile)
                case .details(let profile):
                    ServerDetailsView(profile: profile)
                }
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
                    Button("Журнал") { sheet = .log }
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
        return "нет соединения"
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
                    FolderChip(title: "Все", count: store.profiles.count, selected: folderID == nil) {
                        folderID = nil
                    }
                    ForEach(store.folders) { item in
                        FolderChip(title: item.name,
                                   count: store.count(in: item.id),
                                   selected: folderID == item.id) {
                            folderID = item.id
                        }
                    }
                    Button {
                        folderName = ""
                        sheet = .newFolder
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Theme.accent)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
                .padding(.horizontal, 2)
            }
            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    /// Что показать вместо пустого списка: пустая папка, пустой поиск или вообще нет серверов.
    private var emptyText: String {
        if store.profiles.isEmpty { return "пока пусто — нажмите + сверху" }
        if let folderID, store.count(in: folderID) == 0 {
            return store.subscription(in: folderID) == nil
                ? "в этой папке пока нет серверов — добавьте их при импорте подписки"
                : "папка пустая — обновите подписку кнопкой ↻ в заголовке"
        }
        return "в этой папке ничего не нашлось"
    }

    private var serverSection: some View {
        Section {
            if visible.isEmpty {
                Text(emptyText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(visible) { profile in
                row(profile)
            }
        } header: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(folderID == nil ? "Все серверы" : store.folderName(folderID))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(String(visible.count) + "/" + String(aliveCount))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 4)
                    if engine.bulkRunning || engine.speedRunning != nil {
                        HeaderButton(icon: "xmark", tint: .red) {
                            engine.cancelMeasurements()
                            traffic.stop()
                            probeLine = ""
                        }
                    } else {
                        HeaderButton(icon: "speedometer", tint: Theme.accent) {
                            speedAll()
                        }
                        .disabled(visible.isEmpty)
                        HeaderButton(icon: "waveform.path.ecg", tint: Theme.accent) {
                            checkAll()
                        }
                        .disabled(visible.isEmpty)
                    }
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
                  nameSize: nameFontSize,
                  onPing: { engine.runCheck(profile: profile) })
            // Строка во всю ширину телефона: без отступов карточки, как в настройках iOS.
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
            .contentShape(Rectangle())
            .onTapGesture { store.select(profile.id) }
            .onLongPressGesture { sheet = .details(profile) }
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
                Button { sheet = .details(profile) } label: {
                    Label("Сведения", systemImage: "info.circle")
                }
                Button { Task { await connect(profile) } } label: {
                    Label("Подключиться", systemImage: "power")
                }
                Button { engine.runCheck(profile: profile) } label: {
                    Label("Пинг", systemImage: "waveform.path.ecg")
                }
                Button { engine.runSpeedAll(profiles: [profile]) } label: {
                    Label("Скорость", systemImage: "speedometer")
                }
                Button { store.toggleFavorite(profile) } label: {
                    Label(profile.favorite ? "Убрать из избранного" : "В избранное",
                          systemImage: profile.favorite ? "star.slash" : "star")
                }
                Button {
                    noteText = profile.userNote ?? ""
                    sheet = .note(profile)
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
                    Button { sheet = .qr(profile) } label: {
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
            Button("Изм") { sheet = .subscriptions }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Menu {
                Button {
                    addText = ""
                    addTitle = ""
                    targetFolderID = folderID
                    createFolder = true
                    sheet = .add
                } label: {
                    Label("Подписка по ссылке", systemImage: "link")
                }
                Button { importClipboard() } label: {
                    Label("Импорт из буфера", systemImage: "doc.on.clipboard")
                }
                Button { sheet = .scanner } label: {
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
                    folderID = nil
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
                }
                Section {
                    Picker("Куда добавить", selection: $createFolder) {
                        Text("Новая папка").tag(true)
                        Text("В существующую").tag(false)
                    }
                    .pickerStyle(.segmented)
                    if createFolder {
                        TextField("Имя папки", text: $addTitle)
                        if !addText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("По умолчанию: " + ProfileStore.folderName(for: addText))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Picker("Папка", selection: $targetFolderID) {
                            ForEach(store.folders) { item in
                                Text(item.name + " · " + String(store.count(in: item.id))).tag(Optional(item.id))
                            }
                        }
                    }
                } footer: {
                    Text(createFolder
                         ? "Серверы лягут в свою новую папку — имя можно изменить. Одну и ту же подписку можно добавить сколько угодно раз: папки не сольются, даже если назвать их одинаково."
                         : "Серверы добавятся в выбранную папку рядом с теми, что там уже есть.")
                }
                Section {
                    Button("Взять из буфера обмена") {
                        let text = (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty { addText = text }
                    }
                }
            }
            .navigationTitle("Новая подписка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { sheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") { addSubscription() }
                        .disabled(addText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    /// Своя пустая папка: серверы можно добавить в неё потом, а имя поменять в «Изм.».
    private var newFolderSheet: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Название папки", text: $folderName)
                } footer: {
                    Text("Одинаковые названия разрешены: папки различаются внутренне. Переименовать можно в «Изм.».")
                }
            }
            .navigationTitle("Новая папка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { sheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        let created = store.addFolder(name: folderName)
                        sheet = nil
                        folderID = created.id
                    }
                    .disabled(folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var scannerSheet: some View {
        NavigationView {
            QRScannerView { code in
                sheet = nil
                // Тот же лист с выбором папки, что и для ссылки: скрытого создания нет.
                addText = code
                addTitle = ""
                targetFolderID = store.lastFolderID
                createFolder = true
                // Сканер закрылся — лист выбора папки открываем после закрытия.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    sheet = .add
                }
            }
            .ignoresSafeArea()
            .navigationTitle("Наведите камеру на QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { sheet = nil }
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
                    Button("Отмена") { sheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        store.setNote(noteText, for: profile)
                        sheet = nil
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
        let typed = addTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        let target: UUID
        if createFolder {
            // Пустое имя — имя хоста панели; занятое имя не правим: одинаковые папки разрешены.
            let base = typed.isEmpty ? ProfileStore.folderName(for: input) : typed
            target = store.addFolder(name: base).id
        } else if let existing = targetFolderID ?? store.lastFolderID {
            target = existing
        } else {
            // Папок нет вовсе — первый импорт создаёт одну по имени подписки.
            target = store.addFolder(name: ProfileStore.folderName(for: input)).id
        }
        store.rememberFolder(target)
        sheet = nil
        folderID = target
        Task {
            if input.lowercased().hasPrefix("http") {
                await store.importFromURL(input, folderID: target)
            } else {
                store.importFromText(input, folderID: target)
            }
        }
    }

    /// Всё добавление идёт через лист с выбором папки: буфер и QR только заполняют его.
    private func importClipboard() {
        let text = (UIPasteboard.general.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        addTitle = ""
        targetFolderID = store.lastFolderID
        createFolder = true
        // iOS на первом обращении показывает «Разрешить вставку» и отдаёт пустую строку:
        // тогда открываем лист и просим нажать «Взять из буфера обмена» внутри него.
        if text.isEmpty {
            addText = ""
            probeLine = "буфер не отдался — нажмите «Взять из буфера обмена» в открывшемся окне"
        } else {
            addText = text
        }
        sheet = .add
    }

    private func refreshCurrent() async {
        if let folderID, let subscription = store.subscription(in: folderID) {
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

    private func checkAll() {
        engine.runCheckAll(profiles: visible) { [engine, store, prefs] in
            guard prefs.autoFastest else { return }
            var best: (id: UUID, millis: Int)?
            for row in engine.bulk {
                guard row.result?.ok == true, let millis = row.result?.millis else { continue }
                if best == nil || millis < best!.millis { best = (row.id, millis) }
            }
            if let best { store.select(best.id) }
        }
    }

    /// Тест скорости по всем серверам папки — по очереди, каждый требует своего туннеля.
    private func speedAll() {
        engine.runSpeedAll(profiles: visible)
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

/// Строка списка из трёх строк: название, бейдж протокола, флаг страны и выходной IP.
/// Справа — «Пинг»: после замера на его месте цифра (нажатие повторяет тест),
/// после теста скорости она поднимается, а под ней появляется скорость.
struct ServerRow: View {
    let profile: Profile
    let selected: Bool
    let bulk: DevEngine.BulkRow?
    let speed: DevEngine.SpeedResult?
    let busy: Bool
    /// Размер шрифта названия — общий для всего списка (считается в ProfilesView).
    let nameSize: CGFloat
    let onPing: () -> Void

    /// Плашка «Пинг» и результат замера — один и тот же размер: иначе строка «дёргается».
    static let pillWidth: CGFloat = 68
    static let pillHeight: CGFloat = 24

    private var result: ProbeResult? { bulk?.result }
    /// Идёт замер именно этого сервера: строка показывает кружок вместо «Пинг».
    private var checking: Bool { bulk != nil && bulk?.done == false }
    private var millis: Int? { result?.ok == true ? result?.millis : nil }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundColor(selected ? Theme.accent : Color(uiColor: .tertiaryLabel))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(profile.name)
                        .font(.system(size: nameSize, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
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

                // Третья строка появляется только по результатам пинга: флаг и страна.
                if let result {
                    Text(result.countryLine ?? ProbeResult.unavailable)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(result.ok ? .secondary : .red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 4) {
                pingControl
                if let speed {
                    Text(String(format: "↓ %.1f · ↑ %.1f", speed.downMbps, speed.upMbps))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.green)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(width: Self.pillWidth, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var pingControl: some View {
        if checking {
            ProgressView()
                .scaleEffect(0.7)
                .frame(width: Self.pillWidth, height: Self.pillHeight)
        } else if let millis {
            Button(action: onPing) {
                Text("\(millis) мс")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.pingColor(millis))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    // Размер плашки один и тот же у «Пинг» и у результата.
                    .frame(width: Self.pillWidth, height: Self.pillHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.pingColor(millis).opacity(0.12))
                    )
            }
            .buttonStyle(.borderless)
            .disabled(busy)
        } else {
            Button(action: onPing) {
                Text("Пинг")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.accent)
                    .lineLimit(1)
                    .frame(width: Self.pillWidth, height: Self.pillHeight)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.accent.opacity(0.12))
                    )
            }
            .buttonStyle(.borderless)
            .disabled(busy)
        }
    }
}
