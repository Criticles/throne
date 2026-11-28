import Libbox
import SwiftUI

/// Настройки: что крутит приложение, что импортировать, подписки, журнал и статистика.
struct SettingsView: View {
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var engine: DevEngine
    @EnvironmentObject private var prefs: Prefs
    @EnvironmentObject private var updater: UpdateChecker
    @State private var showProtocols = false
    /// Тест живёт вне экрана: показываем его ход в строке «Диагностики».
    @ObservedObject private var tester = TrafficTester.shared

    var body: some View {
        NavigationView {
            List {
                coreSection
                protocolsSection
                subscriptionsSection
                networkSection
                measurementSection
                alertsSection
                journalSection
                diagnosticsSection
                vpnSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Настройки")
        }
        .navigationViewStyle(.stack)
        // Лист висит на корне: у `.sheet`, приклеенного к Section внутри List, первый показ
        // закрывается сам — Section пересоздаётся вместе с модификатором.
        .sheet(isPresented: $showProtocols) { protocolsSheet }
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
            HStack {
                Text("Состояние")
                Spacer()
                Text(engine.running ? "подключено · " + engine.activeCoreName : "выключено")
                    .font(.caption)
                    .foregroundColor(engine.running ? .green : .secondary)
                    .multilineTextAlignment(.trailing)
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
        }
    }

    // MARK: - Протоколы при импорте

    private var protocolsSection: some View {
        Section {
            Button {
                showProtocols = true
            } label: {
                HStack {
                    Text("Протоколы при импорте")
                    Spacer()
                    Text(protocolsSummary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        } footer: {
            Text("Открывается список всех протоколов, которые умеет приложение. Выключенные не попадают в список при импорте и обновлении подписки.")
        }
    }

    /// Подписка с самым близким сроком окончания.
    private var nearestExpiring: Subscription? {
        var best: Subscription?
        for subscription in store.subscriptions {
            guard let expire = subscription.expire else { continue }
            if let current = best?.expire {
                if expire < current { best = subscription }
            } else {
                best = subscription
            }
        }
        return best
    }

    private var protocolsSummary: String {
        let total = ProfileKind.allCases.count
        let allowed = store.allowedKinds.count
        return allowed == total ? "Все" : String(allowed) + " из " + String(total)
    }

    private var protocolsSheet: some View {
        NavigationView {
            List {
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
                } footer: {
                    Text("sing-box держит VLESS, VMess, Trojan, Shadowsocks, TUIC, Hysteria2, Mieru, MasterDNS, WireGuard, AmneziaWG и JSON-конфиг. Xray — VLESS + XHTTP. WireTurn/Turnable — TURN/SRTP с ключами WireGuard.")
                }
            }
            .navigationTitle("Протоколы")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { showProtocols = false }
                }
            }
        }
        .navigationViewStyle(.stack)
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
                    if subscription.expire != nil {
                        Text(Self.expiryText(subscription))
                            .font(.caption2)
                            .foregroundColor(Self.expiryColor(subscription))
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

    // MARK: - Пинг и скорость

    private var measurementSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("Адрес для пинга").font(.caption).foregroundColor(.secondary)
                TextField("https://1.1.1.1/cdn-cgi/trace", text: $prefs.pingTarget)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .font(.system(.footnote, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Скачивание").font(.caption).foregroundColor(.secondary)
                TextField("https://speed.cloudflare.com/__down", text: $prefs.speedURL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .font(.system(.footnote, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Отдача").font(.caption).foregroundColor(.secondary)
                TextField("https://speed.cloudflare.com/__up", text: $prefs.speedUploadURL)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .font(.system(.footnote, design: .monospaced))
            }
            Picker("Объём теста", selection: $prefs.speedMegabytes) {
                Text("5 МБ").tag(5)
                Text("10 МБ").tag(10)
                Text("25 МБ").tag(25)
            }
        } header: {
            Text("Пинг и скорость")
        } footer: {
            Text("Пинг меряется по этому адресу через Clash API. Скорость — скачивание и отдача файла указанного объёма через выбранный сервер.")
        }
    }

    // MARK: - Уведомления

    private var alertsSection: some View {
        Section {
            Toggle("Напомнить за 3 дня до конца подписки", isOn: $prefs.notifyExpiry)
            if let nearest = nearestExpiring {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ближайшее окончание").font(.subheadline)
                    Text(nearest.name + " · " + Self.dateFormatter.string(from: nearest.expire ?? Date()))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Уведомления")
        } footer: {
            Text("Уведомление ставит система: оно придёт, даже если приложение закрыто. Нужно разрешение на уведомления — iOS спросит при первом запуске.")
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
        } footer: {
            Text("В журнале — импорт и логи ядра, там же экспорт в txt. В статистике — сколько серверов отвечает, кто быстрее и по какому правилу пойдёт домен.")
        }
    }

    // MARK: - Системный VPN

    private var vpnSection: some View {
        Section {
            Toggle("Подключаться при запуске", isOn: $prefs.autoConnect)
            NavigationLink {
                ContentView()
            } label: {
                Label("VPN через Network Extension", systemImage: "shield.lefthalf.filled")
            }
        } header: {
            Text("Системный VPN")
        } footer: {
            Text("Автоподключение поднимает туннель при запуске приложения, если выбран сервер. В LiveContainer без entitlement расширение не запускается: для проверки используйте dev-режим на экране «Серверы».")
        }
    }

    // MARK: - Диагностика

    /// Прогон трафика через сервер: нужен, чтобы сверить счётчики приложения с ядром.
    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                TrafficTestView()
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "speedometer")
                        .foregroundColor(Theme.accent)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Тест трафика").font(.subheadline.weight(.medium))
                        Text(tester.running
                             ? "идёт: " + Format.size(tester.downloaded) + " из " + Format.size(tester.total)
                             : "прокачать объём через сервер и сверить счётчики")
                            .font(.caption2)
                            .foregroundColor(tester.running ? Theme.accent : .secondary)
                    }
                }
            }
        } header: {
            Text("Диагностика")
        } footer: {
            Text("Тест расходует трафик сервера — как обычная загрузка.")
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
            // Метка сборки: без неё по присланному логу нельзя понять, какая версия на телефоне,
            // и одинаковые симптомы в старой и новой сборке выглядят как «не исправили».
            HStack {
                Text("Сборка")
                Spacer()
                Text(Self.buildStamp).foregroundColor(.secondary)
            }
            HStack {
                Text("Обновление")
                Spacer()
                Text(updater.status.isEmpty ? "не проверялось" : updater.status)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.trailing)
            }
            Button {
                Task { await updater.check() }
            } label: {
                Label(updater.checking ? "Проверяю…" : "Проверить обновление", systemImage: "arrow.down.circle")
            }
            .disabled(updater.checking)
            if let release = updater.available {
                Link(destination: release.url) {
                    Label("Скачать " + release.version, systemImage: "square.and.arrow.down")
                }
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

    private static func expiryText(_ subscription: Subscription) -> String {
        guard let expire = subscription.expire else { return "" }
        let left = SubscriptionAlerts.daysLeft(subscription) ?? 0
        let date = dateFormatter.string(from: expire)
        if left < 0 { return "истекла " + date }
        return "до " + date + " · осталось " + String(left) + " дн."
    }

    private static func expiryColor(_ subscription: Subscription) -> Color {
        let left = SubscriptionAlerts.daysLeft(subscription) ?? 0
        if left < 0 { return .red }
        if left <= 3 { return .orange }
        return .secondary
    }

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

    /// Коммит, из которого собрано приложение (CI пишет его в Info.plist).
    private static var buildStamp: String {
        (Bundle.main.infoDictionary?["ThroneBuild"] as? String) ?? "локальная"
    }
}
