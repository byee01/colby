import CombustionCore
import CombustionSim
import Foundation

func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("colby-sim-\(UUID().uuidString)")
}

/// Probe-style UART frame: sync(2) crc(2) type(1) len(1) payload. The CRC is not
/// validated by the simulator, so a filler is used.
func frame(type: UInt8, crc: UInt8 = 0, payload: [UInt8] = []) -> [UInt8] {
    [0xCA, 0xFE, crc, crc, type, UInt8(payload.count)] + payload
}

let probeA: PeripheralId = "PROBE-A"
let mfr: [UInt8] = [0xC7, 0x09, 0x01, 0x3F, 0x5A, 0x00, 0x10]
