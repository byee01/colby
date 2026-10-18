from gen_common import *


def alarm_word(a): return a[0] | a[1] << 1 | a[2] << 2 | a[3] << 3   # (set, tripped, alarming, raw13)


UNSET = (0, 0, 0, 0)


def default_status():
    return dict(
        lo=100, hi=200, temps=list(DEFAULT_TEMPS), mode=0, color=0, pid=1, batt=0, vcore=0, vsurf=0, vamb=3,
        pred=dict(state=0, mode=0, type=0, sp=0, hs=0, secs=0, core=200),   # core raw 200 = 0.0 C
        food=dict(mode=0, prod=0, serv=0, thr=0, z=0, rt=0, d=0, tlr=0, state=0, lr=0, fsecs=0, fseq=0),
        overheat=0, prefs=0, high=[UNSET] * 11, low=[UNSET] * 11, session=(0x1A2B3C4D, 5000))


def status_bytes(s, network=None, layout="current"):
    p, f = s["pred"], s["food"]
    b = bytearray(u32(s["lo"]) + u32(s["hi"]) + temps_bytes(s["temps"]))
    b.append(s["mode"] | s["color"] << 2 | (s["pid"] - 1) << 5)
    b.append(s["batt"] | virtual_bits(s["vcore"], s["vsurf"], s["vamb"]) << 1)
    b += pack([(p["state"], 4), (p["mode"], 2), (p["type"], 2), (p["sp"], 10), (p["hs"], 10), (p["secs"], 17), (p["core"], 11)], 7)
    b += pack([(f["mode"], 3), (f["prod"], 10), (f["serv"], 3), (f["thr"], 13), (f["z"], 13), (f["rt"], 13), (f["d"], 13), (f["tlr"], 8)], 10)
    b += pack([(f["state"], 3), (f["lr"], 8), (f["fsecs"], 16), (f["fseq"], 32)], 8)
    if network is not None:
        b.append(network)
    b.append(s["overheat"])
    b.append(s["prefs"])
    for a in s["high"] + s["low"]:
        b += u16(alarm_word(a))
    if layout == "current":
        b += u32(s["session"][0]) + u16(s["session"][1])
    return bytes(b)


def alarm_obj(a):
    return {"set": bool(a[0]), "tripped": bool(a[1]), "alarming": bool(a[2]), "temperature": round(a[3] / 10 - 20, 1)}


def food_expected(f):
    if f["mode"] > 1 or f["serv"] > 1 or f["state"] > 2:
        return None
    integrated = f["mode"] == 1
    return {"mode": "integrated" if integrated else "simplified", "product": f["prod"],
            "serving": "servedImmediately" if f["serv"] == 0 else "cookedAndChilled",
            "thresholdTemp": fine(f["thr"]) if integrated else None, "zValue": fine(f["z"]) if integrated else None,
            "referenceTemp": fine(f["rt"]) if integrated else None, "dValue": fine(f["d"]) if integrated else None,
            "targetLogReduction": round(f["tlr"] / 10, 1), "state": ["notSafe", "safe", "safetyImpossible"][f["state"]],
            "logReduction": round(f["lr"] / 10, 1), "secondsAboveThreshold": f["fsecs"], "logSequence": f["fseq"]}


