import Foundation
import Libbox
import Network
import NetworkExtension

/// Реализация `libbox.PlatformInterface` для iOS.
///
/// Ядро вызывает эти методы само: `openTun` — чтобы получить дескриптор utun,
/// `startDefaultInterfaceMonitor` — чтобы узнать, через какой интерфейс выходить в сеть.
/// В P0 часть методов-заглушек (владелец соединения, WiFi, интерфейсы) — на iOS они либо
/// невозможны, либо нужны только для правил по приложениям; см. комментарии.
final class PlatformInterface: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private let provider: NEPacketTunnelProvider
    private var pathMonitor: Network.NWPathMonitor?
    private var lastPathDescription = ""

    init(provider: NEPacketTunnelProvider) {
        self.provider = provider
        super.init()
    }

    // MARK: - TUN

    func openTun(_ options: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        guard let options, let ret0_ else {
            throw NSError(domain: "com.criticles.throne.tunnel", code: 10,
                          userInfo: [NSLocalizedDescriptionKey: "openTun: пустые аргументы"])
        }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: options.getMTU())

        if options.getAutoRoute() {
            // В libbox нет getDNSMode: ядро отдаёт один адрес DNS-хайджека (адрес TUN + 1).
            if let dnsBox = try? options.getDNSServerAddress() {
                settings.dnsSettings = NEDNSSettings(servers: [dnsBox.value])
            }

            // IPv4
            var v4Addresses: [String] = []
            var v4Masks: [String] = []
            if let iterator = options.getInet4Address() {
                while iterator.hasNext() {
                    if let prefix = iterator.next() {
                        v4Addresses.append(prefix.address())
                        v4Masks.append(prefix.mask())
                    }
                }
            }

            let ipv4 = NEIPv4Settings(addresses: v4Addresses, subnetMasks: v4Masks)
            var v4Included: [NEIPv4Route] = []
            if let iterator = options.getInet4RouteAddress(), iterator.hasNext() {
                while iterator.hasNext() {
                    if let prefix = iterator.next() {
                        v4Included.append(NEIPv4Route(destinationAddress: prefix.address(),
                                                      subnetMask: prefix.mask()))
                    }
                }
            } else {
                v4Included.append(NEIPv4Route.default())
            }
            var v4Excluded: [NEIPv4Route] = []
            if let iterator = options.getInet4RouteExcludeAddress() {
                while iterator.hasNext() {
                    if let prefix = iterator.next() {
                        v4Excluded.append(NEIPv4Route(destinationAddress: prefix.address(),
                                                      subnetMask: prefix.mask()))
                    }
                }
            }
            ipv4.includedRoutes = v4Included
            ipv4.excludedRoutes = v4Excluded
            settings.ipv4Settings = ipv4

            // IPv6
            var v6Addresses: [String] = []
            var v6Prefixes: [NSNumber] = []
            if let iterator = options.getInet6Address() {
                while iterator.hasNext() {
                    if let prefix = iterator.next() {
                        v6Addresses.append(prefix.address())
                        v6Prefixes.append(NSNumber(value: prefix.prefix()))
                    }
                }
            }
            if !v6Addresses.isEmpty {
                let ipv6 = NEIPv6Settings(addresses: v6Addresses, networkPrefixLengths: v6Prefixes)
                var v6Included: [NEIPv6Route] = []
                if let iterator = options.getInet6RouteAddress(), iterator.hasNext() {
                    while iterator.hasNext() {
                        if let prefix = iterator.next() {
                            v6Included.append(NEIPv6Route(destinationAddress: prefix.address(),
                                                          networkPrefixLength: NSNumber(value: prefix.prefix())))
                        }
                    }
                } else {
                    v6Included.append(NEIPv6Route.default())
                }
                var v6Excluded: [NEIPv6Route] = []
                if let iterator = options.getInet6RouteExcludeAddress() {
                    while iterator.hasNext() {
                        if let prefix = iterator.next() {
                            v6Excluded.append(NEIPv6Route(destinationAddress: prefix.address(),
                                                          networkPrefixLength: NSNumber(value: prefix.prefix())))
                        }
                    }
                }
                ipv6.includedRoutes = v6Included
                ipv6.excludedRoutes = v6Excluded
                settings.ipv6Settings = ipv6
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        var settingsError: Error?
        provider.setTunnelNetworkSettings(settings) { error in
            settingsError = error
            semaphore.signal()
        }
        semaphore.wait()

        if let settingsError {
            TunnelLog.write("openTun: setTunnelNetworkSettings — \(settingsError.localizedDescription)")
            throw settingsError
        }

        // Первый способ — напрямую из packetFlow (так делает sing-box-for-apple),
        // второй — поиск utun по control-имени внутри libbox (tun_darwin.go).
        if let tunFD = provider.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32, tunFD > 0 {
            TunnelLog.write("openTun: fd \(tunFD) из packetFlow")
            ret0_.pointee = tunFD
            return
        }
        let loopFD = LibboxGetTunnelFileDescriptor()
        if loopFD != -1 {
            TunnelLog.write("openTun: fd \(loopFD) из LibboxGetTunnelFileDescriptor")
            ret0_.pointee = loopFD
            return
        }

        TunnelLog.write("openTun: дескриптор utun не найден")
        throw NSError(domain: "com.criticles.throne.tunnel", code: 11,
                      userInfo: [NSLocalizedDescriptionKey: "не найден файловый дескриптор utun"])
    }

    // MARK: - Прочее из PlatformInterface

    func usePlatformAutoDetectControl() -> Bool { false }

    func autoDetectControl(_: Int32) throws {}

    func useProcFS() -> Bool { false }

    /// Владельца соединения на iOS определить нельзя — отсюда нет правил «по приложению».
    func findConnectionOwner(_: Int32, sourceAddress _: String?, sourcePort _: Int32,
                             destinationAddress _: String?, destinationPort _: Int32) throws -> LibboxConnectionOwner
    {
        throw NSError(domain: "com.criticles.throne.tunnel", code: 12,
                      userInfo: [NSLocalizedDescriptionKey: "findConnectionOwner недоступен на iOS"])
    }

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { return }
        let monitor = Network.NWPathMonitor()
        pathMonitor = monitor
        let semaphore = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { [weak self] path in
            self?.publish(path, to: listener)
            semaphore.signal()
            monitor.pathUpdateHandler = { [weak self] path in
                self?.publish(path, to: listener)
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .utility))
        semaphore.wait()
    }

    func closeDefaultInterfaceMonitor(_: LibboxInterfaceUpdateListenerProtocol?) throws {
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathDescription = ""
    }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        throw NSError(domain: "com.criticles.throne.tunnel", code: 13,
                      userInfo: [NSLocalizedDescriptionKey: "getInterfaces не реализован в P0"])
    }

    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? { nil }

    func underNetworkExtension() -> Bool { true }

    func includeAllNetworks() -> Bool { false }

    func readWIFIState() -> LibboxWIFIState? { nil }

    func systemCertificates() -> (any LibboxStringIteratorProtocol)? { nil }

    func clearDNSCache() {}

    // gomobile генерирует для Go-метода SendNotification селектор send(_:)
    func send(_: LibboxNotification?) throws {}

    // MARK: - CommandServerHandler

    func serviceStop() throws {
        TunnelLog.write("commandServer: serviceStop")
    }

    func serviceReload() throws {
        TunnelLog.write("commandServer: serviceReload")
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        throw NSError(domain: "com.criticles.throne.tunnel", code: 14,
                      userInfo: [NSLocalizedDescriptionKey: "системный прокси на iOS недоступен"])
    }

    func setSystemProxyEnabled(_: Bool) throws {
        throw NSError(domain: "com.criticles.throne.tunnel", code: 15,
                      userInfo: [NSLocalizedDescriptionKey: "системный прокси на iOS недоступен"])
    }

    func writeDebugMessage(_ message: String?) {
        if let message {
            TunnelLog.write("core: \(message)")
        }
    }

    // MARK: - Сеть

    private func publish(_ path: Network.NWPath, to listener: LibboxInterfaceUpdateListenerProtocol) {
        let description = describe(path)
        if description == lastPathDescription {
            return
        }
        lastPathDescription = description
        guard path.status == .satisfied, let interface = path.availableInterfaces.first else {
            listener.updateDefaultInterface("", interfaceIndex: -1,
                                           isExpensive: false, isConstrained: false)
            return
        }
        listener.updateDefaultInterface(interface.name,
                                        interfaceIndex: Int32(interface.index),
                                        isExpensive: path.isExpensive,
                                        isConstrained: path.isConstrained)
    }

    private func describe(_ path: Network.NWPath) -> String {
        var parts: [String] = []
        parts.append(path.status == .satisfied ? "satisfied" : "unsatisfied")
        if let interface = path.availableInterfaces.first {
            parts.append("\(interface.name)#\(interface.index)")
        }
        if path.isExpensive { parts.append("expensive") }
        if path.isConstrained { parts.append("constrained") }
        return parts.joined(separator: " ")
    }
}
