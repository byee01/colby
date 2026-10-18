import CombustionCodec
import Foundation

// Shared types between Links (producers) and Stores (consumers). docs/02 §3, §5, §6.

public typealias NodeSerial = String

/// One path that delivers data for a probe. docs/02 §3 LinkSource.
public struct LinkSource: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Hashable {
        case advertisement, directConnection, nodeConnection, nodeAdvertisement
    }
    public var kind: Kind
    public var via: NodeSerial?
    public var hopCount: Int?
    public var rssi: Int?
    public var highRadioPower: Bool?
    public var lastSeen: Date

    public init(kind: Kind, via: NodeSerial? = nil, hopCount: Int? = nil, rssi: Int? = nil,
                highRadioPower: Bool? = nil, lastSeen: Date) {
        self.kind = kind
        self.via = via
        self.hopCount = hopCount
        self.rssi = rssi
        self.highRadioPower = highRadioPower
        self.lastSeen = lastSeen
    }

    /// Identity of the path, ignoring per-packet values (rssi, lastSeen).
    public var pathKey: PathKey { PathKey(kind: kind, via: via) }

    public struct PathKey: Sendable, Hashable {
        public var kind: Kind
        public var via: NodeSerial?
    }
}

public struct LinkInfo: Sendable, Equatable {
    public var sources: [LinkSource]
    public var primary: LinkSource?
    public init(sources: [LinkSource] = [], primary: LinkSource? = nil) {
        self.sources = sources
        self.primary = primary
    }
}

/// What a link reports about one probe. Links emit these; ProbeStore merges them.
public struct ProbeObservation: Sendable, Equatable {
    public enum Payload: Sendable, Equatable {
        /// Advertisement data only (no prediction, alarms, session).
        case advertisement(ProbeAdvertisement)
        /// Full status from GATT Probe Status or node 0x45.
        case status(ProbeStatusPayload)
    }
    public var serial: ProbeSerial
    public var source: LinkSource
    public var payload: Payload
    public var receivedAt: Date

    public init(serial: ProbeSerial, source: LinkSource, payload: Payload, receivedAt: Date) {
        self.serial = serial
        self.source = source
        self.payload = payload
        self.receivedAt = receivedAt
    }
}

/// Something that can read log records for a probe (DirectProbeLink, NodeLink).
/// HistoryStore uses it for backfill and live fetches. docs/02 §6.3.
public protocol LogFetcher: Sendable {
    /// Streams records in [start, end]. Finishes at `end` or after the idle timeout.
    func readLogs(probe: ProbeSerial, start: UInt32, end: UInt32) -> AsyncThrowingStream<LogRecord, any Error>
}
