import SwiftUI

/// Маршрутизация: режим, правила, гео-списки и проверка «какое правило поймает домен».
struct RoutingView: View {
    @EnvironmentObject private var prefs: Prefs
    @EnvironmentObject private var rules: RuleStore

    @State private var draft: RouteRule?
    @State private var domain = ""

    var body: some View {
        NavigationView {
            List {
                modeSection
                rulesSection
                geoSection
                testSection
                xraySection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Маршрут")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        draft = RouteRule()
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                }
            }
            .sheet(item: $draft) { rule in
                RuleEditorView(rule: rule) { saved in
                    if rules.rules.contains(where: { $0.id == saved.id }) {
                        rules.update(saved)
                    } else {
                        rules.add(saved)
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var modeSection: some View {
        Section {
            Picker("Режим", selection: $prefs.routingMode) {
                ForEach(Prefs.RoutingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .listRowSeparator(.hidden)

            Text(prefs.routingMode.hint)
                .font(.footnote)
                .foregroundColor(.secondary)

            Toggle("Не пускать локальную сеть в туннель", isOn: $prefs.bypassLocalNetwork)
            Toggle("Блокировать рекламу и трекеры", isOn: $prefs.blockAds)
        } header: {
            Text("Режим")
        }
    }

    private var rulesSection: some View {
        Section {
            ForEach(rules.rules) { rule in
                HStack(spacing: 12) {
                    Circle()
                        .fill(color(for: rule.action))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rule.title).font(.subheadline)
                        Text(rule.kind.title + " → " + rule.action.title)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { rule.enabled },
                        set: { _ in rules.toggle(rule) }
                    ))
                    .labelsHidden()
                }
                .contentShape(Rectangle())
                .onTapGesture { draft = rule }
                .swipeActions {
                    if !rule.builtin {
                        Button(role: .destructive) {
                            rules.delete(rule)
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                }
            }
            .onDelete { offsets in
                // Сначала собираем копии: удаление сдвигает индексы.
                let victims = offsets.map { rules.rules[$0] }.filter { !$0.builtin }
                for rule in victims { rules.delete(rule) }
            }
            .onMove { source, destination in
                rules.move(from: source, to: destination)
            }
        } header: {
            HStack {
                Text("Правила")
                Spacer()
                Text("\(rules.rules.filter { $0.enabled }.count)/\(rules.rules.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } footer: {
            Text("Порядок важен: срабатывает первое совпавшее правило. Нажмите на правило, чтобы изменить. Карандаш сверху — перетаскивание.")
        }
    }

    private var geoSection: some View {
        Section {
            ForEach(rules.assets) { asset in
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundColor(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(asset.name).font(.subheadline)
                        Text(detail(for: asset))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(asset.bytes > 0 ? "Обновить" : "Скачать") {
                        Task { await rules.download(asset) }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
        } header: {
            Text("Гео-списки")
        } footer: {
            Text("Списки Loyalsoldier: страны и категории доменов для правил geosite/geoip. " + rules.status)
        }
    }

    private var testSection: some View {
        Section {
            TextField("например, ads.example.com или 10.1.2.3", text: $domain)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            Text(rules.evaluate(domain))
                .font(.footnote)
                .foregroundColor(.secondary)
        } header: {
            Text("Какое правило поймает адрес")
        } footer: {
            Text("Проверка идёт по вашим правилам в том же порядке, что и в ядре. Списки geosite/geoip читает только ядро, поэтому по ним ответ приблизительный.")
        }
    }

    private var xraySection: some View {
        Section {
            Picker("VLESS-профили", selection: $prefs.xrayPreference) {
                ForEach(Prefs.XrayPreference.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
        } header: {
            Text("Xray")
        } footer: {
            Text("Какие VLESS-серверы отдавать ядру Xray вместо sing-box: XHTTP он умеет, sing-box — нет.")
        }
    }

    private func color(for action: RuleAction) -> Color {
        switch action {
        case .proxy: return Theme.accent
        case .direct: return .green
        case .block: return .red
        }
    }

    private func detail(for asset: GeoAsset) -> String {
        guard asset.bytes > 0 else { return "не скачан" }
        let size = ByteCountFormatter.string(fromByteCount: Int64(asset.bytes), countStyle: .file)
        if let updated = asset.updated {
            return size + " · " + Self.formatter.string(from: updated)
        }
        return size
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()
}

/// Редактор правила с подсказками: при вводе показывает теги geosite, коды стран и уже
/// использованные значения — как в Throne на Android.
struct RuleEditorView: View {
    @EnvironmentObject private var rules: RuleStore
    @Environment(\.presentationMode) private var presentation

    let original: RouteRule
    let onSave: (RouteRule) -> Void

    @State private var kind: RuleKind
    @State private var value: String
    @State private var action: RuleAction
    @State private var enabled: Bool

    init(rule: RouteRule, onSave: @escaping (RouteRule) -> Void) {
        self.original = rule
        self.onSave = onSave
        _kind = State(initialValue: rule.kind)
        _value = State(initialValue: rule.value)
        _action = State(initialValue: rule.action)
        _enabled = State(initialValue: rule.enabled)
    }

    private var suggestions: [String] {
        rules.suggestions(for: kind, query: value)
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("Тип", selection: $kind) {
                        ForEach(RuleKind.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    TextField(kind.placeholder, text: $value)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                } header: {
                    Text("Условие")
                } footer: {
                    Text(kind.hint)
                }

                if !suggestions.isEmpty {
                    Section("Подсказки") {
                        ForEach(suggestions, id: \.self) { item in
                            Button(item) {
                                value = item
                            }
                            .buttonStyle(.borderless)
                            .font(.subheadline)
                        }
                    }
                }

                Section("Действие") {
                    Picker("Действие", selection: $action) {
                        ForEach(RuleAction.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Правило включено", isOn: $enabled)
                }
            }
            .navigationTitle(original.value.isEmpty ? "Новое правило" : "Правило")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { presentation.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        var rule = original
                        rule.kind = kind
                        rule.value = value
                        rule.action = action
                        rule.enabled = enabled
                        onSave(rule)
                        presentation.wrappedValue.dismiss()
                    }
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
