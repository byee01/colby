import Foundation

/// Opaque platform peripheral identifier (CBPeripheral UUID string on macOS).
public struct PeripheralId: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public enum BluetoothState: String, Sendable, Codable, Equatable {
    case poweredOn, poweredOff, unauthorized, unsupported
}

public struct RawAdvertisement: Sendable, Equatable {
    public var peripheral: PeripheralId
    /// Manufacturer-specific data including the 2-byte company ID (0x09C7, little-endian).
    public var mfrData: [UInt8]
    public var rssi: Int
    public var time: Date

    public init(peripheral: PeripheralId, mfrData: [UInt8], rssi: Int, time: Date) {
        self.peripheral = peripheral
        self.mfrData = mfrData
        self.rssi = rssi
        self.time = time
    }
}

/// Normalized (uppercase) GATT UUID string. Constants from docs/01 §2.
public struct GattUUID: Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue.uppercased() }
    public init(stringLiteral value: String) { self.init(value) }
    public var description: String { rawValue }

    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static let probeStatusService: GattUUID = "00000100-CAAB-3792-3D44-97AE51C1407A"
    public static let probeStatus: GattUUID = "00000101-CAAB-3792-3D44-97AE51C1407A"

    public static let uartService: GattUUID = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    /// App writes requests here.
    public static let uartRX: GattUUID = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
    /// Responses and node notifications arrive here.
    public static let uartTX: GattUUID = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"

    /// 0x180A on probes; node documentation says 0x181A (unverified).
    public static let deviceInformationService: GattUUID = "180A"
    public static let manufacturerName: GattUUID = "2A29"
    public static let modelNumber: GattUUID = "2A24"
    public static let serialNumber: GattUUID = "2A25"
    public static let hardwareRevision: GattUUID = "2A27"
    public static let firmwareRevision: GattUUID = "2A26"
}

public enum CombustionVendor {
    /// Bluetooth company identifier used in manufacturer data.
    public static let companyId: UInt16 = 0x09C7
}

public struct GattService: Sendable, Equatable {
    public var uuid: GattUUID
    public var characteristics: [GattUUID]
    public init(uuid: GattUUID, characteristics: [GattUUID]) {
        self.uuid = uuid
        self.characteristics = characteristics
    }
}

public enum DisconnectReason: String, Sendable, Codable, Equatable {
    case requested, linkLost, timeout, bluetoothOff
}

public enum TransportError: Error, Sendable, Equatable {
    case notPoweredOn(BluetoothState)
    case timeout
    case connectionRefused(PeripheralId)
    case alreadyConnected(PeripheralId)
    case disconnected
    case characteristicNotFound(GattUUID)
    case operationFailed(String)
}

/// Platform boundary (docs/02 §5.1). Only implementations of this touch OS Bluetooth APIs.
public protocol BleTransport: Sendable {
    /// Current state first, then changes.
    var state: AsyncStream<BluetoothState> { get }
    var advertisements: AsyncStream<RawAdvertisement> { get }
    func startScan() async
    func stopScan() async
    func connect(_ id: PeripheralId, timeout: Duration) async throws -> any GattConnection
}

public protocol GattConnection: Sendable {
    var peripheral: PeripheralId { get }
    var mtu: Int { get }
    /// Yields at most one reason, then finishes.
    var disconnected: AsyncStream<DisconnectReason> { get }
    func discover() async throws -> [GattService]
    func read(_ characteristic: GattUUID) async throws -> [UInt8]
    func write(_ characteristic: GattUUID, _ bytes: [UInt8], withResponse: Bool) async throws
    /// Enables notifications. The stream finishes on disconnect.
    func subscribe(_ characteristic: GattUUID) async throws -> AsyncStream<[UInt8]>
    func close() async
}
