import SwiftUI

/// Создание цепочки: имя, звенья по порядку и папка, куда её положить.
/// Формат тот же, что у «Добавить профиль»: имя сверху, содержимое ниже.
struct ChainSheet: View {
    @EnvironmentObject private var store: ProfileStore
    @Environment(\.presentationMode) private var presentation

    /// Одно звено цепочки: подпись, исходный payload и бейдж протокола.
    struct Link: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let payload: String
        let badge: String
    }

    /// Куда положить цепочку: в новую папку (имя правится) или в существующую.
    private enum FolderMode: Equatable {
        case new
        case existing(UUID)
        case custom
    }

    @State private var name = ""
    @State private var links: [Link] = []
    @State private var mode: FolderMode = .new
    @State private var newFolderName = ""
    @State private var picking = false
    @State private var choosingFolder = false

    private var defaultFolderName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Цепочка" : name
    }

    private var folderChoiceTitle: String {
        switch mode {
        case .new: return "По умолчанию"
        case .existing(let id): return store.folder(id)?.name ?? "Куда добавить"
        case .custom: return "Новая папка"
        }
    }

    /// Имя новой папки показываем, пока выбрано «по умолчанию» или «новая папка».
    private var showsNameField: Bool {
        if case .existing = mode { return false }
        return true
    }

    private var canSave: Bool { links.count >= 2 }

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottom) {
                form
                if choosingFolder {
                    FolderChoiceSheet(
                        title: "Куда добавить",
                        defaultTitle: "По умолчанию",
                        defaultDetail: defaultFolderName,
                        options: store.folders.map { folder in
                            FolderChoiceSheet.Option(id: folder.id,
                                                     title: folder.name,
                                                     detail: String(store.count(in: folder.id)),
                                                     isDefault: false)
                        },
                        onDefault: {
                            mode = .new
                            closeFolderSheet()
                        },
                        onPick: { option in
                            mode = .existing(option.id)
                            closeFolderSheet()
                        },
                        onNew: {
                            mode = .custom
                            closeFolderSheet()
                        },
                        onCancel: { closeFolderSheet() }
                    )
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var form: some View {
        Form {
            Section {
                TextField("Название цепочки", text: $name)
            } header: {
                Text("Название")
            } footer: {
                Text("Например: «DE → FI · чистый выход». Имя можно не заполнять — подставится «Цепочка».")
            }

            Section {
                ForEach(links) { link in
                    // Индекс считаем по месту в массиве: ключевые пути к элементам
                    // кортежа Swift не поддерживает, поэтому enumerate тут не годится.
                    let index = links.firstIndex(of: link) ?? 0
                    HStack(spacing: 10) {
                        Text(String(index + 1))
                            .font(.caption2.weight(.bold))
                            .foregroundColor(Theme.accent)
                            .frame(width: 20, height: 20)
                            .background(Theme.accent.opacity(0.16))
                            .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(link.name).font(.subheadline)
                            Text(link.badge).font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer(minLength: 6)
                        if index == 0 {
                            Text("вход").font(.caption2).foregroundColor(.secondary)
                        } else if index == links.count - 1 {
                            Text("выход").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    links.remove(atOffsets: offsets)
                }
                .onMove { source, destination in
                    links.move(fromOffsets: source, toOffset: destination)
                }

                Button {
                    withAnimation(.easeOut(duration: 0.15)) { picking = true }
                } label: {
                    Label("Добавить звено", systemImage: "plus")
                        .font(.subheadline)
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Звенья · " + String(links.count))
            } footer: {
                Text("Порядок важен: первое звено — то, к чему подключается телефон, последнее — откуда трафик выходит в интернет. Переставить можно долгим нажатием.")
            }

            Section {
                // Имя новой папки — всегда активно и первым, как в «Новой подписке».
                TextField(defaultFolderName, text: $newFolderName)

                Button {
                    withAnimation(.easeOut(duration: 0.15)) { choosingFolder = true }
                } label: {
                    HStack {
                        Text("Или выбрать существующую")
                            .foregroundColor(.primary)
                        Spacer()
                        if case .existing(let id) = mode {
                            Text(store.folder(id)?.name ?? "")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text("Папка")
            } footer: {
                Text(showsNameField
                     ? "По умолчанию — новая папка с именем цепочки. Имя можно поменять прямо здесь."
                     : "Цепочка ляжет в выбранную папку, её имя не меняется.")
            }
        }
        .navigationTitle("Создать цепочку")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Отмена") { presentation.wrappedValue.dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить") { save() }
                    .disabled(!canSave)
            }
        }
        .overlay(
            Group {
                if picking {
                    PillChoiceSheet(
                        title: "Добавить звено",
                        items: store.profiles.filter { $0.kind != .chain }.map { profile in
                            PillChoiceSheet.Item(id: profile.id.uuidString,
                                                 title: profile.name,
                                                 detail: profile.badge ?? profile.kind.title,
                                                 accent: false)
                        },
                        extraTitle: nil,
                        onPick: { picked in
                            if let profile = store.profiles.first(where: { $0.id.uuidString == picked.id }) {
                                links.append(Link(name: profile.name,
                                                  payload: profile.payload,
                                                  badge: profile.badge ?? profile.kind.title))
                            }
                            withAnimation(.easeOut(duration: 0.15)) { picking = false }
                        },
                        onExtra: {},
                        onCancel: { withAnimation(.easeOut(duration: 0.15)) { picking = false } }
                    )
                }
            }
        )
    }

    private func closeFolderSheet() {
        withAnimation(.easeOut(duration: 0.15)) { choosingFolder = false }
    }

    private func save() {
        let payloads = links.map { ["name": $0.name, "payload": $0.payload] }
        var folder: UUID?
        switch mode {
        case .existing(let id):
            folder = id
        case .new, .custom:
            let typed = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
            folder = store.addFolder(name: typed.isEmpty ? defaultFolderName : typed).id
        }
        guard let created = store.addChain(name: name, links: payloads, folderID: folder) else { return }
        store.select(created.id)
        presentation.wrappedValue.dismiss()
    }
}
