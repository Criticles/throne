import SwiftUI

/// Маршрут: режим, расширенная маршрутизация отдельной кнопкой и гео-списки.
/// Сами правила живут в «Маршрутизации» — здесь только выбор и общие переключатели.
struct RoutingView: View {
    @EnvironmentObject private var prefs: Prefs
    @EnvironmentObject private var rules: RuleStore
    @EnvironmentObject private var router: AppRouter

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
                        Text(router.pendingInsert.map { "ждёт: «" + $0.value + "» → выберите профиль" }
                             ?? "активно: " + rules.plan.name + " · профилей: " + String(rules.plans.count))
                            .font(.caption2)
                            .foregroundColor(router.pendingInsert == nil ? .secondary : Theme.accent)
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
            Button {
                geoName = ""
                geoURL = ""
                showGeoSheet = true
            } label: {
                Label("Добавить свой список", systemImage: "plus.circle")
            }
        } header: {
            Text("Гео-списки")
        } footer: {
            Text("Списки Loyalsoldier: страны и категории доменов для правил geosite/geoip. " + rules.status)
        }
    }

    private var geoSheet: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Имя списка", text: $geoName)
                    TextField("https://…/geoip.dat", text: $geoURL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .font(.system(.footnote, design: .monospaced))
                } footer: {
                    Text("Любой .dat/.srs по ссылке: скачается в приложение и появится в этом списке.")
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
                        rules.addAsset(name: geoName, url: geoURL)
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
