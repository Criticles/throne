import Libbox
import SwiftUI

/// Настройки: что крутит приложение, что импортировать, подписки, журнал и статистика.
struct SettingsView: View {
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var engine: DevEngine
    @EnvironmentObject private var prefs: Prefs

    var body: some View {
        NavigationView {
            List {
                coreSection
                protocolsSection
                subscriptionsSection
                networkSection
                journalSection
                vpnSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Настройки")
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Ядро

    private var coreSection: some View {
        Section {
            ForEach(CoreInfo.lines) { item in
                HStack(alignment: .top) {
                    Text(item.title).font(.subheadline)
                    Spacer()
                    Text(item.value)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.trailing)
                }
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
        } header: {
            Text("Ядра")
        } footer: {
            Text("sing-box — форк throneproj с WireTurn и AmneziaWG; Xray отвечает за VLESS + XHTTP, sing-box этот транспорт не умеет. MTU влияет только на WireTurn: поверх TURN и SRTP панельные 1280 фрагментируются.")
        }
    }

    // MARK: - Протоколы при импорте

    private var protocolsSection: some View {
        Section {
            ForEach(ProfileKind.allCases, id: \.self) { kind in
                Toggle(kind.title, isOn: Binding(
                    get: { store.allowedKinds.contains(kind) },
                    set: { isOn in
                        if isOn {
                            store.allowedKinds.insert(kind)
                        } else {
                            store.allowedKinds.remove(kind)
                        }
                    }
                ))
            }
        } header: {
            Text("Протоколы при импорте")
        } footer: {
            Text("Выключенные протоколы не попадают в список при импорте и обновлении подписки. Уже добавленные серверы остаются — их можно удалить вручную.")
        }
    }

    // MARK: - Подписки

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
                    Text(subscription.trafficText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if let expire = subscription.expire {
                        Text("до \(Self.dateFormatter.string(from: expire))")
                            .font(.caption2)
                            .foregroundColor(expire < Date() ? .red : .secondary)
                    }
                    Toggle("Автообновление каждые \(subscription.intervalHours) ч",
                           isOn: Binding(
                            get: { subscription.autoUpdate },
                            set: { on in store.setAutoUpdate(on, intervalHours: subscription.intervalHours, for: subscription) }
                           ))
                        .font(.caption)
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

    // MARK: - Сеть

    private var networkSection: some View {
        Section {
            Picker("DNS", selection: $prefs.dnsMode) {
                ForEach(Prefs.DNSMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            if prefs.dnsMode != .system {
                TextField("https://1.1.1.1/dns-query", text: $prefs.dnsServer)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .font(.system(.footnote, design: .monospaced))
            }
            Text(prefs.dnsMode.hint)
                .font(.caption2)
                .foregroundColor(.secondary)

            Picker("Стек TUN", selection: $prefs.tunStack) {
                ForEach(Prefs.TUNStack.allCases) { stack in
                    Text(stack.title).tag(stack)
                }
            }
            .pickerStyle(.segmented)

            Stepper(value: $prefs.tunMTU, in: 1280...9000, step: 20) {
                HStack {
                    Text("MTU туннеля")
                    Spacer()
                    Text("\(prefs.tunMTU)")
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
            Toggle("IPv6 в туннеле", isOn: $prefs.ipv6)
        } header: {
            Text("DNS и туннель")
        } footer: {
            Text("DNS применяется сразу. Стек, MTU и IPv6 включаются в конфиг сборки через Network Extension — в dev-режиме TUN не поднимается.")
        }
    }

    // MARK: - Журнал и статистика

    private var journalSection: some View {
        Section {
            NavigationLink {
                LogsView()
            } label: {
                Label("Журнал", systemImage: "text.alignleft")
            }
            NavigationLink {
                StatsView()
            } label: {
                Label("Статистика и правила", systemImage: "chart.bar")
            }
        } footer: {
            Text("В журнале — импорт и логи ядра, там же экспорт в txt. В статистике — сколько серверов отвечает, кто быстрее и по какому правилу пойдёт домен.")
        }
    }

    // MARK: - Системный VPN

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

    // MARK: - О приложении

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
        return host + "/…/" + String(tail.prefix(4)) + "…"
    }

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return short + " (" + build + ")"
    }
}
