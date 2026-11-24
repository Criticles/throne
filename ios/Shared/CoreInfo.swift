import Foundation
import Libbox

/// Строка таблицы «что за ядро»: подпись и значение.
struct CoreLine: Identifiable {
    let id: String
    let title: String
    let value: String
}

/// Что именно крутит приложение — чтобы это было видно в настройках, а не только в README.
enum CoreInfo {
    static let singboxRepo = "throneproj/sing-box"
    static let singboxBranch = "wip/1.15.0-alpha.13-resync"
    static let xrayRepo = "throneproj/xray-core"
    static let wireturn = "Turnable v0.8.7 + WireGuard"
    static let turnableVersion = "v0.8.7"

    /// Версия sing-box берётся из самого фреймворка, остальное — пины из CI.
    static var lines: [CoreLine] {
        [
            CoreLine(id: "singbox", title: "sing-box", value: "throneproj/sing-box"),
            CoreLine(id: "xray", title: "Xray", value: "throneproj/xray"),
            CoreLine(id: "turnable", title: "WireTurn", value: "Turnable"),
        ]
    }
}
