import Foundation
import Libbox

/// Платформенная заглушка для запуска ядра **внутри приложения**.
///
/// В dev-режиме нет TUN: sing-box слушает локальный SOCKS, поэтому `openTun`
/// не вызывается вовсе. Всё остальное ядро может спросить — и получает
/// либо пустой ответ, либо понятную ошибку.
///
/// Набор методов повторяет `LibboxPlatformInterfaceProtocol` из ядра 183cf759:
/// там появились shell/SSH/SFTP/bridge/auto-redirect. На iOS они невозможны, поэтому
/// заглушки либо возвращают false/пустую строку, либо бросают ошибку — но сигнатуры
/// обязаны совпадать с протоколом дословно, иначе Swift не собирается.
final class DevPlatform: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private let onLog: (String) -> Void

    init(onLog: @escaping (String) -> Void) {
        self.onLog = onLog
        super.init()
    }

    private func unsupported(_ code: Int, _ text: String) -> NSError {
        NSError(domain: "com.criticles.throne.dev", code: code,
                userInfo: [NSLocalizedDescriptionKey: text])
    }

    // MARK: - TUN и сеть

    func openTun(_: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw unsupported(1, "dev-режим не использует TUN")
    }

    func usePlatformAutoDetectControl() -> Bool { false }
    func autoDetectControl(_: Int32) throws {}

    func findConnectionOwner(_: Int32, sourceAddress _: String?, sourcePort _: Int32,
                             destinationAddress _: String?, destinationPort _: Int32) throws -> LibboxConnectionOwner
    {
        throw unsupported(2, "владелец соединения недоступен на iOS")
    }

    func startDefaultInterfaceMonitor(_: LibboxInterfaceUpdateListenerProtocol?) throws {}
    func closeDefaultInterfaceMonitor(_: LibboxInterfaceUpdateListenerProtocol?) throws {}

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        throw unsupported(3, "getInterfaces не реализован")
    }

    func startNeighborMonitor(_: LibboxNeighborUpdateListenerProtocol?) throws {
        throw unsupported(4, "neighbor monitor недоступен на iOS")
    }

    func closeNeighborMonitor(_: LibboxNeighborUpdateListenerProtocol?) throws {}
    func registerMyInterface(_: String?) {}

    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }
    func underNetworkExtension() -> Bool { false }
    func includeAllNetworks() -> Bool { false }
    func readWIFIState() -> LibboxWIFIState? { nil }
    func clearDNSCache() {}
    func send(_: LibboxNotification?) throws {}
    func cancelNotification(_: String?, typeID _: Int32) throws {}

    // MARK: - Shell / SSH / bridge (только десктоп)

    func usePlatformShell() -> Bool { false }

    func checkPlatformShell() throws {
        throw unsupported(5, "shell на iOS недоступен")
    }

    func openShellSession(_: LibboxPlatformUser?, command _: String?, environ _: (any LibboxStringIteratorProtocol)?,
                          term _: String?, rows _: Int32, cols _: Int32) throws -> any LibboxShellSessionProtocol
    {
        throw unsupported(6, "shell на iOS недоступен")
    }

    func lookupUser(_: String?) throws -> LibboxPlatformUser {
        throw unsupported(7, "пользователи на iOS недоступны")
    }

    func lookupSFTPServer(_ error: NSErrorPointer) -> String {
        error?.pointee = unsupported(8, "sftp на iOS недоступен")
        return ""
    }

    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String {
        error?.pointee = unsupported(9, "ssh на iOS недоступен")
        return ""
    }

    func tailscaleHostname() -> String { "" }

    func usePlatformBridge() -> Bool { false }

    func createBridge(_: LibboxBridgeOptions?) throws -> any LibboxBridgeSessionProtocol {
        throw unsupported(10, "bridge на iOS недоступен")
    }

    func usePlatformAutoRedirect() -> Bool { false }

    func createAutoRedirect(_: Data?, handler _: (any LibboxAutoRedirectHandlerProtocol)?) throws -> any LibboxAutoRedirectSessionProtocol {
        throw unsupported(11, "auto-redirect на iOS недоступен")
    }

    // MARK: - CommandServerHandler

    func serviceStop() throws {
        onLog("core: serviceStop")
    }

    func serviceReload() throws {
        onLog("core: serviceReload")
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        throw unsupported(12, "системный прокси недоступен")
    }

    func setSystemProxyEnabled(_: Bool) throws {
        throw unsupported(13, "системный прокси недоступен")
    }

    func writeDebugMessage(_ message: String?) {
        if let message {
            onLog("core: \(message)")
        }
    }

    func connectSSHAgent(_: UnsafeMutablePointer<Int32>?) throws {
        throw unsupported(14, "ssh-agent на iOS недоступен")
    }

    func triggerNativeCrash() throws {
        throw unsupported(15, "native crash недоступен на iOS")
    }
}
