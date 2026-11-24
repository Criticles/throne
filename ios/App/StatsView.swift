import SwiftUI

/// Статистика: счётчики, скорость, трафик по серверам и проверка правила для домена.
struct StatsView: View {
    @EnvironmentObject private var engine: DevEngine
    @EnvironmentObject private var store: ProfileStore
    @EnvironmentObject private var rules: RuleStore
    @EnvironmentObject private var traffic: TrafficMonitor

    @StateObject private var stats = TrafficStatsStore.shared
    @State private var period = 7
    @State private var domain = ""

    var body: some View {
        List {
            countersSection
            speedSection
            trafficSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Статистика")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var checkedCount: Int {
        var count = 0
        for row in engine.bulk where row.done { count += 1 }
        return count
    }

    private var aliveCount: Int {
        var count = 0
        for row in engine.bulk where row.result?.ok == true { count += 1 }
        return count
    }

    private var trafficRows: [TrafficStatsStore.Row] {
        stats.summary(days: period)
    }

    private var countersSection: some View {
        Section {
            statRow("Серверов в списке", String(store.profiles.count))
            statRow("Проверено", String(checkedCount))
            statRow("Отвечает", String(aliveCount))
        } header: {
            Text("Счётчики")
        }
    }

    private var speedSection: some View {
        Section {
            SpeedGraph(down: traffic.down, up: traffic.up)
                .frame(height: 110)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
            HStack {
                Label(Self.rate(traffic.speedDown), systemImage: "arrow.down")
                    .foregroundColor(.green)
                Spacer()
                Label(Self.rate(traffic.speedUp), systemImage: "arrow.up")
                    .foregroundColor(.orange)
            }
            .font(.footnote.weight(.medium))
        } header: {
            HStack {
                Text("Скорость сейчас")
                Spacer()
                Text(traffic.live ? "live" : "нет данных")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        } footer: {
            Text("Срез раз в секунду из Clash API живого ядра: последние 60 секунд.")
        }
    }

    private var trafficSection: some View {
        Section {
            Picker("Период", selection: $period) {
                Text("7 дней").tag(7)
                Text("30 дней").tag(30)
            }
            .pickerStyle(.segmented)

            if trafficRows.isEmpty {
                Text("пока нечего показывать: трафик копится, пока приложение подключено")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            ForEach(trafficRows) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.profile)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text("↑ " + Self.size(item.up) + " · ↓ " + Self.size(item.down))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Трафик по серверам")
        }
    }

    private func statRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
        }
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func rate(_ bytesPerSecond: Double) -> String {
        let value = ByteCountFormatter.string(fromByteCount: Int64(max(bytesPerSecond, 0)), countStyle: .file)
        return value + "/с"
    }
}

/// Мини-график скорости: две линии по последним 60 срезам.
struct SpeedGraph: View {
    let down: [Double]
    let up: [Double]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill))
                line(values: down, peak: peak, size: geometry.size, color: .green)
                line(values: up, peak: peak, size: geometry.size, color: .orange)
            }
        }
    }

    private var peak: Double {
        let left = down.max() ?? 0
        let right = up.max() ?? 0
        let maximum = max(left, right)
        return maximum > 0 ? maximum : 1
    }

    private func line(values: [Double], peak: Double, size: CGSize, color: Color) -> some View {
        Path { path in
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(max(values.count - 1, 1))
            for index in values.indices {
                let x = CGFloat(index) * step
                let ratio = CGFloat(values[index] / peak)
                let y = size.height - ratio * (size.height - 8) - 4
                if index == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
        }
        .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
    }
}
