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

    /// Версия sing-box берётся из самого фреймворка, остальное — пины из CI.
    static var lines: [CoreLine] {
        [
            CoreLine(id: "singbox", title: "sing-box", value: LibboxVersion()),
            CoreLine(id: "fork", title: "форк", value: singboxRepo + " · " + singboxBranch),
            CoreLine(id: "xray", title: "Xray", value: "VLESS + XHTTP · " + xrayRepo),
            CoreLine(id: "wireturn", title: "WireTurn", value: wireturn),
        ]
    }
}
