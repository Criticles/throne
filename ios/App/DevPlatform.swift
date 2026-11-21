import Foundation
import Libbox

/// Платформенная заглушка для запуска ядра **внутри приложения**.
///
/// В dev-режиме нет TUN: sing-box слушает локальный SOCKS, поэтому `openTun`
/// не вызывается вовсе. Всё остальное ядро может спросить — и получает
/// либо пустой ответ, либо понятную ошибку.
final class DevPlatform: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private let onLog: (String) -> Void

    init(onLog: @escaping (String) -> Void) {
        self.onLog = onLog
        super.init()
    }

    // MARK: - PlatformInterface

    func openTun(_: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw NSError(domain: "com.criticles.throne.dev", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "dev-режим не использует TUN"])
    }

    func usePlatformAutoDetectControl() -> Bool { false }
    func autoDetectControl(_: Int32) throws {}
    func useProcFS() -> Bool { false }

    func findConnectionOwner(_: Int32, sourceAddress _: String?, sourcePort _: Int32,
                             destinationAddress _: String?, destinationPort _: Int32) throws -> LibboxConnectionOwner
    {
        throw NSError(domain: "com.criticles.throne.dev", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "владелец соединения недоступен на iOS"])
    }

    func startDefaultInterfaceMonitor(_: LibboxInterfaceUpdateListenerProtocol?) throws {}

    func closeDefaultInterfaceMonitor(_: LibboxInterfaceUpdateListenerProtocol?) throws {}

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        throw NSError(domain: "com.criticles.throne.dev", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "getInterfaces не реализован"])
    }

    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }

    func underNetworkExtension() -> Bool { false }

    func includeAllNetworks() -> Bool { false }

    func readWIFIState() -> LibboxWIFIState? { nil }

    func systemCertificates() -> (any LibboxStringIteratorProtocol)? { nil }

    func clearDNSCache() {}

    func send(_: LibboxNotification?) throws {}

    // MARK: - CommandServerHandler

    func serviceStop() throws {
        onLog("core: serviceStop")
    }

    func serviceReload() throws {
        onLog("core: serviceReload")
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        throw NSError(domain: "com.criticles.throne.dev", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "системный прокси недоступен"])
    }

    func setSystemProxyEnabled(_: Bool) throws {
        throw NSError(domain: "com.criticles.throne.dev", code: 5,
                      userInfo: [NSLocalizedDescriptionKey: "системный прокси недоступен"])
    }

    func writeDebugMessage(_ message: String?) {
        if let message {
            onLog("core: \(message)")
        }
    }
}
