import Foundation

/// Общие константы приложения и расширения.
/// При смене bundle id меняйте здесь, в ios/project.yml и в docs/apple-setup.md.
enum Shared {
    static let appGroup = "group.com.criticles.throne"
    static let tunnelBundleID = "com.criticles.throne.tunnel"
    static let logFileName = "tunnel.log"
    static let configFileName = "p0-config.json"

    /// Ключ в `providerConfiguration`, куда приложение кладёт конфиг sing-box.
    static let configKey = "configContent"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static var logURL: URL? {
        containerURL?.appendingPathComponent(logFileName)
    }

    static var configURL: URL? {
        containerURL?.appendingPathComponent(configFileName)
    }
}