def status_expected(s, length, node=False):
    """length = bytes of status excluding any node serial prefix (GATT: up to 100; node: up to 101)."""
    p = s["pred"]
    base = 49 if node else 48
    alarms_end = base + 46
    return {
        "logRange": {"min": s["lo"], "max": s["hi"]},
        "temperatures": [celsius(r) for r in s["temps"]],
        "mode": mode_name(s["mode"]), "color": color_name(s["color"]), "probeNumber": s["pid"], "batteryLow": bool(s["batt"]),
        "virtualSensors": virtual_obj(s["vcore"], s["vsurf"], s["vamb"]),
        "prediction": {"state": state_name(p["state"]), "mode": pmode_name(p["mode"]), "type": ptype_name(p["type"]),
                       "setpoint": tenths(p["sp"]), "heatStart": tenths(p["hs"]), "rawSecondsRemaining": p["secs"],
                       "estimatedCore": core_c(p["core"])},
        "foodSafe": food_expected(s["food"]) if length >= 48 else None,
        "overheating": overheat_names(s["overheat"]) if length > base else None,
        "preferences": prefs_obj(s["prefs"]) if length > base + 1 else None,
        "alarms": ({"high": {c: alarm_obj(a) for c, a in zip(CHANNELS, s["high"])},
                    "low": {c: alarm_obj(a) for c, a in zip(CHANNELS, s["low"])}} if length >= alarms_end else None),
        "session": ({"sessionId": s["session"][0], "samplePeriodMs": s["session"][1]}
                    if length >= alarms_end + 6 and s["session"][0] != 0 else None),
    }


