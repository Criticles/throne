import SwiftUI

/// Расширенная маршрутизация: записи «правило → outbound» как в Throne на ПК,
/// плюс тот же план в JSON — можно вставить готовый и выгрузить свой.
struct AdvancedRouteView: View {
    @EnvironmentObject private var rules: RuleStore
    @EnvironmentObject private var store: ProfileStore
    @Environment(\.presentationMode) private var presentation

    @State private var finalTarget = "proxy"
    @State private var entries: [RoutePlanEntry] = []
    @State private var showJSON = false
    @State private var message = ""
    @State private var loaded = false

    private var targets: [String] {
        var list = ["proxy", "direct", "reject"]
        for profile in store.profiles where !list.contains(profile.name) {
            list.append(profile.name)
        }
        return list
    }

    var body: some View {
        Form {
            Section {
                Picker("Общий outbound", selection: $finalTarget) {
                    ForEach(targets, id: \.self) { target in
                        Text(target).tag(target)
                    }
                }
            } header: {
                Text("Куда всё остальное")
            } footer: {
                Text("Сюда идёт трафик, который не поймала ни одна запись. proxy — выбранный сервер, direct — напрямую, reject — блокировать.")
            }

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
                            TextField("geosite:ads, domain:example.com, ip_cidr:10.0.0.0/8", text: $entry.value)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .font(.system(.footnote, design: .monospaced))
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
                    Button {
                        entries.append(RoutePlanEntry(kind: "rule", value: "geosite:"))
                    } label: {
                        Label("Правило", systemImage: "line.3.horizontal.decrease")
                    }
                    Button {
                        entries.append(RoutePlanEntry(kind: "outbound", value: "direct"))
                    } label: {
                        Label("Outbound", systemImage: "arrow.turn.down.right")
                    }
                } label: {
                    Label("Добавить запись", systemImage: "plus.circle")
                }
            } header: {
                Text("Записи по порядку")
            } footer: {
                Text("Срабатывает первая подходящая запись. Формат правила: geosite:ads, geoip:ru, domain:example.com, suffix:example.com, keyword:ads, ip_cidr:10.0.0.0/8.")
            }

            Section {
                Button {
                    showJSON = true
                } label: {
                    Label("Открыть JSON", systemImage: "curlybraces")
                }
            } footer: {
                Text(message.isEmpty ? "JSON — тот же план в текстовом виде: можно вставить свой или забрать текущий." : message)
            }
        }
        .navigationTitle("Маршрутизация")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить") { save() }
            }
        }
        .sheet(isPresented: $showJSON) {
            RouteJSONView(plan: RoutePlan(finalTarget: finalTarget, entries: entries)) { plan in
                finalTarget = plan.finalTarget
                entries = plan.entries
                message = "план применён из JSON"
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            finalTarget = rules.plan.finalTarget
            entries = rules.plan.entries
        }
    }

    private func save() {
        rules.savePlan(RoutePlan(finalTarget: finalTarget, entries: entries))
        message = "сохранено: " + String(entries.count) + " записей"
    }
}

/// Текстовый редактор плана: вставить готовый JSON или скопировать текущий.
struct RouteJSONView: View {
    @Environment(\.presentationMode) private var presentation
    @State private var text = ""
    @State private var error = ""

    let plan: RoutePlan
    let onApply: (RoutePlan) -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 10) {
                TextEditor(text: $text)
                    .font(.system(.caption, design: .monospaced))
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground)))
                if !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                HStack(spacing: 10) {
                    Button("Сформировать из текущего") { text = Self.encode(plan) }
                        .buttonStyle(.bordered)
                    Spacer()
                    Button("Применить") { apply() }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("JSON плана")
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
            .onAppear {
                if text.isEmpty { text = Self.encode(plan) }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func apply() {
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(RoutePlan.self, from: data)
        else {
            error = "не разобрать JSON: нужны поля finalTarget и entries"
            return
        }
        error = ""
        onApply(parsed)
        presentation.wrappedValue.dismiss()
    }

    private static func encode(_ plan: RoutePlan) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(plan),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
