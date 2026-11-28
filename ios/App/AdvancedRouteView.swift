import SwiftUI
import UniformTypeIdentifiers

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
    /// Служебный профиль: у него нет своего final, и флаг нельзя потерять
    /// при сохранении — иначе «Быстрые правила» станут обычным профилем.
    @State private var isSystem = false
    /// Включён ли профиль: у «Быстрых правил» это переключатель, у обычных — тоже.
    @State private var isEnabled = true
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
        case newFolder
        case preview
        case export
        /// Куда идёт всё, что не поймала ни одна папка: то же окно, что у атрибутов.
        case destination

        var id: String {
            switch self {
            case .newFolder: return "newFolder"
            case .preview: return "preview"
            case .export: return "export"
            case .destination: return "destination"
            }
        }
    }

    @State private var sheet: Sheet?
    @State private var newRuleName = ""
    /// Какая папка сейчас «в руке» при перетаскивании.
    @State private var dragging: UUID?

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
                  isSystem: isSystem,
                  isEnabled: isEnabled,
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
        .sheet(item: $sheet) { item in
            switch item {
            case .newFolder:
                newRuleSheet
            case .preview:
                RouteJSONSheet(title: name, text: rules.planJSON(plan))
            case .export:
                RouteExportView(plan: plan)
            case .destination:
                RouteValueView(attr: "outbound", values: [finalTarget], options: targets) { updated in
                    let value = updated.first ?? "proxy"
                    finalTarget = value.isEmpty ? "proxy" : value
                }
            }
        }
        .onAppear(perform: load)
        // Пишем в хранилище сразу: «Куда добавить» и «Соединения» читают store,
        // а не состояние этого экрана — иначе папки видны только здесь.
        .onChange(of: folders) { _ in persist() }
        .onChange(of: name) { _ in persist() }
        .onChange(of: finalTarget) { _ in persist() }
        .onChange(of: directList) { _ in persist() }
        .onChange(of: proxyList) { _ in persist() }
        .onChange(of: blockList) { _ in persist() }
        .onChange(of: warpList) { _ in persist() }
        .onDisappear { persist() }
    }

    /// Сохранение без выхода с экрана.
    private func persist() {
        guard loaded else { return }
        rules.savePlan(plan)
    }

    // MARK: - Секции

    private var commonSection: some View {
        Section {
            TextField("Название профиля", text: $name)

            // У «Быстрых правил» выхода по умолчанию нет: всё, что не поймала
            // ни одна папка, уходит в активный профиль — там уже его final.
            if isSystem {
                // У «Быстрых правил» нет своего выхода, зато есть выключатель:
                // пока он выключен, папки в конфиг не попадают.
                Toggle(isOn: $isEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Быстрые правила включены")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.primary)
                        Text(isEnabled
                             ? "их папки проверяются раньше основного профиля"
                             : "выключены — трафик идёт по основному профилю")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .tint(Theme.accent)
            } else {
                // Тот же вид, что у атрибутов папки: имя, значение и «Выбрать» с окном.
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Outbound по умолчанию")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.primary)
                        Text(finalTarget)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Выбрать") { sheet = .destination }
                        .font(.caption2.weight(.medium))
                        .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Основное")
        } footer: {
            Text(isSystem
                 ? "Служебный профиль: его папки проверяются раньше основного, своего выхода у него нет — непойманное уходит в выбранный профиль."
                 : "Сюда идёт всё, что не поймала ни одна папка: proxy — выбранный сервер, direct — напрямую, reject — блокировать.")
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
                    // Свайп на удаление есть только у обычных папок: у служебных
                    // Reject/Direct/Proxy кнопки нет, а не «есть, но не работает».
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !rule.locked {
                            Button(role: .destructive) {
                                folders.removeAll { $0.id == rule.id }
                            } label: {
                                Label("Удалить", systemImage: "trash")
                            }
                        }
                    }
            }
            .onMove { source, destination in
                folders.move(fromOffsets: source, toOffset: destination)
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
            Text("Приоритет исполнения — сверху вниз: каждая следующая папка менее приоритетна, чем предыдущая. Зажмите папку, чтобы переставить; свайп влево — удалить.")
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

    /// Строка папки: только стрелка перехода. Порядок — зажать и потянуть,
    /// удаление — свайпом вправо или кнопкой внутри папки.
    private func folderRow(_ rule: RoutePlanRule) -> some View {
        NavigationLink {
            RouteRuleEditorView(rule: rule, targets: targets, embedded: true) { updated in
                if let index = folders.firstIndex(where: { $0.id == updated.id }) {
                    folders[index] = updated
                }
            }
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
            .padding(.vertical, 2)
        }
        .onDrag {
            dragging = rule.id
            return NSItemProvider(object: rule.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: FolderDropDelegate(item: rule,
                                                        items: $folders,
                                                        dragging: $dragging))
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
                        // Редактор теперь открывается переходом по строке папки,
                        // поэтому лист просто закрываем.
                        sheet = nil
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
        isSystem = stored.isSystem
        isEnabled = stored.isEnabled
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
/// Перестановка папок долгим нажатием: тянем строку, порядок меняется на лету.
struct FolderDropDelegate: DropDelegate {
    let item: RoutePlanRule
    @Binding var items: [RoutePlanRule]
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item.id,
              let from = items.firstIndex(where: { $0.id == dragging }),
              let to = items.firstIndex(where: { $0.id == item.id }) else { return }
        withAnimation {
            items.move(fromOffsets: IndexSet(integer: from),
                       toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

struct RouteRuleEditorView: View {
    @Environment(\.presentationMode) private var presentation
    /// Сервера берём из хранилища напрямую: в outbound папки можно указать конкретный сервер,
    /// а не только proxy/direct/reject, и список не должен зависеть от того, что передал родитель.
    @EnvironmentObject private var store: ProfileStore

    let targets: [String]
    /// true — открыт переходом (свой NavigationView не нужен, «Отмены» нет, есть «назад»).
    let embedded: Bool
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
    /// Атрибут, для которого открыт выбор значения панелью снизу.
    @State private var attrPicker: RoutePlanAttr?

    init(rule: RoutePlanRule, targets: [String], embedded: Bool = false,
         onSave: @escaping (RoutePlanRule) -> Void) {
        self.targets = targets
        self.embedded = embedded
        self.onSave = onSave
        var initial = rule
        // На iPhone нет процессов, Android-пакетов и Wi-Fi: такие атрибуты из папки убираем
        // и в редакторе, а не только при импорте.
        initial.attrs.removeAll { RouteAttribute.unavailable.contains($0.attr) }
        // Одиночные атрибуты (outbound, network, ip_version…) держат одно значение: старые
        // профили могли сохранить несколько — оставляем последнее выбранное.
        for index in initial.attrs.indices
        where RouteAttribute.singleChoice(initial.attrs[index].attr) && initial.attrs[index].values.count > 1 {
            initial.attrs[index].values = [initial.attrs[index].values[0]]
        }
        // `outbound` всегда в списке: он задаёт, куда папка уходит, и правится как остальные
        // атрибуты. В JSON он при этом остаётся полем правила, а не ключом-массивом.
        if !initial.attrs.contains(where: { $0.attr == "outbound" }) {
            initial.attrs.insert(RoutePlanAttr(attr: "outbound",
                                               values: [initial.outbound.isEmpty ? "proxy" : initial.outbound]),
                                 at: 0)
        }
        _rule = State(initialValue: initial)
    }

    var body: some View {
        if embedded {
            // Кнопок нет: изменения уходят в профиль сразу, «назад» ничего не теряет.
            contentWithPicker
                .onChange(of: rule) { updated in onSave(updated) }
                .onDisappear { onSave(rule) }
        } else {
            NavigationView {
                contentWithPicker.toolbar { cancelToolbar; confirmToolbar }
            }
            .navigationViewStyle(.stack)
        }
    }

    /// Экран плюс панель выбора значения атрибута.
    private var contentWithPicker: some View {
        content.overlay(
            Group {
                if let item = attrPicker {
                    PillChoiceSheet(
                        title: item.attr,
                        items: valueOptions(item.attr).map { option in
                            PillChoiceSheet.Item(id: option,
                                                 title: option,
                                                 detail: item.values.contains(option) ? "выбрано" : nil,
                                                 accent: item.values.contains(option))
                        },
                        extraTitle: nil,
                        onPick: { picked in
                            choose(picked.title, in: item)
                            withAnimation(.easeOut(duration: 0.15)) { attrPicker = nil }
                        },
                        onExtra: {},
                        onCancel: { withAnimation(.easeOut(duration: 0.15)) { attrPicker = nil } }
                    )
                }
            }
        )
    }

    /// «Готово» есть всегда: и на экране, и в листе.
    @ToolbarContentBuilder
    private var confirmToolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Готово") {
                onSave(rule)
                presentation.wrappedValue.dismiss()
            }
        }
    }

    /// «Отмена» только у листа — на экране возвращает стрелка «назад».
    @ToolbarContentBuilder
    private var cancelToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Отмена") { presentation.wrappedValue.dismiss() }
        }
    }

    private var content: some View {
        Group {
            Form {
                Section {
                    // У служебных папок имя задаёт поведение (Reject/Direct/Proxy),
                    // поэтому их не переименовываем.
                    TextField("Название папки", text: $rule.name)
                        .disabled(rule.locked)
                } header: {
                    Text("Папка")
                } footer: {
                    Text("Куда направить папку — атрибут outbound: proxy, direct, reject или конкретный сервер.\nУсловия ниже складываются: сработает, когда совпало каждое.")
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
            .sheet(item: $sheet) { item in
                switch item {
                case .attribute:
                    RouteAttributePicker { attr in
                        addAttr(attr)
                    }
                case .value(let current):
                    RouteValueView(attr: current.attr, values: current.values,
                                   options: valueOptions(current.attr)) { updated in
                        if let index = rule.attrs.firstIndex(where: { $0.id == current.id }) {
                            rule.attrs[index].values = updated
                            syncDestination(current.attr)
                        }
                    }
                }
            }
        }
    }

    /// Значения атрибута: у `outbound` — все сервера, у остальных — справочник.
    private func valueOptions(_ attr: String) -> [String] {
        attr == "outbound" ? destinations : RouteAttribute.options(attr)
    }

    /// Строка атрибута: имя и значение слева, «Выбрать» справа. До пяти вариантов — нативное
    /// меню (как у строки DNS): всплывает над содержимым, ничего не сдвигает, ставит галочку.
    private func attrRow(_ item: RoutePlanAttr) -> some View {
        let options = valueOptions(item.attr)
        let isDestination = item.attr == "outbound"
        let shown = isDestination
            ? (rule.outbound.isEmpty ? "не задано" : rule.outbound)
            : item.summary
        let placeholder = isDestination ? rule.outbound.isEmpty : item.values.isEmpty

        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.attr)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.primary)
                // «не задано» — обычным шрифтом: в моноширинном пробел выглядит вдвое шире.
                Text(shown)
                    .font(.system(.caption2, design: placeholder ? .default : .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Text(RouteAttribute.about(item.attr))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .opacity(0.75)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if RouteAttribute.singleChoice(item.attr), options.count > 1 {
                // Одиночный выбор (protocol, network, ip_version…) — панель, как «Куда направить».
                Button("Выбрать") { attrPicker = item }
                    .font(.caption2.weight(.medium))
                    .foregroundColor(Theme.accent)
                    .buttonStyle(.borderless)
            } else if options.isEmpty || options.count > 5 {
                Button("Выбрать") { sheet = .value(item) }
                    .font(.caption2.weight(.medium))
                    .buttonStyle(.borderless)
            } else {
                Menu {
                    ForEach(options, id: \.self) { option in
                        Button {
                            choose(option, in: item)
                        } label: {
                            Text(item.values.contains(option) ? "✓ \(option)" : option)
                        }
                    }
                } label: {
                    Text("Выбрать")
                        .font(.caption2.weight(.medium))
                        .foregroundColor(Theme.accent)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Одиночный выбор заменяет значение, наборы (`rule_set`) копятся.
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
        syncDestination(item.attr)
    }

    /// `outbound` — это поле правила, а не обычный ключ: держим `rule.outbound`/`action`
    /// в согласии с выбранным значением, иначе JSON уедет не туда.
    private func syncDestination(_ attr: String) {
        guard attr == "outbound" else { return }
        let destination = rule.attrs.first(where: { $0.attr == "outbound" })?.values.first ?? "proxy"
        rule.outbound = destination.isEmpty ? "proxy" : destination
        rule.action = rule.outbound == "reject" ? "reject" : "route"
    }

    /// Новый атрибут только добавляется: значения выбираются по «Выбрать», а не сразу
    /// открытым листом — иначе после каждого добавления поверх экрана висит окно.
    private func addAttr(_ attr: String) {
        guard !rule.attrs.contains(where: { $0.attr == attr }) else { return }
        // У outbound значение уже есть — это поле самой папки.
        let seeded = attr == "outbound" ? [rule.outbound] : []
        rule.attrs.append(RoutePlanAttr(attr: attr, values: seeded))
        sheet = nil
    }
}

/// Полный список атрибутов. Открывается сразу по «Добавить атрибут».
/// `outbound` здесь есть: он же выбирает, куда папка уходит (proxy, direct, reject или сервер).
struct RouteAttributePicker: View {
    @Environment(\.presentationMode) private var presentation
    @State private var query = ""

    let onPick: (String) -> Void

    private var attributes: [String] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return RouteAttribute.available }
        return RouteAttribute.available.filter { $0.contains(text) }
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
    /// Свой список значений (у `outbound` — все сервера); nil — справочник по атрибуту.
    let customOptions: [String]?
    let onDone: ([String]) -> Void

    init(attr: String, values: [String], options: [String]? = nil,
         onDone: @escaping ([String]) -> Void) {
        self.attr = attr
        // Одиночный атрибут держит одно значение: если в старых данных их несколько,
        // оставляем первое — иначе в списке сразу три галочки.
        let initial = (RouteAttribute.singleChoice(attr) && values.count > 1) ? [values[0]] : values
        _values = State(initialValue: initial)
        self.customOptions = options
        self.onDone = onDone
    }

    private var options: [String] { customOptions ?? RouteAttribute.options(attr) }

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
                Text(RouteAttribute.singleChoice(attr)
                     ? "Выбрано: " + (values.first ?? "ничего")
                     : "Выбрано: \(values.count) из \(options.count)")
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
