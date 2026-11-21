import Foundation

/// Конфиг P0: только TUN + прямой выход.
/// Задача фазы — доказать, что дескриптор utun доходит до ядра и трафик идёт.
/// Никаких серверов, подписок и роутинга здесь ещё нет — это P1.
///
/// Формат соответствует sing-box 1.12+ (DNS-серверы — объектами с `type`/`server`),
/// на котором стоит форк throneproj/sing-box.
enum P0Config {
    static let json = """
    {
      "log": { "level": "info", "timestamp": true },
      "dns": {
        "servers": [
          { "type": "udp", "tag": "dns-direct", "server": "1.1.1.1" }
        ],
        "final": "dns-direct",
        "strategy": "ipv4_only"
      },
      "inbounds": [
        {
          "type": "tun",
          "tag": "tun-in",
          "address": ["172.19.0.1/30"],
          "mtu": 9000,
          "auto_route": true,
          "strict_route": false,
          "stack": "gvisor"
        }
      ],
      "outbounds": [
        { "type": "direct", "tag": "direct" }
      ],
      "route": {
        "auto_detect_interface": true,
        "final": "direct"
      }
    }
    """

    /// Кладём конфиг в App Group, чтобы расширение могло прочитать его,
    /// даже если запущено системой (из Настроек или по on-demand), без приложения.
    static func prepareInContainer() {
        guard let url = Shared.configURL else { return }
        try? json.write(to: url, atomically: true, encoding: .utf8)
    }

    static func loadFromContainer() -> String? {
        guard let url = Shared.configURL else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
