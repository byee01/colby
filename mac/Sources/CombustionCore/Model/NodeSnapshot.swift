import CombustionCodec
import Foundation

/// Firmware, hardware and model strings of a device, read from its Device Information service.
/// Any field is nil until read (or if the device does not provide it). docs/02 §3.
public struct DeviceInfo: Sendable, Equatable {
    public var firmware: String?
    public var hardware: String?
    public var model: String?

    public init(firmware: String? = nil, hardware: String? = nil, model: String? = nil) {
        self.firmware = firmware
        self.hardware = hardware
        self.model = model
    }

    public var isEmpty: Bool { firmware == nil && hardware == nil && model == nil }
}

/// What the UI knows about one MeatNet node (Display, Booster, ...). docs/02 §3.
///
/// `link` says how we hear the node: `.directConnection` while a `NodeLink` is up, otherwise
/// `.nodeAdvertisement` from its own advertisements (probes, hops and heartbeat are empty then).
public struct NodeSnapshot: Sendable, Equatable {
    public var serial: NodeSerial
    public var productType: NodeProductType
    /// Probes this node relayed recently, ascending. Only known while connected.
    public var probes: [ProbeSerial]
    /// Repeater network hops (1...4) from each of `probes` to this node.
    public var hopCounts: [ProbeSerial: Int]
    public var link: LinkSource
    public var isConnected: Bool
    public var firmware: DeviceInfo?
    /// Heartbeats (`0x49`) received on the current connection. The payload (network topology) is not decoded.
    public var heartbeatCount: Int
    public var lastHeartbeat: Date?

    public init(
        serial: NodeSerial, productType: NodeProductType, probes: [ProbeSerial] = [],
        hopCounts: [ProbeSerial: Int] = [:], link: LinkSource, isConnected: Bool = false,
        firmware: DeviceInfo? = nil, heartbeatCount: Int = 0, lastHeartbeat: Date? = nil
    ) {
        self.serial = serial
        self.productType = productType
        self.probes = probes
        self.hopCounts = hopCounts
        self.link = link
        self.isConnected = isConnected
        self.firmware = firmware
        self.heartbeatCount = heartbeatCount
        self.lastHeartbeat = lastHeartbeat
    }
}
