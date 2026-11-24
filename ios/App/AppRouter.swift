import SwiftUI

/// Что добавить в маршрутизацию из «Соединений»: атрибут и значение уже подставлены.
struct RouteInsertPrefill: Identifiable, Equatable {
    var id = UUID()
    var title = ""
    var attr = "domain"
    var value = ""
}

/// Переключение вкладок и переход из «Соединений» в маршрутизацию.
@MainActor
final class AppRouter: ObservableObject {
    /// 0 — Серверы, 1 — Маршрут, 2 — Соединения, 3 — Настройки.
    @Published var tab = 0
    @Published var insert: RouteInsertPrefill?

    func openRouting(with prefill: RouteInsertPrefill) {
        tab = 1
        insert = prefill
    }
}

/// Добавление адреса или домена в конкретное правило конкретного профиля.
struct RouteInsertView: View {
    @EnvironmentObject private var rules: RuleStore
    @Environment(\.presentationMode) private var presentation

    let prefill: RouteInsertPrefill

    @State private var planID: UUID?
    @State private var attr: String
    @State private var value: String
    @State private var target = "proxy"
    @State private var showAttributePicker = false

    init(prefill: RouteInsertPrefill) {
        self.prefill = prefill
        _attr = State(initialValue: prefill.attr)
        _value = State(initialValue: prefill.value)
    }

    private var targets: [String] { ["proxy", "direct", "reject"] }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    HStack {
                        Text(prefill.title.isEmpty ? prefill.value : prefill.title)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                } header: {
                    Text("Из соединения")
                }

                Section {
                    Picker("Профиль", selection: Binding(
                        get: { planID ?? rules.plan.id },
                        set: { planID = $0 }
                    )) {
                        ForEach(rules.plans) { plan in
                            Text(plan.name).tag(plan.id)
                        }
                    }
                    Button {
                        showAttributePicker = true
                    } label: {
                        HStack {
                            Text("Атрибут")
                            Spacer()
                            Text(attr).foregroundColor(.secondary)
                        }
                    }
                    TextField("Значение", text: $value)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.footnote, design: .monospaced))
                    Picker("Куда", selection: $target) {
                        ForEach(targets, id: \.self) { item in
                            Text(item).tag(item)
                        }
                    }
                } header: {
                    Text("Правило")
                } footer: {
                    Text("Запись добавится в конец списка профиля и сработает после правил, которые уже есть выше.")
                }
            }
            .navigationTitle("В маршрутизацию")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { presentation.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Добавить") { save() }
                        .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .sheet(isPresented: $showAttributePicker) {
                RouteAttributePicker { picked in
                    if picked != "outbound" { attr = picked }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            if planID == nil { planID = rules.plan.id }
        }
    }

    private func save() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = RoutePlanEntry(kind: "rule", attr: attr, value: trimmed, target: target)
        rules.addEntry(entry, to: planID ?? rules.plan.id)
        presentation.wrappedValue.dismiss()
    }
}
