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

    /// Один лист на экран: несколько `.sheet` на одном виде в iOS 15 конфликтуют, и открывается
    /// только последний.
    private enum Sheet: Identifiable {
        case rule(RoutePlanRule)
        case newFolder
        case preview
        case export

        var id: String {
            switch self {
            case .rule(let rule): return "rule-\(rule.id.uuidString)"
            case .newFolder: return "newFolder"
            case .preview: return "preview"
            case .export: return "export"
            }
        }
    }

    @State private var sheet: Sheet?
    @State private var newRuleName = ""

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
        .sheet(item: $sheet) { item in
            switch item {
            case .rule(let rule):
                RouteRuleEditorView(rule: rule, targets: targets) { updated in
                    if let index = folders.firstIndex(where: { $0.id == updated.id }) {
                        folders[index] = updated
                    }
                }
            case .newFolder:
                newRuleSheet
            case .preview:
                RouteJSONSheet(title: name, text: rules.planJSON(plan))
            case .export:
                RouteExportView(plan: plan)
            }
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
                sheet = .newFolder
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
                sheet = .preview
            } label: {
                Label("Предварительный просмотр JSON", systemImage: "curlybraces")
            }
            Button {
                sheet = .export
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
                sheet = .rule(rule)
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
                    Button("Отмена") { sheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        let created = RoutePlanRule(name: newRuleName.trimmingCharacters(in: .whitespacesAndNewlines))
                        folders.append(created)
                        // Сначала закрываем лист создания: подмена одного листа другим на iOS 15
                        // не срабатывает, поэтому редактор открываем чуть позже.
                        sheet = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                            sheet = .rule(created)
                        }
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

/// Рамки строк атрибутов в координатах формы — по ним меню значений встаёт под своей строкой.
private struct AttributeFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Редактор одной папки: название, действие, outbound и список атрибутов внутри.
struct RouteRuleEditorView: View {
    @Environment(\.presentationMode) private var presentation
    /// Сервера берём из хранилища напрямую: в outbound папки можно указать конкретный сервер,
    /// а не только proxy/direct/reject, и список не должен зависеть от того, что передал родитель.
    @EnvironmentObject private var store: ProfileStore

    let targets: [String]
    let onSave: (RoutePlanRule) -> Void

    /// Встроенные цели плюс все сервера (по имени, без повторов).
    private var destinations: [String] {
        var list = targets
        for profile in store.profiles where !list.contains(profile.name) {
            list.append(profile.name)
        }
        return list
    }

    /// Один лист на экран (iOS 15 не умеет два `.sheet` на одном виде).
    private enum Sheet: Identifiable {
        case attribute
        case value(RoutePlanAttr)

        var id: String {
            switch self {
            case .attribute: return "attribute"
            case .value(let attr): return "value-\(attr.id.uuidString)"
            }
        }
    }

    @State private var rule: RoutePlanRule
    @State private var sheet: Sheet?
    /// Развёрнутый атрибут: варианты всплывают поверх формы, строки не сдвигаются.
    @State private var openAttr: UUID?

    /// Система координат формы: по ней считаются рамки строк для всплывающего меню.
    private static let formSpace = "routeFolderForm"

    init(rule: RoutePlanRule, targets: [String], onSave: @escaping (RoutePlanRule) -> Void) {
        self.targets = targets
        self.onSave = onSave
        _rule = State(initialValue: rule)
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Название папки", text: $rule.name)
                    Picker("Outbound по умолчанию", selection: $rule.outbound) {
                        ForEach(destinations, id: \.self) { target in
                            Text(target).tag(target)
                        }
                    }
                    .onChange(of: rule.outbound) { target in
                        // «Блокировать» — это тот же outbound, просто reject: отдельного
                        // переключателя не нужно, action держим в согласии с выбором.
                        rule.action = target == "reject" ? "reject" : "route"
                    }
                } header: {
                    Text("Папка")
                } footer: {
                    Text("Direct — напрямую, Proxy — через прокси, Reject — заблокировать.\nВсё, что попадёт под атрибуты ниже, уходит в выбранный outbound.")
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
                        sheet = .attribute
                    } label: {
                        Label("Добавить атрибут", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Атрибуты · свайп влево, чтоб удалить")
                } footer: {
                    Text("Условия внутри одной папки складываются: сработает, когда совпало каждое.")
                }
            }
            .navigationTitle(rule.name.isEmpty ? "Папка" : rule.name)
            .navigationBarTitleDisplayMode(.inline)
            .coordinateSpace(name: Self.formSpace)
            // Меню значений рисуется поверх формы: координаты строк приходят из
            // AttributeFrameKey, поэтому список висит ровно под своей строкой.
            .overlayPreferenceValue(AttributeFrameKey.self) { frames in
                GeometryReader { proxy in
                    if let id = openAttr,
                       let frame = frames[id],
                       let item = rule.attrs.first(where: { $0.id == id }) {
                        let width: CGFloat = 236
                        let height = CGFloat(RouteAttribute.options(item.attr).count) * 38 + 54
                        ZStack(alignment: .topLeading) {
                            Color.black.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture { openAttr = nil }
                            optionsPopup(for: item)
                                .frame(width: width)
                                .offset(
                                    x: max(12, proxy.size.width - width - 16),
                                    y: min(frame.maxY + 6,
                                           max(12, proxy.size.height - height - 12))
                                )
                        }
                    }
                }
            }
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
            .sheet(item: $sheet) { item in
                switch item {
                case .attribute:
                    RouteAttributePicker { attr in
                        addAttr(attr)
                    }
                case .value(let current):
                    RouteValueView(attr: current.attr, values: current.values) { updated in
                        if let index = rule.attrs.firstIndex(where: { $0.id == current.id }) {
                            rule.attrs[index].values = updated
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    /// Строка атрибута: имя и значение слева, «Выбрать» справа. Варианты до пяти всплывают
    /// поверх формы — строки не сдвигаются, отдельное окно не открывается.
    private func attrRow(_ item: RoutePlanAttr) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.attr)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.accent)
                Text(item.summary)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(openAttr == item.id ? "Принять" : "Выбрать") { pick(item) }
                .font(.caption2.weight(.medium))
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: AttributeFrameKey.self,
                    value: [item.id: proxy.frame(in: .named(Self.formSpace))]
                )
            }
        )
    }

    /// «Выбрать»: до пяти вариантов — всплывающий список, иначе окно (поиск или ввод).
    private func pick(_ item: RoutePlanAttr) {
        let options = RouteAttribute.options(item.attr)
        if options.isEmpty || options.count > 5 {
            openAttr = nil
            sheet = .value(item)
            return
        }
        openAttr = openAttr == item.id ? nil : item.id
    }

    /// Одиночный выбор заменяет значение, наборы (`rule_set`) копятся. Список остаётся
    /// открытым: галочка должна быть видна сразу, без повторного тапа.
    private func choose(_ option: String, in item: RoutePlanAttr) {
        guard let index = rule.attrs.firstIndex(where: { $0.id == item.id }) else { return }
        var values = rule.attrs[index].values
        if let at = values.firstIndex(of: option) {
            values.remove(at: at)
        } else if RouteAttribute.singleChoice(item.attr) {
            values = [option]
        } else {
            values.append(option)
        }
        rule.attrs[index].values = values
    }

    /// Всплывающий список значений: галочки и «Принять» внизу.
    private func optionsPopup(for item: RoutePlanAttr) -> some View {
        let options = RouteAttribute.options(item.attr)
        return VStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button {
                    choose(option, in: item)
                } label: {
                    HStack(spacing: 8) {
                        Text(option)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(.primary)
                        Spacer(minLength: 6)
                        if item.values.contains(option) {
                            Image(systemName: "checkmark")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(Theme.accent)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider()
            Button {
                openAttr = nil
            } label: {
                Text("Принять")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        )
    }

    /// Новый атрибут только добавляется: значения выбираются по «Выбрать», а не сразу
    /// открытым листом — иначе после каждого добавления поверх экрана висит окно.
    private func addAttr(_ attr: String) {
        guard !rule.attrs.contains(where: { $0.attr == attr }) else { return }
        rule.attrs.append(RoutePlanAttr(attr: attr))
        sheet = nil
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

/// Значения атрибута. Два случая и ни одним больше:
/// — вариантов нет: поле с «＋» и список добавленного с удалением;
/// — вариантов больше пяти (`rule_set` — 48): поиск сверху, выбранные с галочкой держатся первыми.
/// До пяти вариантов окно не открывается вовсе — они раскрываются прямо в папке.
struct RouteValueView: View {
    @Environment(\.presentationMode) private var presentation

    let attr: String
    @State private var values: [String]
    @State private var text = ""
    @State private var query = ""
    let onDone: ([String]) -> Void

    init(attr: String, values: [String], onDone: @escaping ([String]) -> Void) {
        self.attr = attr
        _values = State(initialValue: values)
        self.onDone = onDone
    }

    private var options: [String] { RouteAttribute.options(attr) }

    /// Выбранные — сверху, остальные ниже; поиск фильтрует только невыбранные.
    private var shown: [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let chosen = options.filter { values.contains($0) }
        let rest = options.filter {
            !values.contains($0) && (needle.isEmpty || $0.lowercased().contains(needle))
        }
        return chosen + rest
    }

    var body: some View {
        NavigationView {
            Group {
                if options.isEmpty {
                    typedForm
                } else {
                    optionsList
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
        }
        .navigationViewStyle(.stack)
    }

    /// Вариантов нет: поле ввода с «＋» справа, введённое копится ниже с удалением.
    private var typedForm: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("Значение", text: $text)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.footnote, design: .monospaced))
                        .onSubmit { addTyped() }
                    Button {
                        addTyped()
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundColor(Theme.accent)
                    }
                    .buttonStyle(.borderless)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Значение")
            } footer: {
                Text(RouteAttribute.hint(attr))
            }

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
                    Text("Добавлено · \(values.count)")
                } footer: {
                    Text("Можно вписать своё значение — список только подсказывает формат.")
                }
            }
        }
    }

    /// Длинный список: поиск и галочки в этом же окне, без второго листа.
    private var optionsList: some View {
        List {
            Section {
                ForEach(shown, id: \.self) { option in
                    optionRow(option)
                }
            } header: {
                Text("Выбрано: \(values.count) из \(options.count)")
            } footer: {
                Text("Нажатие ставит галочку, выбранные поднимаются наверх. Поиск фильтрует остальные.")
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Найти значение")
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

    /// Одиночный выбор заменяет значение, наборы (`rule_set`) копятся.
    private func toggle(_ option: String) {
        if let index = values.firstIndex(of: option) {
            values.remove(at: index)
        } else if RouteAttribute.singleChoice(attr) {
            values = [option]
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