def gen_probe_status():
    F = "probe_status"

    def emit(name, desc, s, size=None, source="spec", trailing=b""):
        raw = status_bytes(s)
        if size is not None:
            raw = raw[:size]
        write(F, name, desc, source, {"hex": hx(raw + trailing), "expected": status_expected(s, len(raw))})

    s = default_status()
    emit("current_100_bytes", "Current firmware: 100-byte status with session ID and sample period", s)
    emit("legacy_94_bytes_no_session", "Firmware that predates session ID: 94 bytes, session absent", s, size=94)
    s0 = default_status(); s0["session"] = (0, 0)
    emit("current_100_session_id_0", "100 bytes with session ID 0 (status sent when notifications are first enabled): session treated as not supplied", s0)
    s0b = default_status(); s0b["session"] = (0, 5000)
    emit("current_100_session_id_0_period_set", "Session ID 0 with a non-zero sample period: both treated as not supplied", s0b)
    emit("trailing_bytes_ignored", "Bytes after the known 100-byte layout are ignored", s, trailing=bytes([1, 2, 3, 4, 5, 6]))
    for n, why in [(30, "minimum: through prediction status; food safe, flags, alarms and session absent"),
                   (47, "one byte short of food safe status"), (48, "through food safe status; overheating absent"),
                   (49, "overheating present, preferences absent"), (50, "overheating and preferences present, alarms absent"),
                   (93, "alarms cut one byte short: absent"), (97, "session ID present but sample period cut: session absent"),
                   (99, "sample period one byte short: session absent")]:
        emit("truncated_%d_bytes" % n, "Truncated status of %d bytes: %s" % (n, why), s, size=n)
    for n in (0, 29):
        write(F, "error_too_short_%d" % n, "Status shorter than the 30-byte minimum", "hand-built",
              {"hex": hx(status_bytes(s)[:n]), "expectedError": {"kind": "tooShort", "expected": 30, "actual": n}})

    s = default_status(); s["lo"], s["hi"] = 0, 0xFFFFFFFF
    emit("log_range_extremes", "Log range min 0, max 0xFFFFFFFF", s)
    s = default_status(); s["session"] = (0xFFFFFFFF, 0xFFFF)
    emit("session_extremes", "Session ID 0xFFFFFFFF and sample period 65535 ms", s)
    s = default_status(); s["session"] = (1, 1)
    emit("session_minimum_nonzero", "Smallest valid session ID (1) and sample period 1", s)

    for name, raws, d in [("min", [0] * 8, "all raw 0 = -20 C"), ("369", [7780] * 8, "raw 7780 = 369 C"),
                          ("raw_max", [8191] * 8, "13-bit raw max 8191 = 389.55 C"),
                          ("alternating", [0, 8191, 1, 8190, 4096, 4095, 2730, 5461], "bit-boundary patterns"),
                          ("instant_read", [raw_of(71.25)] + [0] * 7, "Instant Read mode: only T1 valid")]:
        s = default_status(); s["temps"] = raws
        if name == "instant_read":
            s["mode"] = 1
        emit("temps_" + name, "Temperatures: " + d, s)

    s = default_status(); s.update(mode=1, color=1, pid=8, batt=1, vcore=5, vsurf=3, vamb=3)
    emit("mode_instant_read_grey_id8_battery_low", "Instant Read, grey, probe ID 8, low battery, core T6/surface T7/ambient T8", s)
    s = default_status(); s.update(mode=3, color=5, pid=2)
    emit("mode_error_unknown_color", "Error mode with undefined color 5", s)
    s = default_status(); s.update(mode=2)
    emit("mode_reserved", "Reserved mode 2", s)

    def pred(**kw):
        s = default_status(); s["pred"].update(kw); return s
    for st in (0, 1, 2, 3, 4, 5, 14, 15):
        emit("prediction_state_%d" % st, "Prediction state raw %d%s" % (st, " (reserved, reads as unknown)" if 5 <= st <= 14 else ""),
             pred(state=st, sp=650, hs=200, secs=1800, core=600))
    for m in range(4):
        emit("prediction_mode_%d" % m, "Prediction mode raw %d" % m, pred(state=3, mode=m, type=1, sp=650))
    for t in range(4):
        emit("prediction_type_%d" % t, "Prediction type raw %d" % t, pred(state=3, mode=2, type=t, sp=650))
    emit("prediction_setpoint_max_102_3", "Set point raw 1023 = 102.3 C, the largest settable target", pred(state=3, mode=1, type=1, sp=1023, hs=1023))
    emit("prediction_setpoint_zero", "Set point 0", pred(state=1, sp=0))
    emit("prediction_seconds_max_17_bit", "17-bit seconds 131071", pred(state=3, mode=1, type=1, sp=650, secs=131071))
    emit("prediction_seconds_zero_done", "Removal prediction done, 0 s", pred(state=4, mode=1, type=1, sp=650, secs=0, core=850))
    emit("prediction_core_min", "Estimated core raw 0 = -20 C", pred(state=2, core=0))
    emit("prediction_core_max", "Estimated core raw 2047 = 184.7 C", pred(state=3, core=2047))
    emit("prediction_all_fields_max", "Every prediction field at its maximum bit pattern", pred(state=15, mode=3, type=3, sp=1023, hs=1023, secs=131071, core=2047))
    emit("prediction_heat_start_and_progress", "Heat start 20.5 C, set point 63 C, estimated core 41.7 C (about 50 percent)", pred(state=3, mode=1, type=1, sp=630, hs=205, secs=900, core=617))

    def alarms(high=None, low=None):
        s = default_status()
        if high: s["high"] = [high.get(i, UNSET) for i in range(11)]
        if low: s["low"] = [low.get(i, UNSET) for i in range(11)]
        return s
    emit("alarms_all_unset", "All 22 alarms unset at -20 C", alarms())
    emit("alarms_minus_20_set", "High and low alarm on core set at -20 C (raw 0)", alarms({8: (1, 0, 0, 0)}, {8: (1, 0, 0, 0)}))
    emit("alarms_799_set", "Alarm temperature 799 C (raw 8190)", alarms({8: (1, 0, 0, 8190)}, {9: (1, 0, 0, 8190)}))
    emit("alarms_raw_max_8191", "13-bit raw maximum 8191 decodes to 799.1 C", alarms({10: (1, 0, 0, 8191)}))
    emit("alarms_tripped_and_alarming", "Core high alarm set, tripped and alarming at 74.5 C; ambient low set and tripped only",
         alarms({8: (1, 1, 1, 945)}, {10: (1, 1, 0, 700)}))
    emit("alarms_flags_without_set", "Tripped/alarming bits with set = 0 are reported as is", alarms({0: (0, 1, 1, 100)}))
    emit("alarms_every_channel", "A different alarm on every channel in both arrays",
         alarms({i: (1, i % 2, (i // 2) % 2, 200 + 100 * i) for i in range(11)}, {i: (i % 2, 0, 1, 50 * i + 1) for i in range(11)}))

    def food(**kw):
        s = default_status(); s["food"].update(kw); return s
    emit("food_safe_simplified_default", "Simplified mode, default product, served immediately, not safe", food())
    emit("food_safe_simplified_poultry_safe", "Simplified, any poultry (1), safe", food(prod=1, state=1, fsecs=45, fseq=77))
    emit("food_safe_simplified_casseroles_chilled", "Simplified, casseroles (12), cooked and chilled", food(prod=12, serv=1, state=2))
    emit("food_safe_simplified_ignores_integrated_fields", "Simplified mode: integrated parameters in the bytes are ignored (decoded as nil)", food(prod=3, thr=3300, z=100, rt=4000, d=500, tlr=40))
    emit("food_safe_integrated_dairy_milk", "Integrated, dairy milk (15), cooked and chilled; values from FoodSafeDataTest and ProbeStatusTest",
         food(mode=1, prod=15, serv=1, thr=5461, z=2730, rt=5461, d=4594, tlr=170, state=2, lr=187, fsecs=48331, fseq=0xBEEFFACE), source="android-test")
    emit("food_safe_integrated_custom_1023", "Integrated, custom product 1023", food(mode=1, prod=1023, thr=1, z=1, rt=1, d=1, tlr=1))
    emit("food_safe_integrated_max_values", "Integrated with every field at its maximum (13-bit values 409.55, log reduction 25.5, 16-bit seconds, 32-bit sequence)",
         food(mode=1, prod=1023, serv=1, thr=8191, z=8191, rt=8191, d=8191, tlr=255, state=2, lr=255, fsecs=65535, fseq=0xFFFFFFFF))
    emit("food_safe_integrated_zero", "Integrated mode with all-zero parameters", food(mode=1))
    emit("food_safe_reserved_mode_is_nil", "Reserved food safe mode 2: food safe decodes to nil, rest of the status is unaffected", food(mode=2, prod=5))
    emit("food_safe_reserved_serving_is_nil", "Reserved serving 2: food safe nil", food(serv=2))
    emit("food_safe_reserved_state_is_nil", "Reserved food safe state 3: food safe nil", food(state=3))
    emit("food_safe_reserved_state_7_is_nil", "Reserved food safe state 7: food safe nil", food(state=7))

    for mask, nm in [(0x00, "none"), (0x01, "t1"), (0x80, "t8"), (0xFF, "all"), (0xA5, "pattern")]:
        s = default_status(); s["overheat"] = mask
        emit("overheat_" + nm, "Overheating mask 0x%02X (bit n = T(n+1))" % mask, s)
    for pref, nm in [(0, "normal"), (1, "always_on"), (4, "high_radio"), (5, "always_on_high_radio"), (3, "reserved_power_mode"), (0xF8, "reserved_bits_ignored")]:
        s = default_status(); s["prefs"] = pref
        emit("preferences_" + nm, "Thermometer preferences byte 0x%02X" % pref, s)

    # Android ProbeStatusTest 'fromRaw overall': 48-byte buffer filled with 0xFF
    a = bytearray([0xFF] * 48)
    a[0:4] = bytes([0xAA] * 4); a[4:8] = bytes([0x55] * 4)
    a[8:21] = bytes([0x89, 0x00, 0xDA, 0x00, 0xD7, 0x0D, 0x07, 0x33, 0x05, 0xD5, 0x18, 0x74, 0x1A])
    a[21] = 0b10111001; a[22] = 0b10111011
    a[23:30] = bytes([0b10010011, 0xA9, 0b10101010, 0b11011001, 0b11011011, 0b10110101, 0xF9])
    a[30:40] = pack([(1, 3), (15, 10), (1, 3), (5461, 13), (2730, 13), (5461, 13), (4594, 13), (170, 8)], 10)
    a[40:48] = bytes([0b11011010, 0b01011101, 0xE6, 0b01110101, 0xD6, 0x7F, 0xF7, 0b11111101])
    write(F, "android_from_raw_overall_48_bytes", "48-byte buffer from ProbeStatusTest 'fromRaw overall' (unspecified bytes 0xFF): "
          "temps -13.15/67.2/258.4/160.55/225.6/114.5/189.75/22.3, instant read, color 6, ID 6, low battery, prediction 68.1/61.8/89533 s, food safe integrated, safety impossible 18.7 log, 48331 s, seq 0xBEEFFACE",
          "android-test", {"hex": hx(a), "expected": {
              "logRange": {"min": 0xAAAAAAAA, "max": 0x55555555},
              "temperatures": [-13.15, 67.2, 258.4, 160.55, 225.6, 114.5, 189.75, 22.3],
              "mode": "instantRead", "color": "unknown(6)", "probeNumber": 6, "batteryLow": True,
              "virtualSensors": {"core": "t6", "surface": "t7", "ambient": "t7"},
              "prediction": {"state": "predicting", "mode": "timeToRemoval", "type": "resting", "setpoint": 68.1, "heatStart": 61.8,
                             "rawSecondsRemaining": 89533, "estimatedCore": 179.7},
              "foodSafe": {"mode": "integrated", "product": 15, "serving": "cookedAndChilled", "thresholdTemp": 273.05, "zValue": 136.5,
                           "referenceTemp": 273.05, "dValue": 229.7, "targetLogReduction": 17.0, "state": "safetyImpossible",
                           "logReduction": 18.7, "secondsAboveThreshold": 48331, "logSequence": 0xBEEFFACE},
              "overheating": None, "preferences": None, "alarms": None, "session": None}})
    write(F, "android_min_raw_size_30_bytes", "30 bytes of 0xFF (ProbeStatus.MIN_RAW_SIZE): no food safe", "android-test",
          {"hex": "FF" * 30, "expected": {
              "logRange": {"min": 0xFFFFFFFF, "max": 0xFFFFFFFF}, "temperatures": [389.55] * 8, "mode": "error", "color": "unknown(7)",
              "probeNumber": 8, "batteryLow": True, "virtualSensors": {"core": "t1", "surface": "t7", "ambient": "t8"},
              "prediction": {"state": "unknown", "mode": "reserved", "type": "reserved", "setpoint": 102.3, "heatStart": 102.3,
                             "rawSecondsRemaining": 131071, "estimatedCore": 184.7},
              "foodSafe": None, "overheating": None, "preferences": None, "alarms": None, "session": None}})
    write(F, "android_not_enough_data_13_bytes", "13 bytes: Android returns null; here tooShort", "android-test",
          {"hex": "FF" * 13, "expectedError": {"kind": "tooShort", "expected": 30, "actual": 13}})


def gen_node_status():
    F = "node_status"

    def emit(name, desc, s, serial=0x10005A3F, hop=1, size=None, source="spec", trailing=b"", network_low=0):
        raw = u32(serial) + status_bytes(s, network=(hop - 1) << 6 | network_low)
        if size is not None:
            raw = raw[:size]
        write(F, name, desc, source, {"hex": hx(raw + trailing), "expected": {
            "probeSerial": "%08X" % serial, "hopCount": hop, "status": status_expected(s, len(raw) - 4, node=True)}})

    s = default_status()
    emit("current_105_bytes", "New node: 105-byte 0x45 payload with session ID and sample period", s, hop=1)
    emit("legacy_99_bytes_no_session", "Node that predates session fields: 99 bytes", s, hop=2, size=99)
    s0 = default_status(); s0["session"] = (0, 0)
    emit("current_105_session_id_0", "105 bytes with session ID 0: a new node relaying an old probe. The value, not the length, decides: session absent", s0, hop=1)
    emit("current_105_session_id_0_period_set", "Session ID 0 with a stray sample period", {**default_status(), "session": (0, 1000)}, hop=3)
    for h in (1, 2, 3, 4):
        emit("hop_%d" % h, "Hop count %d (top two bits of the network information byte)" % h, s, serial=0x20000000 + h, hop=h)
    emit("hop_reserved_low_bits_ignored", "Reserved low bits set in the network byte", s, hop=2, network_low=0x3F)
    emit("trailing_bytes_ignored", "Bytes after the 105-byte payload are ignored", s, hop=1, trailing=bytes([9, 9, 9]))
    emit("serial_max", "Probe serial FFFFFFFF", s, serial=0xFFFFFFFF, hop=4)
    for n, why in [(53, "network byte present; overheating absent"), (54, "overheating present, preferences absent"),
                   (55, "preferences present, alarms absent"), (98, "alarms cut one byte short: absent"),
                   (102, "session ID present, sample period cut: session absent")]:
        emit("truncated_%d_bytes" % n, "Truncated 0x45 payload of %d bytes: %s" % (n, why), s, hop=2, size=n)

    legacy = default_status()
    raw35 = u32(0x10005A3F) + status_bytes(legacy, network=2 << 6)[:30] + bytes([2 << 6])
    write(F, "legacy_35_bytes_oldest_node", "Oldest nodes (Android MINIMUM_PAYLOAD_LENGTH): network byte directly after the prediction status, 35 bytes total", "android-test",
          {"hex": hx(raw35), "expected": {"probeSerial": "10005A3F", "hopCount": 3, "status": status_expected(legacy, 30, node=True)}})

    s = default_status(); s["temps"] = [0] * 4 + [7780] * 4
    emit("temps_minus_20_and_369", "T1-T4 at -20 C (raw 0), T5-T8 at 369 C (raw 7780)", s, hop=1)
    s = default_status(); s["temps"] = [8191] * 8
    emit("temps_raw_max", "13-bit raw max", s, hop=1)
    s = default_status(); s["pred"].update(state=3, mode=1, type=1, sp=1023, hs=1023, secs=131071, core=2047)
    emit("prediction_setpoint_102_3_seconds_max", "Set point 102.3 C and 17-bit seconds maximum", s, hop=2)
    for st in (0, 1, 2, 3, 4, 15):
        s = default_status(); s["pred"].update(state=st, mode=2, type=2, sp=650, hs=210, secs=3600, core=500)
        emit("prediction_state_%d" % st, "Prediction state raw %d, removal and resting mode, resting type" % st, s, hop=1)
    s = default_status(); s["high"] = [(1, 0, 0, 0)] + [UNSET] * 10; s["low"] = [UNSET] * 10 + [(1, 1, 1, 8190)]
    emit("alarms_minus_20_and_799", "High T1 alarm at -20 C; low ambient alarm at 799 C, tripped and alarming", s, hop=1)
    s = default_status(); s["food"].update(mode=1, prod=18, serv=0, thr=3300, z=200, rt=3200, d=100, tlr=60, state=1, lr=61, fsecs=1200, fseq=99)
    emit("food_safe_integrated_eggs", "Integrated food safe, eggs (18), safe", s, hop=2)
    s = default_status(); s["food"].update(mode=0, prod=2, serv=1, state=0, fseq=5)
    emit("food_safe_simplified_beef", "Simplified food safe, beef cuts (2)", s, hop=3)
    s = default_status(); s.update(mode=1, color=1, pid=4, batt=1, overheat=0x0C, prefs=5, temps=[raw_of(80.0)] + [0] * 7)
    emit("instant_read_overheat_prefs", "Instant read probe with overheating T3/T4 and always-on/high-radio prefs", s, hop=1)
    s = default_status(); s["session"] = (0xFFFFFFFF, 0xFFFF); s["lo"], s["hi"] = 0xFFFFFFFE, 0xFFFFFFFF
    emit("session_and_log_extremes", "Session ID, sample period and log sequence at maximum", s, hop=4)

    full = u32(1) + status_bytes(default_status(), network=0)
    for n, exp in [(0, 35), (4, 35), (34, 35), (40, 53), (52, 53)]:
        write(F, "error_too_short_%d" % n, "0x45 payload of %d bytes: %s" % (n, "below the 35-byte minimum" if n < 35 else "no room for the network byte after food safe"),
              "hand-built", {"hex": hx(full[:n]), "expectedError": {"kind": "tooShort", "expected": exp, "actual": n}})
