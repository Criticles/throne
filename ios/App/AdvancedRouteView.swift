import SwiftUI

/// Редактор профиля маршрутизации: упрощённый вид (четыре списка) и расширенный
/// (записи «атрибут → значение»). Атрибуты — полным списком, значения — отдельным экраном
/// с подсказками; снизу предпросмотр JSON профиля.
struct AdvancedRouteView: View {
    @EnvironmentObject private var rules: RuleStore
    @EnvironmentObject private var store: ProfileStore
    @Environment(\.presentationMode) private var presentation

    let planID: UUID

    @State private var name = ""
    @State private var finalTarget = "proxy"
    @State private var directList = ""
    @State private var proxyList = ""
    @State private var blockList = ""
    @State private var warpList = ""
    @State private var entries: [RoutePlanEntry] = []
    @State private var tab = 0
    @State private var loaded = false

    @State private var showAddEntry = false
    @State private var editingEntry: RoutePlanEntry?
    @State private var valueText = ""
    @State private var showPreview = false
    @State private var showExport = false

    private var targets: [String] {
        var list = ["proxy", "direct", "reject"]
        for profile in store.profiles where !list.contains(profile.name) {
            list.append(profile.name)
        }
        return list
    }

    private var plan: RoutePlan {
        RoutePlan(id: planID,
                  name: name,
                  finalTarget: finalTarget,
                  entries: entries,
                  directList: directList,
                  proxyList: proxyList,
                  blockList: blockList,
                  warpList: warpList)
    }

    var body: some View {
        Form {
            commonSection
            typeSection
            if tab == 0 {
                simplifiedSection
            } else {
                extendedSection
            }
            previewSection
        }
        .navigationTitle(name.isEmpty ? "Профиль" : name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить") { save() }
            }
        }
        .sheet(isPresented: $showAddEntry) {
            RouteAttributePicker { attr in
                add(attr)
            }
        }
        .sheet(item: $editingEntry) { entry in
            RouteValueView(attr: entry.attr,
                           targets: targets,
                           value: valueText) { updated in
                apply(updated, to: entry)
            }
        }
        .sheet(isPresented: $showPreview) {
            RouteJSONSheet(title: name, text: rules.planJSON(plan))
        }
        .sheet(isPresented: $showExport) {
            RouteExportView(plan: plan)
        }
        .onAppear(perform: load)
    }

    // MARK: - Секции

    private var commonSection: some View {
        Section {
            TextField("Название профиля", text: $name)
            Picker("Общий outbound", selection: $finalTarget) {
                ForEach(targets, id: \.self) { target in
                    Text(target).tag(target)
                }
            }
        } header: {
            Text("Основное")
        } footer: {
            Text("Сюда идёт всё, что не поймала ни одна запись: proxy — выбранный сервер, direct — напрямую, reject — блокировать.")
        }
    }

    private var typeSection: some View {
        Section {
            Picker("Вид", selection: $tab) {
                Text("Упрощённая").tag(0)
                Text("Расширенная").tag(1)
            }
            .pickerStyle(.segmented)
        }
    }

    private var simplifiedSection: some View {
        Section {
            domainEditor(title: "Напрямую", text: $directList, hint: "по строке: geosite:ru, domain:example.com")
            domainEditor(title: "Прокси", text: $proxyList, hint: "что всегда через VPN")
            domainEditor(title: "Блокировать", text: $blockList, hint: "реклама и трекеры")
            domainEditor(title: "WARP-bypass", text: $warpList, hint: "сервисы, которым нужен WARP")
        } header: {
            Text("Списки")
        } footer: {
            Text("По одному правилу в строке. Поддерживается geosite:, geoip:, domain:, suffix:, keyword:, ip_cidr:.")
        }
    }

    private var extendedSection: some View {
        Section {
            ForEach(entries) { entry in
                entryRow(entry)
            }
            .onDelete { offsets in
                entries.remove(atOffsets: offsets)
            }

            Button {
                showAddEntry = true
            } label: {
                Label("Добавить запись", systemImage: "plus.circle")
            }
        } header: {
            Text("Записи по порядку")
        } footer: {
            Text("Срабатывает первая подходящая запись. Нажмите на название атрибута, чтобы вписать значение; «Выбрать» — готовые варианты.")
        }
    }

    private var previewSection: some View {
        Section {
            Button {
                showPreview = true
            } label: {
                Label("Предварительный просмотр JSON", systemImage: "curlybraces")
            }
            Button {
                showExport = true
            } label: {
                Label("Экспорт (JSON или Throne)", systemImage: "square.and.arrow.up")
            }
        } footer: {
            Text(rules.status.isEmpty
                 ? "Предпросмотр показывает ровно тот JSON, который уйдёт при экспорте."
                 : rules.status)
        }
    }

    // MARK: - Строка записи

    private func entryRow(_ entry: RoutePlanEntry) -> some View {
        HStack(spacing: 8) {
            Button {
                valueText = entry.value
                editingEntry = entry
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.attr)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.accent)
                    Text(RouteAttribute.displayValue(entry.value))
                        .font(.caption2)
                        .foregroundColor(entry.value.isEmpty ? .red : .secondary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.borderless)

            Spacer(minLength: 4)

            if entry.kind == "rule" {
                Menu {
                    ForEach(targets, id: \.self) { target in
                        Button(target) { setTarget(target, entry) }
                    }
                } label: {
                    Text(entry.target ?? "proxy")
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(Theme.accent)
                }
            }

            if RouteAttribute.needsChoice(entry.attr) {
                Button("Выбрать") {
                    valueText = entry.value
                    editingEntry = entry
                }
                .font(.caption2.weight(.medium))
                .buttonStyle(.borderless)
            }

            Button {
                entries.removeAll { $0.id == entry.id }
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private func domainEditor(title: String, text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundColor(.secondary)
            TextEditor(text: text)
                .frame(height: 76)
                .font(.system(.caption2, design: .monospaced))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color(uiColor: .separator), lineWidth: 0.5)
                )
            Text(hint).font(.caption2).foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Действия

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let stored = rules.plan(with: planID) else { return }
        name = stored.name
        finalTarget = stored.finalTarget
        directList = stored.directList
        proxyList = stored.proxyList
        blockList = stored.blockList
        warpList = stored.warpList
        entries = stored.entries
    }

    private func add(_ attr: String) {
        let entry = RoutePlanEntry(kind: attr == "outbound" ? "outbound" : "rule",
                                   attr: attr,
                                   value: attr == "outbound" ? "proxy" : "")
        entries.append(entry)
        valueText = entry.value
        // Сразу открываем значение: лишний тап по только что добавленной записи не нужен.
        // Небольшая задержка — список атрибутов должен успеть закрыться.
        let id = entry.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            if let created = entries.first(where: { $0.id == id }) {
                editingEntry = created
            }
        }
    }

    private func apply(_ updated: String, to entry: RoutePlanEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].value = updated
    }

    private func setTarget(_ target: String, _ entry: RoutePlanEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].target = target
    }

    private func save() {
        rules.savePlan(plan)
        presentation.wrappedValue.dismiss()
    }
}

