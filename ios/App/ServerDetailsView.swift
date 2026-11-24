import SwiftUI

/// «Сведения» о сервере: пинг, скорость, расход за всё время и параметры подключения.
/// Всё, что можно обновить, обновляется здесь же.
struct ServerDetailsView: View {
    @EnvironmentObject private var engine: DevEngine
    @EnvironmentObject private var store: ProfileStore
    @Environment(\.presentationMode) private var presentation

    @StateObject private var stats = TrafficStatsStore.shared

    let profile: Profile

    private var bulkRow: DevEngine.BulkRow? {
        engine.bulk.first { $0.id == profile.id }
    }

    private var speed: DevEngine.SpeedResult? {
        engine.speed[profile.id]
    }

    private var traffic: (up: Int64, down: Int64) {
        stats.total(profile: profile.name)
    }

    private var pingText: String {
        guard let row = bulkRow, let result = row.result else { return "не проверялся" }
        guard result.ok else { return ProbeResult.unavailable }
        let country = Probe.countryName(code: result.countryCode, fallback: result.country) ?? result.ip ?? ""
        let millis = result.millis.map { String($0) + " мс" } ?? ""
        return (country + " · " + millis).trimmingCharacters(in: .whitespaces)
    }

    private var speedText: String {
        guard let speed else { return "не измерялась" }
        let down = String(format: "↓ %.1f", speed.downMbps)
        let up = speed.upMbps > 0 ? String(format: " · ↑ %.1f", speed.upMbps) : ""
        return down + up + " Мбит/с"
    }

    private var trafficText: String {
        let up = ByteCountFormatter.string(fromByteCount: traffic.up, countStyle: .file)
        let down = ByteCountFormatter.string(fromByteCount: traffic.down, countStyle: .file)
        return "↑ " + up + " · ↓ " + down
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(alignment: .top) {
                        Text(profile.name).font(.subheadline.weight(.medium))
                        Spacer()
                        ProtocolBadge(text: profile.badge ?? profile.kind.title)
                    }
                    if let note = profile.userNote {
                        Text(note)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Сервер")
                }

                Section {
                    HStack {
                        Text("Пинг")
                        Spacer()
                        Text(pingText)
                            .font(.footnote)
                            .foregroundColor(bulkRow?.result?.ok == true ? Theme.pingColor(bulkRow?.result?.millis) : .secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Скорость")
                        Spacer()
                        Text(speedText)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Трафик за всё время")
                        Spacer()
                        Text(trafficText)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack(spacing: 8) {
                        PlaqueButton(title: "Пинг", icon: "waveform.path.ecg") {
                            Task { await engine.check(profile: profile) }
                        }
                        .disabled(engine.bulkRunning)
                        PlaqueButton(title: "Скорость", icon: "speedometer") {
                            Task { await engine.measureSpeed(profile: profile) }
                        }
                        .disabled(engine.speedRunning != nil || engine.bulkRunning)
                        Spacer()
                        if engine.speedRunning == profile.id || engine.bulkRunning {
                            ProgressView().scaleEffect(0.7)
                        }
                    }
                } header: {
                    Text("Показатели")
                } footer: {
                    Text("Пинг снимается по прогретому соединению. Замер скорости качает 10 МБ через этот сервер, поэтому активное соединение на время теста прерывается.")
                }

                Section {
                    ForEach(ServerInfo.rows(for: profile), id: \.0) { row in
                        HStack {
                            Text(row.0)
                            Spacer()
                            Text(row.1)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } header: {
                    Text("Настройки сервера")
                }

                Section {
                    Button {
                        store.select(profile.id)
                        engine.start(profile: profile, pool: store.profiles)
                        presentation.wrappedValue.dismiss()
                    } label: {
                        Label("Подключиться к этому серверу", systemImage: "power")
                    }
                    Button(role: .destructive) {
                        store.delete(profile)
                        presentation.wrappedValue.dismiss()
                    } label: {
                        Label("Удалить сервер", systemImage: "trash")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Сведения")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { presentation.wrappedValue.dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
