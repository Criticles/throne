import Libbox
import SwiftUI

/// Настройки: подписки, параметры ядра, системный VPN, о приложении.
struct SettingsView: View {
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var engine: DevEngine

    @State private var coreVersion = ""

    var body: some View {
        NavigationView {
            List {
                subscriptionsSection
                coreSection
                vpnSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Настройки")
        }
        .navigationViewStyle(.stack)
    }

    private var subscriptionsSection: some View {
        Section {
            if store.subscriptions.isEmpty {
                Text("подписок нет — добавьте ссылку на экране «Серверы»")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(store.subscriptions) { subscription in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(subscription.name).font(.subheadline.weight(.medium))
                        Spacer()
                        Text("\(subscription.count)").font(.caption).foregroundColor(.secondary)
                    }
                    Text(Self.shortURL(subscription.url))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    if let updated = subscription.updated {
                        Text("обновлено \(Self.dateFormatter.string(from: updated))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button {
                        Task { await store.refresh(subscription) }
                    } label: {
                        Label("Обновить", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) {
                        store.remove(subscription)
                    } label: {
                        Label("Удалить подписку", systemImage: "trash")
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        store.remove(subscription)
                    } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                }
            }
        } header: {
            Text("Подписки")
        } footer: {
            Text("Долгое нажатие — обновить или удалить. Удаление подписки убирает и её серверы.")
        }
    }

    private var coreSection: some View {
        Section {
            HStack {
                Text("Ядро")
                Spacer()
                Text(coreVersion.isEmpty ? "…" : coreVersion)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Stepper(value: $engine.wireturnMTU, in: 1000...1420, step: 20) {
                HStack {
                    Text("MTU WireTurn")
                    Spacer()
                    Text("\(engine.wireturnMTU)")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            HStack {
                Text("Состояние")
                Spacer()
                Text(engine.running ? "подключено" : "выключено")
                    .font(.caption)
                    .foregroundColor(engine.running ? .green : .secondary)
            }
            if engine.running {
                Button(role: .destructive) {
                    engine.stop()
                } label: {
                    Text("Отключить ядро")
                }
            }
            Button(role: .destructive) {
                engine.clearLog()
            } label: {
                Text("Очистить журнал")
            }
        } header: {
            Text("Ядро dev-режима")
        } footer: {
            Text("MTU влияет только на WireTurn: поверх TURN и SRTP панельные 1280 фрагментируются, поэтому по умолчанию 1200.")
        }
        .onAppear {
            if coreVersion.isEmpty { coreVersion = LibboxVersion() }
        }
    }

    private var vpnSection: some View {
        Section {
            NavigationLink {
                ContentView()
            } label: {
                Label("VPN через Network Extension", systemImage: "shield.lefthalf.filled")
            }
        } header: {
            Text("Системный VPN")
        } footer: {
            Text("В LiveContainer без entitlement расширение не запускается: для проверки используйте dev-режим на экране «Серверы».")
        }
    }

    private var aboutSection: some View {
        Section {
            HStack {
                Text("Версия")
                Spacer()
                Text(Self.appVersion).foregroundColor(.secondary)
            }
            Link(destination: URL(string: "https://github.com/Criticles/throne")!) {
                Label("Исходники на GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
        } header: {
            Text("О приложении")
        } footer: {
            Text("Throne — клиент на ядре sing-box (форк throneproj) с Xray и WireTurn.")
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm"
        return formatter
    }()

    private static func shortURL(_ raw: String) -> String {
        guard let url = URL(string: raw) else { return raw }
        let host = url.host ?? raw
        let tail = url.lastPathComponent
        let masked = String(tail.prefix(4))
        return "\(host)/…/\(masked)…"
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }
}
