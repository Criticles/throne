import SwiftUI

/// Куда положить значение из «Соединений»: профиль → папка → значение.
///
/// Схема (по макету):
///  • сверху только профили; папок не видно, пока профиль не выбран;
///  • у выбранного обычного профиля под списком появляется строка
///    «Outbound по умолчанию» — её можно заменить;
///  • у «Быстрых правил» такой строки нет: это служебный профиль;
///  • папки выбранного профиля идут ниже, у каждой свой выход (кроме
///    предустановленных Reject/Direct/Proxy — у них выход задан названием);
///  • «Добавить папку» раскрывает форму: название, кружок-галочка, выход.
struct RouteInsertSheet: View {
    @EnvironmentObject private var rules: RuleStore
    @EnvironmentObject private var store: ProfileStore
    @Environment(\.presentationMode) private var presentation

    let prefill: RouteInsertPrefill

    @State private var planID: UUID?
    @State private var folderID: UUID?

    @State private var showNewProfile = false
    @State private var newProfileName = ""
    @State private var newProfileOutbound = "proxy"

    /// Папки и профили, созданные в этом окне: только у них выход можно поменять.
    /// У давних папок плашка неактивна — иначе смена выхода молча перевела бы
    /// туда все уже лежащие в папке значения.
    /// Что именно меняем в открытом списке выходов: папку или профиль.
    /// Через `confirmationDialog`, а не `Menu`: у Menu в строке списка
    /// появляется лишняя стрелка справа от плашки.
    private struct OutboundTarget: Identifiable {
        let id = UUID()
        let planID: UUID
        let folderID: UUID?
    }

    @State private var picker: OutboundTarget?
    @State private var formTargetPicker = false

    @State private var freshFolders = Set<UUID>()
    @State private var freshPlans = Set<UUID>()

    @State private var showNewFolder = false
    /// Почему не удалось добавить — иначе кнопка «молчит».
    @State private var failure = ""
    @State private var newFolderName = ""
    @State private var newFolderOutbound = "proxy"

    private var plans: [RoutePlan] { rules.plans }

    private var current: RoutePlan? {
        guard let planID else { return nil }
        return plans.first { $0.id == planID }
    }

    private var folders: [RoutePlanRule] { current?.rules ?? [] }

    private var selectedFolder: RoutePlanRule? {
        guard let folderID else { return nil }
        return folders.first { $0.id == folderID }
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
                }

                profileSection

