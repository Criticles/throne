import SwiftUI

/// Редактор профиля маршрутизации: упрощённый вид (четыре списка) и расширенный.
///
/// Расширенный вид устроен как в настольном Throne: сначала создаётся **папка с атрибутами**
/// (у неё есть название, действие и outbound), а внутри неё уже лежат атрибуты со значениями.
/// Порядок папок = порядок применения: первая сверху сработает первой.
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
    @State private var folders: [RoutePlanRule] = []
    @State private var tab = 0
    @State private var loaded = false

    @State private var editingRule: RoutePlanRule?
    @State private var showNewRule = false
    @State private var newRuleName = ""
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
                  rules: folders,
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
        .sheet(item: $editingRule) { rule in
            RouteRuleEditorView(rule: rule, targets: targets) { updated in
                if let index = folders.firstIndex(where: { $0.id == updated.id }) {
                    folders[index] = updated
                }
            }
        }
        .sheet(isPresented: $showNewRule) {
            newRuleSheet
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
            Text("Сюда идёт всё, что не поймала ни одна папка: proxy — выбранный сервер, direct — напрямую, reject — блокировать.")
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
            ForEach(folders) { rule in
                folderRow(rule)
            }
            .onMove { source, destination in
                folders.move(fromOffsets: source, toOffset: destination)
            }
            .onDelete { offsets in
                folders.remove(atOffsets: offsets)
            }

            Button {
                newRuleName = ""
                showNewRule = true
            } label: {
                Label("Добавить папку с атрибутами", systemImage: "folder.badge.plus")
            }
        } header: {
            Text("Папки с атрибутами")
        } footer: {
            Text("Первая папка сверху срабатывает первой. Внутри папки — атрибуты, а «куда пускать» задаётся один раз для всей папки.")
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

    // MARK: - Строка папки

    private func folderRow(_ rule: RoutePlanRule) -> some View {
        HStack(spacing: 8) {
            Button {
                editingRule = rule
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(rule.name.isEmpty ? "Папка" : rule.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text(rule.subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    moveRule(rule, by: -1)
                } label: {
                    Label("Выше", systemImage: "arrow.up")
                }
                .disabled(folders.first?.id == rule.id)
                Button {
                    moveRule(rule, by: 1)
                } label: {
                    Label("Ниже", systemImage: "arrow.down")
                }
                .disabled(folders.last?.id == rule.id)
                Button(role: .destructive) {
                    folders.removeAll { $0.id == rule.id }
                } label: {
                    Label("Удалить папку", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private var newRuleSheet: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Название папки", text: $newRuleName)
                } footer: {
                    Text("Например: «Блок рекламы» или «YouTube через proxy». Атрибуты добавляются внутри папки — после создания.")
                }
            }
            .navigationTitle("Новая папка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { showNewRule = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        let created = RoutePlanRule(name: newRuleName.trimmingCharacters(in: .whitespacesAndNewlines))
                        folders.append(created)
                        showNewRule = false
                        editingRule = created
                    }
                    .disabled(newRuleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
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

    private func moveRule(_ rule: RoutePlanRule, by offset: Int) {
        guard let index = folders.firstIndex(where: { $0.id == rule.id }) else { return }
        let target = index + offset
        guard folders.indices.contains(target) else { return }
        folders.swapAt(index, target)
    }

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
        folders = stored.rules
    }

    private func save() {
        rules.savePlan(plan)
        presentation.wrappedValue.dismiss()
    }
}

/// Редактор одной папки: название, действие, outbound и список атрибутов внутри.
struct RouteRuleEditorView: View {
    @Environment(\.presentationMode) private var presentation

    let targets: [String]
    let onSave: (RoutePlanRule) -> Void

    @State private var rule: RoutePlanRule
    @State private var showAttrPicker = false
    @State private var editingAttr: RoutePlanAttr?

    init(rule: RoutePlanRule, targets: [String], onSave: @escaping (RoutePlanRule) -> Void) {
        self.targets = targets
        self.onSave = onSave
        _rule = State(initialValue: rule)
    }

    private var isBlocking: Binding<Bool> {
        Binding(get: { rule.action == "reject" },
                set: { rule.action = $0 ? "reject" : "route" })
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Название папки", text: $rule.name)
                    Toggle("Блокировать", isOn: isBlocking)
                    if rule.action != "reject" {
                        Picker("Куда пускать", selection: $rule.outbound) {
                            ForEach(targets, id: \.self) { target in
                                Text(target).tag(target)
                            }
                        }
                    }
                } header: {
                    Text("Папка")
                } footer: {
                    Text(rule.action == "reject"
                         ? "Всё, что попадёт под атрибуты ниже, блокируется."
                         : "Всё, что попадёт под атрибуты ниже, уходит в этот outbound.")
                }

                Section {
                    if rule.attrs.isEmpty {
                        Text("Пока пусто: добавьте атрибуты — по ним папка и сработает.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    ForEach(rule.attrs) { item in
                        attrRow(item)
                    }
                    .onDelete { offsets in
                        rule.attrs.remove(atOffsets: offsets)
                    }
                    Button {
                        showAttrPicker = true
                    } label: {
                        Label("Добавить атрибут", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Атрибуты")
                } footer: {
                    Text("Условия внутри одной папки складываются: сработает, когда совпало каждое.")
                }
            }
            .navigationTitle(rule.name.isEmpty ? "Папка" : rule.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { presentation.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        onSave(rule)
                        presentation.wrappedValue.dismiss()
                    }
                }
            }
            .sheet(isPresented: $showAttrPicker) {
                RouteAttributePicker { attr in
                    addAttr(attr)
                }
            }
            .sheet(item: $editingAttr) { item in
                RouteValueView(attr: item.attr, values: item.values) { updated in
                    if let index = rule.attrs.firstIndex(where: { $0.id == item.id }) {
                        rule.attrs[index].values = updated
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func attrRow(_ item: RoutePlanAttr) -> some View {
        HStack(spacing: 8) {
            Button {
                editingAttr = item
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.attr)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.accent)
                    Text(item.summary)
                        .font(.caption2)
                        .foregroundColor(item.values.isEmpty ? .red : .secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if RouteAttribute.needsChoice(item.attr) {
                Button("Выбрать") { editingAttr = item }
                    .font(.caption2.weight(.medium))
                    .buttonStyle(.borderless)
            }

            Button {
                rule.attrs.removeAll { $0.id == item.id }
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }

    private func addAttr(_ attr: String) {
        guard !rule.attrs.contains(where: { $0.attr == attr }) else { return }
        let created = RoutePlanAttr(attr: attr)
        rule.attrs.append(created)
        // Сразу открываем значения: лишний тап по новой строке не нужен.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            if let fresh = rule.attrs.first(where: { $0.id == created.id }) {
                editingAttr = fresh
            }
        }
    }
}

/// Полный список атрибутов. Открывается сразу по «Добавить атрибут».
/// `outbound` здесь нет: он принадлежит папке, а не атрибуту.
struct RouteAttributePicker: View {
    @Environment(\.presentationMode) private var presentation
    @State private var query = ""

    let onPick: (String) -> Void

    private var attributes: [String] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return RouteAttribute.all.filter { $0 != "outbound" } }
        return RouteAttribute.all.filter { $0 != "outbound" && $0.contains(text) }
    }

    var body: some View {
        NavigationView {
            List {
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

/// Значения атрибута: список уже выбранных, поле для своего значения и готовые варианты.
///
/// Варианты отмечаются галочкой и сразу попадают в значение — в поиск ничего не подставляется.
/// Выбранные варианты всегда стоят сверху. Если вариантов больше пяти, они открываются
/// отдельным окном, иначе — прямо здесь.
struct RouteValueView: View {
    @Environment(\.presentationMode) private var presentation

    let attr: String
    @State private var values: [String]
    @State private var text = ""
    @State private var showOptions = false
    let onDone: ([String]) -> Void

    init(attr: String, values: [String], onDone: @escaping ([String]) -> Void) {
        self.attr = attr
        _values = State(initialValue: values)
        self.onDone = onDone
    }

    private var options: [String] { RouteAttribute.options(attr) }
    private var manyOptions: Bool { options.count > 5 }

    /// Выбранные — сверху, остальные ниже; фильтр применяется только к невыбранным.
    private var sortedOptions: [String] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let chosen = options.filter { values.contains($0) }
        let rest = options.filter { !values.contains($0) && (query.isEmpty || $0.lowercased().contains(query)) }
        return chosen + rest
    }

    var body: some View {
        NavigationView {
            Form {
                if !values.isEmpty {
                    Section {
                        ForEach(values, id: \.self) { value in
                            HStack {
                                Text(value)
                                    .font(.system(.footnote, design: .monospaced))
                                Spacer()
                                Button {
                                    values.removeAll { $0 == value }
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    } header: {
                        Text("Значения")
                    }
                }

                Section {
                    HStack {
                        TextField("Значение", text: $text)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.system(.footnote, design: .monospaced))
                        Button("Добавить") { addTyped() }
                            .font(.caption.weight(.semibold))
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if options.isEmpty {
                        Text(RouteAttribute.hint(attr))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text(attr)
                } footer: {
                    Text("Можно вписать своё значение — список только подсказывает формат.")
                }

                if !options.isEmpty {
                    Section {
                        if manyOptions {
                            Button {
                                showOptions = true
                            } label: {
                                HStack {
                                    Text("Выбрать из вариантов")
                                    Spacer()
                                    Text(String(options.count))
                                        .foregroundColor(.secondary)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        } else {
                            ForEach(sortedOptions, id: \.self) { option in
                                optionRow(option)
                            }
                        }
                    } header: {
                        Text("Готовые варианты")
                    } footer: {
                        Text("Нажатие отмечает вариант галочкой и сразу добавляет его к значению: выбранные держатся сверху.")
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
                        onDone(values)
                        presentation.wrappedValue.dismiss()
                    }
                }
            }
            .sheet(isPresented: $showOptions) {
                RouteOptionsSheet(attr: attr, options: options, values: $values)
            }
        }
        .navigationViewStyle(.stack)
    }

    private func optionRow(_ option: String) -> some View {
        Button {
            toggle(option)
        } label: {
            HStack {
                Text(option)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.primary)
                Spacer()
                if values.contains(option) {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ option: String) {
        if let index = values.firstIndex(of: option) {
            values.remove(at: index)
        } else {
            values.append(option)
        }
    }

    private func addTyped() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !values.contains(trimmed) { values.append(trimmed) }
        text = ""
    }
}

/// Окно выбора для атрибутов с длинным списком значений: галочки, выбранные сверху.
struct RouteOptionsSheet: View {
    @Environment(\.presentationMode) private var presentation
    @Binding var values: [String]

    let attr: String
    let options: [String]

    @State private var query = ""

    init(attr: String, options: [String], values: Binding<[String]>) {
        self.attr = attr
        self.options = options
        _values = values
    }

    private var ordered: [String] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let chosen = options.filter { values.contains($0) }
        let rest = options.filter { !values.contains($0) && (text.isEmpty || $0.lowercased().contains(text)) }
        return chosen + rest
    }

    var body: some View {
        NavigationView {
            List {
                if !values.isEmpty {
                    Section {
                        ForEach(values, id: \.self) { value in
                            HStack {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(Theme.accent)
                                Text(value)
                                    .font(.system(.footnote, design: .monospaced))
                                Spacer()
                                Button {
                                    values.removeAll { $0 == value }
                                } label: {
                                    Image(systemName: "minus.circle.fill").foregroundColor(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { toggle(value) }
                        }
                    } header: {
                        Text("Выбрано: \(values.count)")
                    }
                }
                Section {
                    ForEach(ordered, id: \.self) { option in
                        Button {
                            toggle(option)
                        } label: {
                            HStack {
                                Text(option)
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundColor(.primary)
                                Spacer()
                                if values.contains(option) {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(Theme.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Варианты")
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, prompt: "Поиск варианта")
            .navigationTitle(attr)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { presentation.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func toggle(_ option: String) {
        if let index = values.firstIndex(of: option) {
            values.remove(at: index)
        } else {
            values.append(option)
        }
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
