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

    @State private var name = ""
    @State private var links: [Link] = []
    @State private var createFolder = true
    @State private var folderName = ""
    @State private var targetFolderID: UUID?
    @State private var picking = false
    @State private var choosingFolder = false

    private var canSave: Bool {
        links.count >= 2 && (createFolder || targetFolderID != nil)
    }

    var body: some View {
        NavigationView {
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
                        picking = true
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
                    Picker("Куда сохранить", selection: $createFolder) {
                        Text("В новую папку").tag(true)
                        Text("В существующую").tag(false)
                    }
                    .pickerStyle(.segmented)

                    if createFolder {
                        TextField("Имя папки", text: $folderName)
                    } else {
                        // Тот же вид выбора, что у «Куда направить»: крупные строки в диалоге.
                        Button {
                            choosingFolder = true
                        } label: {
                            HStack {
                                Text(store.folder(targetFolderID)?.name ?? "Выберите папку")
                                Spacer()
                                Text(String(store.count(in: targetFolderID)))
                                    .foregroundColor(.secondary)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Папка")
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
            .sheet(isPresented: $picking) {
                linkPicker
            }
            .confirmationDialog("Куда сохранить", isPresented: $choosingFolder, titleVisibility: .visible) {
                ForEach(store.folders) { folder in
                    Button(folder.name + " · " + String(store.count(in: folder.id))) {
                        targetFolderID = folder.id
                    }
                }
                Button("Новая папка") { createFolder = true }
            }
        }
        .navigationViewStyle(.stack)
    }

    /// Список серверов, из которых собираем цепочку.
    private var linkPicker: some View {
        NavigationView {
            List {
                ForEach(store.profiles.filter { $0.kind != .chain }) { profile in
                    Button {
                        let badge = profile.badge ?? profile.kind.title
                        links.append(Link(name: profile.name, payload: profile.payload, badge: badge))
                        picking = false
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).font(.subheadline)
                            Text(profile.badge ?? profile.kind.title)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Добавить звено")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { picking = false }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func save() {
        let payloads = links.map { ["name": $0.name, "payload": $0.payload] }
        var folder: UUID?
        if createFolder {
            let title = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
            folder = store.addFolder(name: title.isEmpty
                                     ? (name.isEmpty ? "Цепочка" : name)
                                     : title).id
        } else {
            folder = targetFolderID
        }
        guard let created = store.addChain(name: name, links: payloads, folderID: folder) else { return }
        store.select(created.id)
        presentation.wrappedValue.dismiss()
    }
}