                if current != nil {
                    folderSection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Маршрутизация")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { presentation.wrappedValue.dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) { confirmButton }
            .confirmationDialog("Куда направить",
                                isPresented: Binding(get: { picker != nil },
                                                     set: { if !$0 { picker = nil } }),
                                titleVisibility: .visible) {
                ForEach(targets, id: \.self) { target in
                    Button(target) {
                        if let choice = picker {
                            if choice.folderID == nil {
                                setProfileOutbound(target)
                            } else {
                                setFolderOutbound(target, folderID: choice.folderID)
                            }
                        }
                        picker = nil
                    }
                }
                Button("Отмена", role: .cancel) { picker = nil }
            }
            .alert(isPresented: Binding(get: { !failure.isEmpty },
                                       set: { if !$0 { failure = "" } })) {
                Alert(title: Text("Не добавилось"),
                      message: Text(failure),
                      dismissButton: .default(Text("Понятно")))
            }
            .onAppear(perform: prepare)
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Профили

    private var profileSection: some View {
        Section {
            ForEach(plans) { plan in
                profileRow(plan)
                    // Подсветка = «этот профиль открыт», в том числе у «Быстрых правил».
                    .listRowBackground(planID == plan.id
                                       ? Theme.accent.opacity(0.14) : nil)
            }

            if showNewProfile {
                creationForm(name: $newProfileName,
                             placeholder: "Название профиля",
                             outbound: $newProfileOutbound,
                             action: { createProfile() },
                             onCancel: { newProfileName = ""; showNewProfile = false })
            } else if !showNewFolder {
                Button {
                    newProfileName = ""
                    newProfileOutbound = "proxy"
                    showNewProfile = true
                    showNewFolder = false
                } label: {
                    Label("Добавить профиль", systemImage: "plus")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
            }
        } header: {
            Text("Профили")
        } footer: {
            if current == nil {
                Text("Выбери профиль — ниже появятся его папки.")
            } else if current?.isSystem == true {
                Text("Быстрые правила всегда активны и приоритетнее основного профиля; "
                     + "своего outbound по умолчанию у них нет.")
            }
        }
    }

    private func profileRow(_ plan: RoutePlan) -> some View {
        // Кнопка и переключатель разделены: внутри `Button` переключатель не ловит тап.
        HStack(spacing: 10) {
            Button {
                planID = plan.id
                folderID = nil
                showNewProfile = false
                showNewFolder = false
                newFolderOutbound = plan.isSystem ? "proxy" : plan.finalTarget
            } label: {
                HStack(spacing: 10) {
                    // «Быстрые правила» не выбирают кружком: они стоят над профилем.
                    // Кружок есть только у обычных профилей.
                    if plan.isSystem {
                        Image(systemName: "bolt.horizontal.circle")
                            .font(.system(size: 15))
                            .foregroundColor(Color(uiColor: .tertiaryLabel))
                            .frame(width: 18, height: 18)
                    } else {
                        // Кружок — выбор профиля для добавления. Тумблер у «Быстрых
                        // правил» — это не выбор, а включение их папок в маршрутизацию.
                        radio(planID == plan.id)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plan.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(.primary)
                        Text(plan.isSystem
                             ? (plan.isEnabled
                                ? "проверяются раньше основного профиля"
                                : "выключены — трафик идёт по основному профилю")
                             : "папок: " + String(plan.rules.count))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if plan.isSystem {
                Toggle("", isOn: Binding(
                    get: { plan.isEnabled },
                    set: { rules.setEnabled(plan.id, $0) }
                ))
                .labelsHidden()
                .tint(Theme.accent)
                .scaleEffect(0.8)
            } else if planID == plan.id, freshPlans.contains(plan.id) {
                // Выход профиля меняем только у созданного в этом окне.
                Button {
                    picker = OutboundTarget(planID: plan.id, folderID: nil)
                } label: {
                    Text(plan.finalTarget)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(Theme.accent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.accent.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.borderless)
            } else if planID == plan.id {
                Text(plan.finalTarget)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(uiColor: .tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
    }

    // MARK: - Папки

    private var folderSection: some View {
        Section {
            ForEach(folders) { folder in
                folderRow(folder)
                    .listRowBackground(folderID == folder.id ? Theme.accent.opacity(0.14) : nil)
            }

            if showNewFolder {
                creationForm(name: $newFolderName,
                             placeholder: "Название папки",
                             outbound: $newFolderOutbound,
                             action: { createFolder() },
                             onCancel: { newFolderName = ""; showNewFolder = false })
            } else if !showNewProfile {
                Button {
                    newFolderName = ""
                    // Новая папка всегда начинается с proxy, а не с выхода профиля.
                    newFolderOutbound = "proxy"
                    showNewFolder = true
                    showNewProfile = false
                } label: {
                    Label(current?.isSystem == true
                          ? "Добавить папку с атрибутами"
                          : "Добавить папку",
                          systemImage: "folder.badge.plus")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
            }
        } header: {
            Text("Папки · " + (current?.name ?? ""))
        } footer: {
            if current?.isSystem == true {
                Text(current?.isEnabled == true
                     ? "Reject, Direct и Proxy менять нельзя — выход задан названием. Свои папки создаются как обычно."
                     : "Профиль выключен: правило добавится в папку, но применится, только когда включишь «Быстрые правила».")
            } else {
                Text("Выход папки меняется только у только что созданной — у остальных он закреплён.")
            }
        }
    }

    private func folderRow(_ folder: RoutePlanRule) -> some View {
        HStack(spacing: 10) {
            Button {
                folderID = folder.id
            } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.name)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        Text(valueCount(folder))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            outboundTail(folder)
        }
    }

    /// Ширина колонки выхода. Одна для всех папок, поэтому центры коротких значений
    /// и плашек с именем сервера лежат на одной вертикальной оси.
    private static let tailWidth: CGFloat = 190

    /// Выход папки справа: и `proxy`, и длинное имя сервера центрируются в своей колонке —
    /// одна ось на весь список. Имя сервера при нехватке места усекается, а не уезжает влево.
    @ViewBuilder
    private func outboundTail(_ folder: RoutePlanRule) -> some View {
        let text = folder.outbound

        if folder.locked {
            tailLabel(text, accent: false, boxed: false)
                .frame(width: Self.tailWidth, alignment: .center)
        } else if freshFolders.contains(folder.id) {
            Button {
                picker = OutboundTarget(planID: planID ?? folder.id, folderID: folder.id)
            } label: {
                tailLabel(text, accent: true, boxed: true)
                    .frame(width: Self.tailWidth, alignment: .center)
            }
            .buttonStyle(.borderless)
        } else {
            // Давняя папка: выход зафиксирован, чтобы не перевести разом все её значения.
            tailLabel(text, accent: false, boxed: true)
                .frame(width: Self.tailWidth, alignment: .center)
        }
    }

    /// Подпись выхода: голый текст у служебных, плашка у тех, что показываются в списке.
    private func tailLabel(_ text: String, accent: Bool, boxed: Bool) -> some View {
        Text(text)
            .font(accent ? .caption2.weight(.medium) : .caption2)
            .foregroundColor(accent ? Theme.accent : .secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, boxed ? 8 : 0)
            .padding(.vertical, boxed ? 4 : 0)
            .background(boxed
                        ? (accent ? Theme.accent.opacity(0.16) : Color(uiColor: .tertiarySystemFill))
                        : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    /// «значений: 3» — коротко, чтобы строка не разрасталась.
    /// Одинаково для обычных и служебных папок: подписи про «выход задан названием» нет.
    private func valueCount(_ folder: RoutePlanRule) -> String {
        let values = folder.attrs.filter { $0.attr != "outbound" }.count
        return values == 0 ? "значений нет" : "значений: " + String(values)
    }

    // MARK: - Формы

    /// Название, кружок-галочка, выход.
    /// Поля выровнены влево, у выхода снова есть подпись «Outbound».
    private func creationForm(name: Binding<String>, placeholder: String,
                              outbound: Binding<String>,
                              action: @escaping () -> Void,
                              onCancel: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            VStack(spacing: 0) {
                TextField(placeholder, text: name)
                    .font(.subheadline)
                    .padding(.vertical, 10)

                Divider()

                // Тот же выбор, что «Куда направить»: крупные строки вместо мелкого меню.
                Button {
                    formTargetPicker = true
                } label: {
                    HStack(spacing: 8) {
                        Text("Outbound")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text(outbound.wrappedValue)
                            .font(.caption.weight(.medium))
                            .foregroundColor(Theme.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.accent.opacity(0.16))
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .confirmationDialog("Куда направить", isPresented: $formTargetPicker, titleVisibility: .visible) {
                    ForEach(targets, id: \.self) { target in
                        Button(target) { outbound.wrappedValue = target }
                    }
                }
            }

            // Пустое поле — крестик: нажатие отменяет создание. Заполнили — галочка.
            let filled = !name.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Button(action: filled ? action : onCancel) {
                Image(systemName: filled ? "checkmark" : "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(filled ? Theme.accent : Color(uiColor: .systemGray2)))
            }
            .buttonStyle(.borderless)
        }
    }

    /// Тонкое кольцо; у выбранного — акцентная точка внутри.
    private func radio(_ selected: Bool) -> some View {
        ZStack {
            Circle()
                .strokeBorder(selected ? Theme.accent : Color(uiColor: .tertiaryLabel),
                              lineWidth: 1)
                .frame(width: 18, height: 18)
            if selected {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 8, height: 8)
            }
        }
    }

    // MARK: - Кнопка внизу

    private var confirmButton: some View {
        Button {
            save()
        } label: {
            Text(selectedFolder.map { "Добавить в «" + $0.name + "»" } ?? "Выбери папку")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selectedFolder == nil ? Theme.accent.opacity(0.25) : Theme.accent))
                .foregroundColor(selectedFolder == nil ? .secondary : .white)
        }
        .buttonStyle(.plain)
        .disabled(selectedFolder == nil)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .padding(.top, 6)
        .background(.ultraThinMaterial)
    }

    // MARK: - Действия

    private func prepare() {
        // Профиль намеренно не выбран: папки появляются только после нажатия,
        // иначе «Быстрые правила» выглядели открытыми сами по себе.
        guard planID == nil else { return }
        newFolderOutbound = "proxy"
    }

    private func setProfileOutbound(_ target: String) {
        guard var plan = current else { return }
        plan.finalTarget = target
        plan.updated = Date()
        rules.savePlan(plan)
        if !showNewFolder { newFolderOutbound = target }
    }

    private func setFolderOutbound(_ target: String, folderID: UUID?) {
        guard let folderID, var plan = current else { return }
        guard let index = plan.rules.firstIndex(where: { $0.id == folderID }) else { return }
        plan.rules[index].outbound = target
        plan.rules[index].action = target == "reject" ? "reject" : "route"
        if let attrIndex = plan.rules[index].attrs.firstIndex(where: { $0.attr == "outbound" }) {
            plan.rules[index].attrs[attrIndex].values = [target]
        }
        plan.updated = Date()
        rules.savePlan(plan)
    }

    private func createProfile() {
        let name = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var plan = rules.addPlan(name: name)
        plan.finalTarget = newProfileOutbound
        plan.updated = Date()
        rules.savePlan(plan)
        planID = plan.id
        freshPlans.insert(plan.id)
        folderID = nil
        newProfileName = ""
        showNewProfile = false
        newFolderOutbound = newProfileOutbound
    }

    private func createFolder() {
        guard let plan = current else { return }
        var updated = plan
        let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var folder = RoutePlanRule(name: name, outbound: newFolderOutbound)
        folder.action = newFolderOutbound == "reject" ? "reject" : "route"
        updated.rules.append(folder)
        updated.updated = Date()
        rules.savePlan(updated)
        folderID = folder.id
        freshFolders.insert(folder.id)
        newFolderName = ""
        showNewFolder = false
    }

    private func save() {
        guard let plan = current, let folder = selectedFolder else {
            failure = "Сначала выбери папку — значение добавляется только в неё."
            return
        }
        let value = prefill.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            failure = "Пустое значение — добавлять нечего."
            return
        }
        guard rules.addValue(value, attr: prefill.attr, to: plan.id, ruleID: folder.id) else {
            failure = "Папка «" + folder.name + "» не найдена в профиле «" + plan.name + "»."
            return
        }
        LogStore.shared.append("маршрут: «" + value + "» → " + plan.name + " / " + folder.name)
        presentation.wrappedValue.dismiss()
    }
}
