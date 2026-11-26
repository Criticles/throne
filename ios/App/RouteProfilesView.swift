import SwiftUI

/// Профили маршрутизации: несколько наборов правил, создание, импорт и экспорт.
/// Импорт сам понимает, что лежит в буфере — JSON профиля или ссылка `throne://route`.
struct RouteProfilesView: View {
    @EnvironmentObject private var rules: RuleStore
    @EnvironmentObject private var router: AppRouter

    /// Один лист на экран: iOS 15 держит только последний `.sheet` из цепочки.
    private enum Sheet: Identifiable {
        case newName, importPlan
        case export(RoutePlan)

        var id: String {
            switch self {
            case .newName: return "newName"
            case .importPlan: return "import"
            case .export(let plan): return "export-\(plan.id.uuidString)"
            }
        }
    }

    /// Заявка из «Соединений»: значение уже есть, остаётся выбрать профиль и папку.
    /// Меню вложенное — профиль, внутри папки: ни листов, ни переходов.
    @ViewBuilder
    private var insertSection: some View {
        if let pending = router.pendingInsert {
            Section {
                Text(pending.value)
                    .font(.system(.footnote, design: .monospaced))
                Menu {
                    ForEach(rules.plans) { plan in
                        Menu(plan.name) {
                            ForEach(plan.rules) { folder in
                                Button(folder.name + " · " + folder.subtitle) {
                                    add(pending, plan: plan.id, folder: folder)
                                }
                            }
                        }
                    }
                } label: {
                    Label("Выбрать профиль и папку", systemImage: "folder.badge.plus")
                }
                .disabled(rules.plans.isEmpty)
                Button("Отменить") { router.pendingInsert = nil }
            } header: {
                Text(pending.title.isEmpty ? "Из соединения" : pending.title)
            } footer: {
                Text("Профиль → папка с атрибутами: «" + pending.value + "» ляжет туда атрибутом «"
                     + pending.attr + "».")
            }
        }
    }

    private func add(_ pending: RouteInsertPrefill, plan: UUID, folder: RoutePlanRule) {
        guard rules.addValue(pending.value, attr: pending.attr, to: plan,
                             ruleID: folder.id) else { return }
        LogStore.shared.append("маршрут: «" + pending.value + "» → " + folder.name)
        router.pendingInsert = nil
    }

    @State private var sheet: Sheet?
    @State private var importText = ""
    @State private var newName = ""

    var body: some View {
        List {
            insertSection
            Section {
                if rules.plans.isEmpty {
                    Text("профилей нет — создайте новый или импортируйте")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                ForEach(rules.plans) { plan in
                    NavigationLink {
                        AdvancedRouteView(planID: plan.id)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(plan.name)
                                    .font(.subheadline.weight(.medium))
                                Text(plan.summary)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer(minLength: 6)
                            if rules.activePlanID == plan.id {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(Theme.accent)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            rules.deletePlan(plan.id)
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                        Button {
                            rules.activate(plan.id)
                        } label: {
                            Label("Активный", systemImage: "checkmark")
                        }
                        .tint(.green)
                    }
                    .contextMenu {
                        Button {
                            rules.activate(plan.id)
                        } label: {
                            Label("Сделать активным", systemImage: "checkmark.circle")
                        }
                        Button {
                            rules.duplicatePlan(plan.id)
                        } label: {
                            Label("Дублировать", systemImage: "plus.square.on.square")
                        }
                        Button {
                            sheet = .export(plan)
                        } label: {
                            Label("Экспорт", systemImage: "square.and.arrow.up")
                        }
                        Divider()
                        Button(role: .destructive) {
                            rules.deletePlan(plan.id)
                        } label: {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                }
            } header: {
                Text("Профили")
            } footer: {
                Text(rules.status.isEmpty
                     ? "Нажатие — редактор профиля. Галочка — активный профиль, он применяется к ядру."
                     : rules.status)
            }

            Section {
                Button {
                    newName = ""
                    sheet = .newName
                } label: {
                    Label("Новый профиль", systemImage: "plus.circle")
                }
                Button {
                    importFromClipboard()
                } label: {
                    Label("Импорт из буфера", systemImage: "doc.on.clipboard")
                }
                Button {
                    importText = ""
                    sheet = .importPlan
                } label: {
                    Label("Импорт JSON / Throne вручную", systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text("Импорт понимает JSON профиля, ссылку throne://route и base64 от JSON — формат определяется сам.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Профили маршрутизации")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheet) { item in
            switch item {
            case .newName:
                newNameSheet
            case .importPlan:
                importSheet
            case .export(let plan):
                RouteExportView(plan: plan)
            }
        }
    }

    private var newNameSheet: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Название профиля", text: $newName)
                } footer: {
                    Text("Профилей может быть сколько угодно: правила одного не мешают другому.")
                }
            }
            .navigationTitle("Новый профиль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { sheet = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                        rules.addPlan(name: trimmed.isEmpty ? "Профиль" : trimmed)
                        sheet = nil
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var importSheet: some View {
        RouteImportView(text: $importText) {
            if rules.importPlan(from: importText) != nil {
                sheet = nil
            }
        }
    }

    private func importFromClipboard() {
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        importText = text
        _ = rules.importPlan(from: text)
    }
}

/// Импорт профиля вручную: вставить текст, проверить и добавить.
struct RouteImportView: View {
    @EnvironmentObject private var rules: RuleStore
    @Environment(\.presentationMode) private var presentation

    @Binding var text: String
    let onImport: () -> Void

    var body: some View {
        NavigationView {
            VStack(spacing: 10) {
                TextEditor(text: $text)
                    .font(.system(.caption2, design: .monospaced))
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(uiColor: .secondarySystemBackground)))
                HStack(spacing: 8) {
                    Button("Из буфера") {
                        if let pasted = UIPasteboard.general.string { text = pasted }
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    Button("Импорт") { onImport() }
                        .buttonStyle(.borderedProminent)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .font(.caption)
            }
            .padding()
            .navigationTitle("Импорт профиля")
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

/// Экспорт профиля: JSON или ссылка Throne, с копированием.
struct RouteExportView: View {
    @Environment(\.presentationMode) private var presentation

    let plan: RoutePlan

    @State private var mode = 0

    private var text: String {
        mode == 0 ? RouteCodec.encode(plan) : RouteCodec.link(plan)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 10) {
                Picker("Формат", selection: $mode) {
                    Text("JSON").tag(0)
                    Text("Throne").tag(1)
                }
                .pickerStyle(.segmented)

                ScrollView {
                    Text(text)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground)))
            }
            .padding()
            .navigationTitle(plan.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { presentation.wrappedValue.dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        UIPasteboard.general.string = text
                    } label: {
                        Label("Скопировать", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
