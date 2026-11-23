import SwiftUI

/// Маршрутизация: режим, обход локальной сети, правила, предпочтение Xray.
/// Часть настроек пока заготовка и честно помечена — в dev-режиме ядро шлёт всё в один сервер.
struct RoutingView: View {
    @EnvironmentObject private var prefs: Prefs

    var body: some View {
        NavigationView {
            List {
                Section {
                    Picker("Режим", selection: $prefs.routingMode) {
                        ForEach(Prefs.RoutingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)

                    Text(prefs.routingMode.hint)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } header: {
                    Text("Режим маршрутизации")
                }

                Section {
                    Toggle("Не пускать локальную сеть в туннель", isOn: $prefs.bypassLocalNetwork)
                    Toggle("Блокировать рекламу и трекеры", isOn: $prefs.blockAds)
                } footer: {
                    Text("Применяется в сборке через Network Extension. В dev-режиме весь трафик идёт в выбранный сервер.")
                }

                Section {
                    RuleRow(icon: "building.2", title: "Российские адреса", detail: "мимо туннеля")
                    RuleRow(icon: "house", title: "Локальная сеть 10.0.0.0/8, 192.168.0.0/16", detail: "мимо туннеля")
                    RuleRow(icon: "app.badge", title: "Правила по приложениям", detail: "позже")
                } header: {
                    Text("Правила")
                } footer: {
                    Text("Заготовка под редактор: будем добавлять адреса, домены и приложения по мере готовности NE-сборки.")
                }

                Section {
                    Picker("VLESS-профили", selection: $prefs.xrayPreference) {
                        ForEach(Prefs.XrayPreference.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                } header: {
                    Text("Xray")
                } footer: {
                    Text("Какие VLESS-серверы отдавать ядру Xray вместо sing-box: XHTTP он умеет, sing-box — нет.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Маршрут")
        }
        .navigationViewStyle(.stack)
    }
}

private struct RuleRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 22)
            Text(title).font(.subheadline)
            Spacer()
            Text(detail).font(.caption).foregroundColor(.secondary)
        }
    }
}