/// Полный список атрибутов — открывается сразу по «Добавить запись».
struct RouteAttributePicker: View {
    @Environment(\.presentationMode) private var presentation
    @State private var query = ""

    let onPick: (String) -> Void

    private var attributes: [String] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return RouteAttribute.all }
        return RouteAttribute.all.filter { $0.contains(text) }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        onPick("outbound")
                        presentation.wrappedValue.dismiss()
                    } label: {
                        HStack {
                            Text("outbound").font(.subheadline.weight(.medium))
                            Spacer()
                            Text("куда направить").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                } header: {
                    Text("Принудительный outbound")
                }

                Section {
                    ForEach(attributes, id: \.self) { attr in
                        Button {
                            onPick(attr)
                            presentation.wrappedValue.dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(attr).font(.subheadline).foregroundColor(.primary)
                                    if RouteAttribute.needsChoice(attr) {
                                        Image(systemName: "list.bullet")
                                            .font(.caption2)
                                            .foregroundColor(Theme.accent)
                                    }
                                }
                                Text(RouteAttribute.hint(attr))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Атрибуты")
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Атрибут")
            .navigationTitle("Атрибут")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { presentation.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// Экран значения атрибута: поле ввода с подсказками и, если надо, готовые варианты.
struct RouteValueView: View {
    @Environment(\.presentationMode) private var presentation

    let attr: String
    let targets: [String]
    @State private var text: String
    let onDone: (String) -> Void

    init(attr: String, targets: [String], value: String, onDone: @escaping (String) -> Void) {
        self.attr = attr
        self.targets = targets
        _text = State(initialValue: value)
        self.onDone = onDone
    }

    private var options: [String] {
        if attr == "outbound" { return targets }
        return RouteAttribute.options(attr)
    }

    private var filtered: [String] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return options }
        return options.filter { $0.lowercased().contains(query) }
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Значение", text: $text)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.footnote, design: .monospaced))
                    if options.isEmpty {
                        Text(RouteAttribute.hint(attr))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text(attr)
                }

                if !filtered.isEmpty {
                    Section {
                        ForEach(filtered.prefix(40), id: \.self) { option in
                            Button {
                                text = option
                            } label: {
                                HStack {
                                    Text(option)
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundColor(.primary)
                                    Spacer()
                                    if option == text {
                                        Image(systemName: "checkmark")
                                            .font(.caption)
                                            .foregroundColor(Theme.accent)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Выбрать")
                    } footer: {
                        Text("Можно вписать своё значение — список только подсказывает.")
                    }
                }
            }
            .navigationTitle(attr)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { presentation.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        onDone(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        presentation.wrappedValue.dismiss()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// Предпросмотр JSON профиля: тот же текст, что при экспорте.
struct RouteJSONSheet: View {
    @Environment(\.presentationMode) private var presentation

    let title: String
    let text: String

    var body: some View {
        NavigationView {
            ScrollView {
                Text(text)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { presentation.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
