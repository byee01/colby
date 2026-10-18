#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
import CombustionCore

// GattUUID <-> CBUUID helpers. GattUUID is the normalized uppercase string
// ("180A" for 16-bit, full 36-character form for 128-bit); `CBUUID.uuidString`
// yields the same shapes, so the mapping is a plain string round trip.

extension GattUUID {
    /// `CBUUID(string:)` traps on malformed input; every GattUUID in this
    /// codebase is a constant from docs/01 §2, so that cannot happen here.
    var cbUUID: CBUUID { CBUUID(string: rawValue) }
}

extension CBUUID {
    var gattUUID: GattUUID { GattUUID(uuidString) }
}
#endif
