import SwiftUI

/// Куда положить значение из «Соединений»: профиль → папка → значение.
/// Профиль выбирается явно: пока он не выбран, папок не видно.
/// В служебных «Быстрых правилах» три папки-выхода (Reject/Direct/Proxy) не удаляются.
struct RouteInsertSheet: View {
    @EnvironmentObject private var rules: RuleStore
    @EnvironmentObject private var store: ProfileStore
    @Environment(\.presentationMode) private var presentation

    let prefill: RouteInsertPrefill

    @State private var planID: UUID?
    @State private var folderID: UUID?
    @State private var newFolder = ""
    @State private var newProfile = ""
    @State private var showNewFolder = false
    @State private var showNewProfile = false

    private var plans: [RoutePlan] { rules.plans }

    private var current: RoutePlan? {
        guard let planID else { return nil }
        for plan in plans where plan.id == planID { return plan }
        return nil
    }

    private var folders: [RoutePlanRule] { current?.rules ?? [] }

    private var selectedFolder: RoutePlanRule? {
        guard let folderID else { return nil }
        for folder in folders where folder.id == folderID { return folder }
        return nil
    }

    private var targets: [String] {
        var list = ["proxy", "direct", "reject"]
        for profile in store.profiles where !list.contains(profile.name) {
            list.append(profile.name)
        }
        return list
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text(prefill.value)
                        .font(.system(.footnote, design: .monospaced))
                } header: {
                    Text(prefill.title.isEmpty ? "Из соединения" : prefill.title)
                } footer: {
                    Text("Значение добавляется выбранной папке.")
                }

                Section {
                    ForEach(plans) { plan in
                        planRow(plan)
                    }
                    if showNewProfile {
                        TextField("Название профиля", text: $newProfile)
                        Button {
                            createProfile()
                        } label: {
                            Label("Создать профиль", systemImage: "plus.circle")
                        }
                        .disabled(newProfile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        Button {
                            newProfile = ""
                            showNewProfile = true
                        } label: {
                            Label("Новый профиль", systemImage: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                } header: {
                    Text("Профиль")
                } footer: {
                    if current == nil {
                        Text("Выберите профиль — ниже появятся его папки.")
                    } else if current?.isSystem == true {
                        Text("Быстрые правила всегда активны и приоритетнее основного профиля; "
                             + "своего outbound по умолчанию у них нет.")
                    }
                }

                if current != nil {
                    Section {
                        ForEach(folders) { folder in
                            folderRow(folder)
                        }
                        if showNewFolder {
                            TextField("Название папки", text: $newFolder)
                            Menu {
                                ForEach(targets, id: \.self) { target in
                                    Button(target) { createFolder(outbound: target) }
                                }
                            } label: {
                                Label("Создать папку и задать выход",
                                      systemImage: "folder.badge.plus")
                            }
                        } else {
                            Button {
                                newFolder = ""
                                showNewFolder = true
                            } label: {
                                Label("Новая папка", systemImage: "folder.badge.plus")
                            }
                            .buttonStyle(.borderless)
                        }
                    } header: {
                        Text("Папки")
                    } footer: {
                        Text("Папка без значений в конфиг ядра не попадает.")
                    }
                }

                if let folder = selectedFolder, !folder.locked {
                    Section {
                        Menu {
                            ForEach(targets, id: \.self) { target in
                                Button(target) { setOutbound(target, folder: folder) }
                            }
                        } label: {
                            HStack {
                                Text("Outbound папки")
                                Spacer()
                                Text(folder.outbound).foregroundColor(.secondary)
                            }
                        }
                    } header: {
                        Text("Выход выбранной папки")
                    } footer: {
                        Text("Меняется и для обычных профилей, и для своих папок быстрых правил.")
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
            .onAppear {
                if planID == nil { planID = rules.activePlanID }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Строки

    private func planRow(_ plan: RoutePlan) -> some View {
        Button {
            planID = plan.id
            folderID = nil
            showNewFolder = false
            showNewProfile = false
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.primary)
                    Text(plan.isSystem
                         ? "всегда активен · выше основного"
                         : "папок: " + String(plan.rules.count) + " · по умолчанию: " + plan.finalTarget)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 6)
                Image(systemName: planID == plan.id ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(planID == plan.id ? Theme.accent : Color(uiColor: .tertiaryLabel))
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func folderRow(_ folder: RoutePlanRule) -> some View {
        Button {
            folderID = folder.id
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    Text("выход: " + folder.outbound + " · значений: "
                         + String(folder.attrs.filter { $0.attr != "outbound" }.count))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 6)
                if folder.locked {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundColor(Color(uiColor: .tertiaryLabel))
                }
                Image(systemName: folderID == folder.id ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(folderID == folder.id ? Theme.accent : Color(uiColor: .tertiaryLabel))
            }
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Действия

    private func createProfile() {
        let name = newProfile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let plan = rules.addPlan(name: name)
        planID = plan.id
        folderID = nil
        newProfile = ""
        showNewProfile = false
    }

    private func createFolder(outbound: String) {
        guard let plan = current else { return }
        let name = newFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var updated = plan
        let folder = RoutePlanRule(name: name, outbound: outbound)
        updated.rules.append(folder)
        rules.savePlan(updated)
        folderID = folder.id
        newFolder = ""
        showNewFolder = false
    }

    private func setOutbound(_ target: String, folder: RoutePlanRule) {
        guard var plan = current else { return }
        guard let index = plan.rules.firstIndex(where: { $0.id == folder.id }) else { return }
        plan.rules[index].outbound = target
        plan.rules[index].action = target == "reject" ? "reject" : "route"
        if let attrIndex = plan.rules[index].attrs.firstIndex(where: { $0.attr == "outbound" }) {
            plan.rules[index].attrs[attrIndex].values = [target]
        }
        rules.savePlan(plan)
    }

    private func save() {
        guard let plan = current, let folder = selectedFolder else { return }
        let value = prefill.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        guard rules.addValue(value, attr: prefill.attr, to: plan.id, ruleID: folder.id) else { return }
        LogStore.shared.append("маршрут: «" + value + "» → " + plan.name + " / " + folder.name)
        presentation.wrappedValue.dismiss()
    }
}
