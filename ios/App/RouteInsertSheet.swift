import SwiftUI

/// Куда положить значение из «Соединений»: сверху профили маршрута, ниже — папки
/// с атрибутами выбранного профиля. Тап по папке сразу добавляет значение.
struct RouteInsertSheet: View {
    @EnvironmentObject private var rules: RuleStore
    @Environment(\.presentationMode) private var presentation

    let prefill: RouteInsertPrefill

    @State private var planID: UUID?

    private var plans: [RoutePlan] { rules.plans }

    /// Пока профиль не выбран вручную — берём активный профиль маршрута.
    private var current: RoutePlan? {
        if let planID {
            return plans.first { $0.id == planID } ?? plans.first
        }
        return plans.first { $0.id == rules.activePlanID } ?? plans.first
    }

    private var folders: [RoutePlanRule] { current?.rules ?? [] }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text(prefill.value)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                } header: {
                    Text(prefill.title.isEmpty ? "Из соединения" : prefill.title)
                } footer: {
                    Text("Атрибут «" + prefill.attr + "». Выберите профиль, затем папку — значение ляжет сразу.")
                }

                Section {
                    if plans.isEmpty {
                        Text("Профилей нет — создайте профиль на вкладке «Маршрут».")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    ForEach(plans) { plan in
                        Button {
                            planID = plan.id
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(plan.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundColor(.primary)
                                    Text(plan.summary)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer(minLength: 6)
                                if current?.id == plan.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(Theme.accent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Профиль")
                }

                Section {
                    if folders.isEmpty {
                        Text("В этом профиле нет папок с атрибутами.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    ForEach(folders) { folder in
                        Button {
                            add(folder)
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(folder.name)
                                        .font(.subheadline)
                                        .foregroundColor(.primary)
                                    Text(folder.subtitle)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer(minLength: 6)
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(Theme.accent)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Папки с атрибутами")
                } footer: {
                    if !folders.isEmpty {
                        Text("«" + prefill.value + "» попадёт в выбранную папку атрибутом «"
                             + prefill.attr + "», порядок папок не меняется.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Куда добавить")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { presentation.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func add(_ folder: RoutePlanRule) {
        guard let plan = current else { return }
        guard rules.addValue(prefill.value, attr: prefill.attr, to: plan.id,
                             ruleID: folder.id) else { return }
        LogStore.shared.append("маршрут: «" + prefill.value + "» → " + folder.name)
        presentation.wrappedValue.dismiss()
    }
}
