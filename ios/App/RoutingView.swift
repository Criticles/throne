import SwiftUI

/// Маршрут: режим, расширенная маршрутизация отдельной кнопкой и гео-списки.
/// Сами правила живут в «Маршрутизации» — здесь только выбор и общие переключатели.
struct RoutingView: View {
    @EnvironmentObject private var prefs: Prefs
    @EnvironmentObject private var rules: RuleStore

    @State private var showGeoSheet = false
    @State private var geoName = ""
    @State private var geoURL = ""

    var body: some View {
        NavigationView {
            List {
                advancedSection
                modeSection
                geoSection
                xraySection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Маршрут")
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showGeoSheet) { geoSheet }
    }

    private var advancedSection: some View {
        Section {
            NavigationLink {
                RouteProfilesView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundColor(Theme.accent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Профили маршрутизации").font(.subheadline.weight(.medium))
                        Text("активно: " + rules.plan.name + " · профилей: " + String(rules.plans.count))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var modeSection: some View {
        Section {
            // Режим и его пояснение — одна строка: между ними не должно быть пустого места.
            VStack(alignment: .leading, spacing: 4) {
                Picker("Режим", selection: $prefs.routingMode) {
                    ForEach(Prefs.RoutingMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(prefs.routingMode.hint)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 2)

            Picker("Если ни одно правило не совпало", selection: $prefs.finalAction) {
                ForEach(RuleAction.allCases) { action in
                    Text(action.title).tag(action)
                }
            }
            Toggle("Не пускать локальную сеть в туннель", isOn: $prefs.bypassLocalNetwork)
            Toggle("Блокировать рекламу и трекеры", isOn: $prefs.blockAds)
        } header: {
            Text("Режим")
        }
    }

    /// Наборы правил `.srs`: их читает ядро, на них ссылаются правила и режимы
    /// «Кроме России» / «Блокировать рекламу». Раньше здесь висели `.dat` от Loyalsoldier,
    /// которые sing-box не понимает.
    private var geoSection: some View {
        Section {
            ForEach(rules.ruleSets) { set in
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down")
                        .foregroundColor(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(set.name).font(.subheadline)
                        Text(set.bytes > 0
                             ? Format.size(Int64(set.bytes)) + " · " + Self.dateText(set.updated)
                             : "не скачан")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(set.bytes > 0 ? "Обновить" : "Скачать") {
                        Task { await rules.download(set) }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
            }
            .onDelete { offsets in
                for index in offsets { rules.deleteRuleSet(rules.ruleSets[index]) }
            }
            Button {
                geoName = ""
                geoURL = ""
                showGeoSheet = true
            } label: {
                Label("Добавить свой набор", systemImage: "plus.circle")
            }
        } header: {
            Text("Наборы правил")
        } footer: {
            Text("Бинарные .srs: «Кроме России» и «Блокировать рекламу» работают, когда соответствующий набор скачан. " + rules.status)
        }
    }

    private static func dateText(_ date: Date?) -> String {
        guard let date else { return "нет даты" }
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM HH:mm"
        return formatter.string(from: date)
    }

    private var geoSheet: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Имя списка", text: $geoName)
                    TextField("https://…/geosite-ads.srs", text: $geoURL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .font(.system(.footnote, design: .monospaced))
                } footer: {
                    Text("Ссылка на .srs от sing-geosite или sing-geoip: файл скачается, и на него можно ссылаться атрибутом rule_set.")
                }
            }
            .navigationTitle("Свой список")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { showGeoSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") {
                        let title = geoName.trimmingCharacters(in: .whitespacesAndNewlines)
                        rules.addRuleSet(RuleSet(name: title.isEmpty ? "набор" : title,
                                                 url: geoURL.trimmingCharacters(in: .whitespacesAndNewlines)))
                        showGeoSheet = false
                    }
                    .disabled(geoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .navigationViewStyle(.stack)
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

    private func detail(for asset: GeoAsset) -> String {
        guard asset.bytes > 0 else { return "не скачан" }
        let size = Format.size(Int64(asset.bytes))
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
