import SwiftUI

/// Куда положить значение из «Соединений»: сверху профили маршрута, ниже — папки
/// с атрибутами выбранного профиля. Тап по папке сразу добавляет значение.
struct RouteInsertSheet: View {
    @EnvironmentObject private var rules: RuleStore
    @Environment(\.presentationMode) private var presentation

    let prefill: RouteInsertPrefill

    @State private var planID: UUID?
    @State private var folderID: UUID?

    private var plans: [RoutePlan] { rules.plans }

    /// Пока профиль не выбран вручную — берём активный профиль маршрута.
    /// Циклы вместо `first(where:) ?? first`: компилятор не тянул такое выражение.
    private var current: RoutePlan? {
        if let planID {
            for plan in plans where plan.id == planID { return plan }
        }
        if let active = rules.activePlanID {
            for plan in plans where plan.id == active { return plan }
        }
        return plans.isEmpty ? nil : plans[0]
    }

    private var folders: [RoutePlanRule] { current?.rules ?? [] }

    private var selectedFolder: RoutePlanRule? {
        guard let folderID else { return nil }
        return folders.first { $0.id == folderID }
    }

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
                            folderID = nil
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
                            folderID = folder.id
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
                                Image(systemName: selectedFolder?.id == folder.id
                                      ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selectedFolder?.id == folder.id
                                                     ? Theme.accent : Color(uiColor: .tertiaryLabel))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Папки с атрибутами")
                } footer: {
                    if !folders.isEmpty {
                        Text(foldersFooter)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("В правило")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { presentation.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }
                        .disabled(selectedFolder == nil)
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    /// Сохраняем только по кнопке: папку можно перевыбрать, ничего не добавив по ошибке.
    /// Подпись под папками: до выбора и после.
    private var foldersFooter: String {
        if let folder = selectedFolder {
            return "«" + prefill.value + "» попадёт в «" + folder.name + "» атрибутом «"
                + prefill.attr + "». Нажмите «Сохранить»."
        }
        return "Отметьте папку — атрибут «" + prefill.attr + "» ляжет в неё."
    }

    private func save() {
        guard let plan = current, let folder = selectedFolder else { return }
        guard rules.addValue(prefill.value, attr: prefill.attr, to: plan.id,
                             ruleID: folder.id) else { return }
        LogStore.shared.append("маршрут: «" + prefill.value + "» → " + folder.name)
        presentation.wrappedValue.dismiss()
    }
}
