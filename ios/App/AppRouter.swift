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
        // Вкладку не переключаем сразу: смена таба и лист в одном кадре на iOS 15
        // проглатывают презентацию. На «Маршрут» уйдём после сохранения.
        insert = prefill
    }
}

/// Добавление значения в выбранную папку выбранного профиля маршрутизации.
///
/// Порядок как у настольного клиента: профиль → папка с атрибутами → значение.
/// Если папок в профиле ещё нет, её можно создать прямо здесь.
struct RouteInsertView: View {
    @EnvironmentObject private var rules: RuleStore
    @EnvironmentObject private var router: AppRouter
    @Environment(\.presentationMode) private var presentation

    let prefill: RouteInsertPrefill

    @State private var planID: UUID?
    @State private var ruleID: UUID?
    @State private var attr: String
    @State private var value: String
    @State private var newFolderName = ""
    @State private var showAttributePicker = false
    @State private var loadedPlan = false

    init(prefill: RouteInsertPrefill) {
        self.prefill = prefill
        _attr = State(initialValue: prefill.attr)
        _value = State(initialValue: prefill.value)
    }

    private var currentPlan: RoutePlan {
        rules.plan(with: planID) ?? rules.plan
    }

    private var folders: [RoutePlanRule] {
        currentPlan.rules
    }

    private var selectedFolder: RoutePlanRule? {
        guard let ruleID else { return nil }
        return folders.first { $0.id == ruleID }
    }

    private var canSave: Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedFolder != nil
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text(prefill.title.isEmpty ? prefill.value : prefill.title)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Text(prefill.value)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                } header: {
                    Text("Из соединения")
                }

                Section {
                    Picker("Профиль", selection: Binding(
                        get: { currentPlan.id },
                        set: { newValue in
                            planID = newValue
                            ruleID = rules.plan(with: newValue)?.rules.first?.id
                        }
                    )) {
                        ForEach(rules.plans) { plan in
                            Text(plan.name).tag(plan.id)
                        }
                    }

                    if folders.isEmpty {
                        TextField("Название новой папки", text: $newFolderName)
                        Button {
                            createFolder()
                        } label: {
                            Label("Создать папку с атрибутами", systemImage: "folder.badge.plus")
                        }
                        .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Picker("Папка с атрибутами", selection: Binding(
                            get: { ruleID ?? folders.first?.id },
                            set: { ruleID = $0 }
                        )) {
                            ForEach(folders) { folder in
                                Text(folder.name + " · " + folder.subtitle).tag(Optional(folder.id))
                            }
                        }
                    }
                } header: {
                    Text("Куда")
                } footer: {
                    Text(selectedFolder.map { "Значение ляжет в «\($0.name)», порядок остальных папок не меняется." }
                         ?? "Сначала выберите папку: в ней и будут условия правила.")
                }

                Section {
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
                } header: {
                    Text("Условие")
                } footer: {
                    Text("Если такого атрибута в папке ещё нет, он добавится сам.")
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
                        .disabled(!canSave)
                }
            }
            .sheet(isPresented: $showAttributePicker) {
                RouteAttributePicker { picked in
                    attr = picked
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear {
            guard !loadedPlan else { return }
            loadedPlan = true
            let start = planID ?? rules.plan.id
            planID = start
            ruleID = rules.plan(with: start)?.rules.first?.id
        }
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let plan = planID else { return }
        if let created = rules.addRule(named: name, to: plan) {
            ruleID = created.id
            newFolderName = ""
        }
    }

    private func save() {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let plan = planID, let folderID = ruleID ?? folders.first?.id else { return }
        guard folders.contains(where: { $0.id == folderID }) else { return }
        guard rules.addValue(trimmed, attr: attr, to: plan, ruleID: folderID) else { return }
        LogStore.shared.append("маршрут: «" + trimmed + "» → папка, атрибут " + attr)
        // Сначала закрываем лист, потом переключаем вкладку: смена таба под шторкой
        // на iOS 15 даёт повторную презентацию и падение.
        presentation.wrappedValue.dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            router.tab = 1
            router.insert = nil
        }
    }
}
