import CombustionCodec
import Foundation

/// A MeatNet node (display, booster, gauge, engine) seen in a scan.
public struct NodeSighting: Sendable, Equatable {
    public var serial: NodeSerial
    public var productType: NodeProductType
    public var peripheral: PeripheralId
    public var rssi: Int
    public var time: Date

    public init(serial: NodeSerial, productType: NodeProductType, peripheral: PeripheralId, rssi: Int, time: Date) {
        self.serial = serial
        self.productType = productType
        self.peripheral = peripheral
        self.rssi = rssi
        self.time = time
    }
}

/// A probe heard advertising from its own peripheral (not repeated by a node). The peripheral is what a
/// direct connection needs; observations alone do not carry it.
public struct ProbeSighting: Sendable, Equatable {
    public var serial: ProbeSerial
    public var peripheral: PeripheralId
    public var rssi: Int
    public var time: Date

    public init(serial: ProbeSerial, peripheral: PeripheralId, rssi: Int, time: Date) {
        self.serial = serial
        self.peripheral = peripheral
        self.rssi = rssi
        self.time = time
    }
}

/// A probe's data repeated by a node, heard on the node's peripheral. Tells the policy which node can reach
/// the probe even before the node's own advertisement has been matched to a serial.
public struct RepeatedProbeSighting: Sendable, Equatable {
    public var serial: ProbeSerial
    public var nodePeripheral: PeripheralId
    /// Nil until the node's own advertisement has been heard.
    public var via: NodeSerial?
    public var hopCount: Int
    public var rssi: Int
    public var time: Date

    public init(serial: ProbeSerial, nodePeripheral: PeripheralId, via: NodeSerial?, hopCount: Int, rssi: Int, time: Date) {
        self.serial = serial
        self.nodePeripheral = nodePeripheral
        self.via = via
        self.hopCount = hopCount
        self.rssi = rssi
        self.time = time
    }
}

public struct AdvertisementDiagnostics: Sendable, Equatable {
    /// Advertisements received from the transport.
    public var received = 0
    /// Probe advertisements published (own and node-repeated).
    public var probePackets = 0
    public var nodePackets = 0
    /// Valid Combustion packets of a product type this version ignores.
    public var unknownPackets = 0
    /// Probe packets with serial 0: a node with no probe in that slot yet (a Display right after power-on
    /// repeats all-zero packets). Dropped.
    public var emptySlotPackets = 0
    /// Advertisements the codec rejected (wrong vendor, too short). Counted, never thrown.
    public var codecErrors = 0
    public init() {}
}

/// Decodes every advertisement and publishes probe observations and node sightings (docs/02 §5.2).
/// Gives live temperatures without using a probe connection slot.
///
/// Repeated-probe packets come from a node's peripheral; the node's own advertisements teach the source which
/// node serial lives on which peripheral, so `LinkSource.via` can be filled. Until the node has been heard,
/// `via` is nil.
public actor AdvertisementSource {
    public nonisolated var observations: AsyncStream<ProbeObservation> { observationBroadcast.stream() }
    public nonisolated var nodeSightings: AsyncStream<NodeSighting> { sightingBroadcast.stream() }
    /// Probes heard on their own peripheral; `ConnectionPolicy` connects to these.
    public nonisolated var probeSightings: AsyncStream<ProbeSighting> { probeSightingBroadcast.stream() }

    /// Probes heard through a node; `ConnectionPolicy` uses them to decide on a node connection.
    public nonisolated var repeatedSightings: AsyncStream<RepeatedProbeSighting> { repeatedBroadcast.stream() }

    public var diagnostics: AdvertisementDiagnostics { stats }
    /// The node serial last advertised by `peripheral`, if any.
    public func nodeSerial(for peripheral: PeripheralId) -> NodeSerial? { nodeByPeripheral[peripheral] }

    private let transport: any BleTransport
    private let observationBroadcast = Broadcaster<ProbeObservation>()
    private let sightingBroadcast = Broadcaster<NodeSighting>()
    private let probeSightingBroadcast = Broadcaster<ProbeSighting>()
    private let repeatedBroadcast = Broadcaster<RepeatedProbeSighting>()
    private var nodeByPeripheral: [PeripheralId: NodeSerial] = [:]
    private var stats = AdvertisementDiagnostics()
    private var task: Task<Void, Never>?

    public init(transport: any BleTransport) {
        self.transport = transport
    }

    /// Starts scanning and consuming advertisements. Idempotent.
    public func start() async {
        guard task == nil else { return }
        // Take the stream before scanning so nothing is missed.
        let stream = transport.advertisements
        task = Task {
            for await raw in stream {
                self.process(raw)
            }
        }
        await transport.startScan()
    }

    public func stop() async {
        task?.cancel()
        task = nil
        await transport.stopScan()
    }

    /// Decodes one advertisement. Exposed for replays that bypass the transport.
    public func process(_ raw: RawAdvertisement) {
        stats.received += 1
        let packet: AdvertisementPacket
        do {
            packet = try decodeAdvertisement(raw.mfrData)
        } catch {
            stats.codecErrors += 1
            return
        }
        switch packet {
        case .probe(let probe) where probe.serial.rawValue == 0, .repeated(let probe, _) where probe.serial.rawValue == 0:
            stats.emptySlotPackets += 1
        case .probe(let probe):
            stats.probePackets += 1
            publish(probe, kind: .advertisement, via: nil, hopCount: nil, raw)
            probeSightingBroadcast.send(ProbeSighting(
                serial: probe.serial, peripheral: raw.peripheral, rssi: raw.rssi, time: raw.time))
        case .repeated(let probe, let hops):
            stats.probePackets += 1
            let via = nodeByPeripheral[raw.peripheral]
            publish(probe, kind: .nodeAdvertisement, via: via, hopCount: hops, raw)
            repeatedBroadcast.send(RepeatedProbeSighting(
                serial: probe.serial, nodePeripheral: raw.peripheral, via: via, hopCount: hops,
                rssi: raw.rssi, time: raw.time))
        case .node(let node):
            stats.nodePackets += 1
            nodeByPeripheral[raw.peripheral] = node.serial
            sightingBroadcast.send(NodeSighting(
                serial: node.serial, productType: node.productType, peripheral: raw.peripheral,
                rssi: raw.rssi, time: raw.time))
        case .unknown:
            stats.unknownPackets += 1
        }
    }

    private func publish(
        _ probe: ProbeAdvertisement, kind: LinkSource.Kind, via: NodeSerial?, hopCount: Int?, _ raw: RawAdvertisement
    ) {
        let source = LinkSource(
            kind: kind, via: via, hopCount: hopCount, rssi: raw.rssi,
            highRadioPower: probe.preferences?.highRadioPower, lastSeen: raw.time)
        observationBroadcast.send(ProbeObservation(
            serial: probe.serial, source: source, payload: .advertisement(probe), receivedAt: raw.time))
    }
}
