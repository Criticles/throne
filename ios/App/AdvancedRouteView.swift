import SwiftUI

/// Маршрутизация: два вида — упрощённый (четыре списка, как в Throne на ПК) и расширенный
/// (записи «правило → outbound»). Экспорт и импорт — JSON или ссылка `throne://route`.
struct AdvancedRouteView: View {
    @EnvironmentObject private var rules: RuleStore
    @EnvironmentObject private var store: ProfileStore
    @Environment(\.presentationMode) private var presentation

    @State private var name = "Маршрут"
    @State private var finalTarget = "proxy"
    @State private var directList = ""
    @State private var proxyList = ""
    @State private var blockList = ""
    @State private var warpList = ""
    @State private var entries: [RoutePlanEntry] = []
    @State private var tab = 0
    @State private var showTransfer = false
    @State private var message = ""
    @State private var loaded = false

    private var targets: [String] {
        var list = ["proxy", "direct", "reject"]
        for profile in store.profiles where !list.contains(profile.name) {
            list.append(profile.name)
        }
        return list
    }

    private var plan: RoutePlan {
        RoutePlan(name: name,
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
            transferSection
        }
        .navigationTitle("Маршрутизация")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить") { save() }
            }
        }
        .sheet(isPresented: $showTransfer) {
            RouteTransferView(plan: plan) { imported in
                apply(imported)
            }
        }
        .onAppear(perform: load)
    }

    private var commonSection: some View {
        Section {
            TextField("Название правила", text: $name)
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
        .listRowSeparator(.hidden)
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
            ForEach($entries) { $entry in
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Тип", selection: $entry.kind) {
                        Text("Правило").tag("rule")
                        Text("Outbound").tag("outbound")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

                    if entry.kind == "rule" {
                        Picker("Атрибут", selection: $entry.attr) {
                            ForEach(RouteAttribute.all, id: \.self) { attr in
                                Text(attr).tag(attr)
                            }
                        }
                        .font(.caption)
                        TextField(RouteAttribute.hint(entry.attr), text: $entry.value)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .font(.system(.footnote, design: .monospaced))
                        Text(RouteAttribute.hint(entry.attr))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        Picker("Цель", selection: $entry.value) {
                            ForEach(targets, id: \.self) { target in
                                Text(target).tag(target)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .onDelete { offsets in
                entries.remove(atOffsets: offsets)
            }

            Menu {
                Menu("Правило") {
                    ForEach(RouteAttribute.all.prefix(10), id: \.self) { attr in
                        Button(attr) {
                            entries.append(RoutePlanEntry(kind: "rule", attr: attr, value: ""))
                        }
                    }
                }
                Button {
                    entries.append(RoutePlanEntry(kind: "outbound", attr: "outbound", value: "direct"))
                } label: {
                    Label("Outbound", systemImage: "arrow.turn.down.right")
                }
            } label: {
                Label("Добавить запись", systemImage: "plus.circle")
            }
        } header: {
            Text("Записи по порядку")
        } footer: {
            Text("Срабатывает первая подходящая запись — порядок можно менять перетаскиванием в режиме правки.")
        }
    }

    private var transferSection: some View {
        Section {
            Button {
                showTransfer = true
            } label: {
                Label("Экспорт и импорт", systemImage: "square.and.arrow.up.on.square")
            }
        } footer: {
            Text(message.isEmpty ? "JSON или ссылка throne://route — можно перенести правило между устройствами." : message)
        }
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

    private func load() {
        guard !loaded else { return }
        loaded = true
        name = rules.plan.name
        finalTarget = rules.plan.finalTarget
        directList = rules.plan.directList
        proxyList = rules.plan.proxyList
        blockList = rules.plan.blockList
        warpList = rules.plan.warpList
        entries = rules.plan.entries
    }

    private func apply(_ imported: RoutePlan) {
        name = imported.name
        finalTarget = imported.finalTarget
        directList = imported.directList
        proxyList = imported.proxyList
        blockList = imported.blockList
        warpList = imported.warpList
        entries = imported.entries
        message = "план импортирован: " + imported.name
    }

    private func save() {
        rules.savePlan(plan)
        message = "сохранено: " + name
    }
}

/// Экспорт/импорт плана: JSON и ссылка `throne://route?plan=…`.
struct RouteTransferView: View {
    @Environment(\.presentationMode) private var presentation
    @State private var text = ""
    @State private var error = ""

    let plan: RoutePlan
    let onImport: (RoutePlan) -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 10) {
                TextEditor(text: $text)
                    .font(.system(.caption2, design: .monospaced))
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground)))
                if !error.isEmpty {
                    Text(error).font(.caption).foregroundColor(.red)
                }
                HStack(spacing: 8) {
                    Button("JSON") { text = Self.encode(plan) }
                        .buttonStyle(.bordered)
                    Button("Ссылка") { text = Self.link(plan) }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Импорт") { importText() }
                        .buttonStyle(.borderedProminent)
                }
                .font(.caption)
            }
            .padding()
            .navigationTitle("Экспорт и импорт")
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
            .onAppear { if text.isEmpty { text = Self.encode(plan) } }
        }
        .navigationViewStyle(.stack)
    }

    private func importText() {
        guard let parsed = Self.decode(text) else {
            error = "не разобрать: нужен JSON плана или ссылка throne://route"
            return
        }
        error = ""
        onImport(parsed)
        presentation.wrappedValue.dismiss()
    }

    private static func encode(_ plan: RoutePlan) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(plan),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func link(_ plan: RoutePlan) -> String {
        let compact = encode(plan).replacingOccurrences(of: "\n", with: "")
        let encoded = compact.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? compact
        return "throne://route?plan=" + encoded
    }

    private static func decode(_ raw: String) -> RoutePlan? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("throne://"), let components = URLComponents(string: text),
           let value = components.queryItems?.first(where: { $0.name == "plan" })?.value,
           let data = value.data(using: .utf8) {
            return try? JSONDecoder().decode(RoutePlan.self, from: data)
        }
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RoutePlan.self, from: data)
    }
}
