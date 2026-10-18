"""Regenerates the codec fixtures (advertisement/, probe_status/, node_status/, uart_frames/).
Run: python3 spec/tools/gen_codec_fixtures/gen_all.py

Independent fixture builder: implements the wire formats straight from the upstream specs
(probe_ble_specification.rst, meatnet_node_ble_specification.rst @ eabc77d), not from the Swift codec."""
import json, os

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "fixtures"))
CHANNELS = ["t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "core", "surface", "ambient"]
SENSORS = ["t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8"]
counts = {}


def pack(fields, nbytes):
    v = 0
    pos = 0
    for val, bits in fields:
        assert 0 <= val < (1 << bits), (val, bits)
        v |= val << pos
        pos += bits
    assert pos <= nbytes * 8
    return v.to_bytes(nbytes, "little")


def u16(x): return x.to_bytes(2, "little")
def u32(x): return x.to_bytes(4, "little")


def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


def hx(b): return bytes(b).hex().upper()


def write(folder, name, description, source, body):
    d = os.path.join(ROOT, folder)
    os.makedirs(d, exist_ok=True)
    doc = {"description": description, "source": source}
    doc.update(body)
    with open(os.path.join(d, name + ".json"), "w") as f:
        json.dump(doc, f, indent=2)
        f.write("\n")
    counts[folder] = counts.get(folder, 0) + 1


def celsius(raw): return round(raw / 20 - 20, 2)
def raw_of(c): return round((c + 20) * 20)
def tenths(raw): return round(raw / 10, 1)
def core_c(raw): return round(raw / 10 - 20, 1)
def fine(raw): return round(raw * 0.05, 2)


# ---- shared fields -------------------------------------------------------------------------

def temps_bytes(raws): return pack([(r, 13) for r in raws], 13)


def color_name(c): return {0: "yellow", 1: "grey"}.get(c, "unknown(%d)" % c)
def mode_name(m): return ["normal", "instantRead", "reserved", "error"][m]
def state_name(s): return {0: "notInserted", 1: "inserted", 2: "warming", 3: "predicting", 4: "removalPredictionDone"}.get(s, "unknown")
def pmode_name(m): return ["none", "timeToRemoval", "removalAndResting", "reserved"][m]
def ptype_name(t): return ["none", "removal", "resting", "reserved"][t]
def overheat_names(mask): return [SENSORS[i] for i in range(8) if mask >> i & 1]
def prefs_obj(b):
    p = b & 3
    return {"powerMode": "normal" if p == 0 else "alwaysOn" if p == 1 else "reserved(%d)" % p, "highRadioPower": bool(b & 4)}


def virtual_obj(core, surf, amb):
    """core 0..5 (T1..T6, 6/7 read as T1), surf 0..3 -> T4..T7, amb 0..3 -> T5..T8."""
    return {"core": "t%d" % (core + 1 if core <= 5 else 1), "surface": "t%d" % (surf + 4), "ambient": "t%d" % (amb + 5)}


def virtual_bits(core, surf, amb): return core | surf << 3 | amb << 5


# ---- advertisement -------------------------------------------------------------------------

VENDOR = bytes([0xC7, 0x09])
DEFAULT_TEMPS = [raw_of(c) for c in (22.5, 23.0, 23.5, 24.0, 24.5, 25.0, 25.5, 26.0)]


def probe_ad(ptype=1, serial=0x10005A3F, raws=None, mode=0, color=0, pid=1, batt=0, vcore=0, vsurf=0, vamb=3,
             network=0, overheat=0, prefs=0, length=25, trailing=b""):
    raws = raws or DEFAULT_TEMPS
    b = bytearray(VENDOR + bytes([ptype]) + u32(serial) + temps_bytes(raws))
    b.append(mode | color << 2 | (pid - 1) << 5)
    b.append(batt | virtual_bits(vcore, vsurf, vamb) << 1)
    b += bytes([network, overheat, prefs])
    return bytes(b[:length]) + trailing


def probe_ad_expected(kind, serial=0x10005A3F, raws=None, mode=0, color=0, pid=1, batt=0, vcore=0, vsurf=0, vamb=3,
                      hop=None, overheat=0, prefs=0, length=25):
    raws = raws or DEFAULT_TEMPS
    e = {"kind": kind, "serial": "%08X" % serial, "temperatures": [celsius(r) for r in raws],
         "mode": mode_name(mode), "color": color_name(color), "probeNumber": pid, "batteryLow": bool(batt),
         "virtualSensors": virtual_obj(vcore, vsurf, vamb),
         "overheating": overheat_names(overheat) if length >= 24 else None,
         "preferences": prefs_obj(prefs) if length >= 25 else None}
    if hop is not None:
        e["hopCount"] = hop
    return e


def gen_advertisements():
    F = "advertisement"

    def probe(name, desc, source="spec", **kw):
        exp_kw = {k: v for k, v in kw.items() if k not in ("network", "trailing", "ptype")}
        write(F, name, desc, source, {"hex": hx(probe_ad(**kw)), "expected": probe_ad_expected("probe", **exp_kw)})

    probe("probe_normal", "Probe, normal mode, yellow, ID 1, all temperatures 22.5-26 C")
    probe("probe_instant_read", "Instant Read: T1 holds the instant read temperature, T2-T8 are raw 0",
          raws=[raw_of(54.35)] + [0] * 7, mode=1, color=1, pid=3)
    probe("probe_error_mode", "Mode 3 (error)", mode=3)
    probe("probe_reserved_mode", "Mode 2 is reserved; it still decodes", mode=2)
    probe("probe_battery_low", "Low battery bit set, virtual sensors unaffected", batt=1, vcore=2, vsurf=1, vamb=2)
    for name, mask, desc in [("t1", 0x01, "T1 only (LSB)"), ("t8", 0x80, "T8 only (MSB)"), ("t3_t4", 0b1100, "T3 and T4"),
                             ("all", 0xFF, "all eight sensors")]:
        probe("probe_overheat_" + name, "Overheating mask: " + desc + ". Bit n is T(n+1)", overheat=mask)
    for core, surf, amb, name in [(0, 0, 0, "core_t1_surface_t4_ambient_t5"), (5, 3, 3, "core_t6_surface_t7_ambient_t8"),
                                  (0, 3, 0, "surface_t7_extreme"), (5, 0, 3, "core_t6_extreme"), (3, 2, 1, "mid_values")]:
        probe("probe_virtual_" + name, "Virtual sensor indices core=%d surface=%d ambient=%d" % (core, surf, amb),
              vcore=core, vsurf=surf, vamb=amb)
    probe("probe_virtual_core_undefined_6", "Core enum 6 is undefined; Android SDK and this codec read it as T1", vcore=6, vsurf=1, vamb=1,
          source="android-test")
    probe("probe_virtual_core_undefined_7", "Core enum 7 is undefined; reads as T1", vcore=7)
    for c in (0, 1, 2, 7):
        probe("probe_color_%d" % c, "Color field %d" % c, color=c)
    for p in (1, 2, 8):
        probe("probe_id_%d" % p, "Probe identifier %d (wire value %d)" % (p, p - 1), pid=p)
    probe("probe_android_mode_color_id", "Mode/ID 0b101_110_01 and status 0b10_11_101_1 from ProbeAdvertisingDataTest: instant read, color 6, ID 6, low battery, core T6, surface T7, ambient T7",
          source="android-test", raws=[0, 0, 0, 0, 0, 0, 0, 0], mode=1, color=6, pid=6, batt=1, vcore=5, vsurf=3, vamb=2,
          serial=0x12345678, prefs=0b100)
    probe("probe_prefs_always_on_high_power", "Preferences: always-on power mode + high radio power", prefs=0b101)
    probe("probe_prefs_reserved_power_mode", "Preferences: reserved power mode 3", prefs=0b011)
    probe("probe_temps_min", "All 13-bit raw readings 0 = -20 C", raws=[0] * 8)
    probe("probe_temps_369", "Raw 7780 = 369 C, the top of the documented range", raws=[7780] * 8)
    probe("probe_temps_raw_max", "13-bit raw maximum 8191 = 389.55 C (above the documented range; decoded as is)", raws=[8191] * 8)
    probe("probe_temps_alternating_extremes", "Alternating raw 0 and raw 8191 to catch bit-boundary errors", raws=[0, 8191] * 4)
    probe("probe_serial_max", "Serial FFFFFFFF", serial=0xFFFFFFFF)
    probe("probe_serial_leading_zeros", "Serial 0000002A keeps its leading zeros in hex form", serial=0x2A)
    probe("probe_size_22_no_network_byte", "22 bytes: ends after battery/virtual sensors; overheating and preferences absent", length=22)
    probe("probe_size_24_no_preferences", "24 bytes: preferences byte absent", length=24, overheat=0x05)
    probe("probe_trailing_bytes_ignored", "Extra bytes after the preferences byte are ignored", trailing=bytes([0xDE, 0xAD, 0xBE, 0xEF]), prefs=4)
    probe("probe_network_byte_ignored", "Probe packets ignore the network information byte (unused by probes)", network=0xC0)

    # node repeated probe data (product type 2), 24 bytes without preferences
    def repeated(name, desc, hop, length=24, source="spec", **kw):
        network = (hop - 1) << 6 | kw.pop("network_low", 0)
        hex_ = hx(probe_ad(ptype=2, network=network, length=length, **kw))
        write(F, name, desc, source, {"hex": hex_, "expected": probe_ad_expected("repeated", hop=hop, length=length, **kw)})

    for h in (1, 2, 3, 4):
        repeated("repeated_hop_%d" % h, "Node-repeated probe data, %d hop(s). Hop count is in the top two bits of the network byte" % h, h,
                 serial=0x10005A3F + h, overheat=0x01 if h == 4 else 0)
    repeated("repeated_hop_low_bits_ignored", "Reserved low bits of the network byte do not change the hop count", 2, network_low=0x3F)
    repeated("repeated_instant_read", "Repeated probe in Instant Read mode", 1, raws=[raw_of(60.0)] + [0] * 7, mode=1)
    repeated("repeated_with_preferences", "Repeated packet that also carries the preferences byte (25 bytes)", 3, length=25, prefs=0b101)
    repeated("repeated_serial_zero", "A node with no probes repeats serial 0; passed through unchanged", 1, serial=0)
    repeated("repeated_battery_low_error_mode", "Repeated probe in error mode with low battery", 2, mode=3, batt=1)
    repeated("repeated_android_hop3", "networkInfo 0b1000_0000 = 3 hops, as in ProbeAdvertisingDataTest", 3, source="android-test", serial=0x12345678,
             raws=[0] * 8, mode=1, color=6, pid=6, batt=1, vcore=5, vsurf=3, vamb=2)

    # node own advertisements
    def node(name, desc, ptype, serial, prefs=None, length=25, source="spec", expected_type=None):
        b = bytearray(VENDOR + bytes([ptype]) + serial.encode().ljust(10, b"\0") + bytes([prefs or 0]) + bytes(11))
        if prefs is None:
            b[13] = 0
        data = bytes(b[:length])
        e = {"kind": "node", "productType": ptype, "nodeProductType": expected_type, "serial": serial,
             "preferences": prefs if (prefs is not None and length > 13 and ptype in (4, 5)) else None}
        write(F, name, desc, source, {"hex": hx(data), "expected": e})

    node("node_display", "Display own advertisement: product type 4, 10-char serial, preferences byte", 4, "DSP0000001", prefs=0x03, expected_type="display")
    node("node_display_prefs_zero", "Display with preferences byte 0", 4, "DSP0000002", prefs=0, expected_type="display")
    node("node_display_no_prefs_byte", "Display packet cut off after the serial (13 bytes): preferences absent", 4, "DSP0000003", length=13, expected_type="display")
    node("node_booster", "Booster own advertisement: product type 5", 5, "BST0000001", prefs=0x80, expected_type="booster")
    node("node_gauge", "Gauge (product type 3): only the serial is decoded in v1", 3, "GAUGE00001", expected_type="gauge")
    node("node_engine", "Engine (product type 6): only the serial is decoded in v1", 6, "ENGINE0001", expected_type="engine")
    node("node_short_serial_nul_padded", "Serial shorter than 10 characters is NUL padded; padding is stripped", 4, "AB12", prefs=1, expected_type="display")
    for t in (0, 7, 0x2A, 0xFF):
        write(F, "unknown_product_type_%d" % t, "Unknown product type %d decodes to unknown(productType)" % t, "hand-built",
              {"hex": hx(VENDOR + bytes([t]) + bytes(range(20))), "expected": {"kind": "unknown", "productType": t}})
    write(F, "unknown_product_type_only_header", "Three bytes (vendor + type) are enough to classify an unknown product", "hand-built",
          {"hex": hx(VENDOR + bytes([9])), "expected": {"kind": "unknown", "productType": 9}})

    def err(name, desc, data, error):
        write(F, name, desc, "hand-built", {"hex": hx(data), "expectedError": error})

    err("error_empty", "Empty manufacturer data", b"", {"kind": "tooShort", "expected": 3, "actual": 0})
    err("error_two_bytes", "Vendor ID only, no product type", VENDOR, {"kind": "tooShort", "expected": 3, "actual": 2})
    err("error_wrong_vendor", "Vendor ID 0x004C (Apple) is rejected", bytes([0x4C, 0x00, 1]) + bytes(22), {"kind": "badSync"})
    err("error_probe_too_short", "Probe packet cut off before the battery byte", probe_ad(length=21), {"kind": "tooShort", "expected": 22, "actual": 21})
    err("error_probe_header_only", "Probe packet with no data after the product type", VENDOR + bytes([1]), {"kind": "tooShort", "expected": 22, "actual": 3})
    err("error_repeated_too_short", "Repeated packet without the network byte", probe_ad(ptype=2, length=22), {"kind": "tooShort", "expected": 23, "actual": 22})
    err("error_node_too_short", "Display packet cut off inside the serial", VENDOR + bytes([4]) + b"DSP00", {"kind": "tooShort", "expected": 13, "actual": 8})
