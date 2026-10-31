from gen_common import *

SERIAL = 0x10005A3F


# ---- framing --------------------------------------------------------------------------------

def with_crc(body): return bytes([0xCA, 0xFE]) + u16(crc16(body)) + body


def req_probe(t, payload=b""): return with_crc(bytes([t, len(payload)]) + payload)
def req_node(t, rid, payload=b""): return with_crc(bytes([t]) + u32(rid) + bytes([len(payload)]) + payload)
def resp_probe(t, ok, payload=b""): return with_crc(bytes([t, ok, len(payload)]) + payload)
def resp_node(t, rid, sid, ok, payload=b""): return with_crc(bytes([t | 0x80]) + u32(rid) + u32(sid) + bytes([ok, len(payload)]) + payload)


# ---- requests -------------------------------------------------------------------------------

def alarm_word_req(a):
    return (a.get("set", False) | a.get("tripped", False) << 1 | a.get("alarming", False) << 2) | round((a["temperature"] + 20) * 10) << 3


def alarms_payload(req):
    out = b""
    for kind in ("high", "low"):
        for c in CHANNELS:
            a = req.get(kind, {}).get(c, {"set": False, "temperature": -20})
            out += u16(alarm_word_req(a))
    return out


def request_payload(r):
    t = r["type"]
    if t == "readLogs": return u32(r["start"]) + u32(r["end"])
    if t == "setPrediction": return u16(round(r["setpoint"] * 10) | ["none", "timeToRemoval", "removalAndResting"].index(r["mode"]) << 10)
    if t == "setAlarms": return alarms_payload(r)
    return b""


TYPES = {"readSessionInfo": 0x03, "readLogs": 0x04, "setPrediction": 0x05, "setAlarms": 0x0B, "silenceAlarms": 0x0C,
         "readProbeFirmware": 0x46, "readProbeHardware": 0x47, "readProbeModel": 0x48}


def encode_probe(r): return req_probe(TYPES[r["type"]], request_payload(r))


def encode_node(r, serial, rid):
    if r["type"] == "silenceAlarms":
        payload = bytes([0, 1]) + u32(serial) + bytes(10)
    else:
        payload = u32(serial) + request_payload(r)
    return req_node(TYPES[r["type"]], rid, payload)


def frame_obj(direction, mtype, rid, sid, ok, payload):
    return {"direction": direction, "messageType": mtype, "requestId": rid, "responseId": sid, "success": ok, "payloadHex": hx(payload)}


# ---- responses ------------------------------------------------------------------------------

def predlog_bytes(p):
    return pack([(virtual_bits(p["vcore"], p["vsurf"], p["vamb"]), 7), (p["state"], 4), (p["mode"], 2), (p["type"], 2),
                 (p["sp"], 10), (p["secs"], 17), (p["core"], 11)], 7)


def predlog_obj(p):
    return {"virtualSensors": virtual_obj(p["vcore"], p["vsurf"], p["vamb"]), "state": state_name(p["state"]), "mode": pmode_name(p["mode"]),
            "type": ptype_name(p["type"]), "setpoint": tenths(p["sp"]), "rawSecondsRemaining": p["secs"], "estimatedCore": core_c(p["core"])}


PL = dict(vcore=0, vsurf=0, vamb=3, state=3, mode=1, type=1, sp=650, secs=1234, core=600)


def log_payload(seq, raws, p): return u32(seq) + temps_bytes(raws) + predlog_bytes(p)


def log_body(probe, seq, raws, p):
    return {"type": "logRecord", "probe": probe, "sequence": seq, "temperatures": [celsius(r) for r in raws], "prediction": predlog_obj(p)}


def padded(text, n): return text.encode().ljust(n, b"\0")


def gen_uart():
    F = "uart_frames"
    counter = [0]

    def out(name, desc, body, source="spec"):
        write(F, name, desc, source, body)

    # ---- encode requests
    probe_cases = [
        ("read_session_info", "Read Session Information, no payload", {"type": "readSessionInfo"}),
        ("read_logs_0_127", "Read Logs 0..127", {"type": "readLogs", "start": 0, "end": 127}),
        ("read_logs_max", "Read Logs 0..0xFFFFFFFF", {"type": "readLogs", "start": 0, "end": 0xFFFFFFFF}),
        ("read_logs_single", "Read Logs of one record", {"type": "readLogs", "start": 5000, "end": 5000}),
        ("set_prediction_65_time_to_removal", "Set Prediction 65.0 C, time to removal", {"type": "setPrediction", "setpoint": 65.0, "mode": "timeToRemoval"}),
        ("set_prediction_102_3_removal_and_resting", "Set Prediction at the 10-bit maximum 102.3 C, removal and resting", {"type": "setPrediction", "setpoint": 102.3, "mode": "removalAndResting"}),
        ("set_prediction_zero_none", "Set Prediction 0 C, mode none (cancel)", {"type": "setPrediction", "setpoint": 0.0, "mode": "none"}),
        ("set_prediction_63_3", "Set Prediction 63.3 C: 0.1 C resolution", {"type": "setPrediction", "setpoint": 63.3, "mode": "timeToRemoval"}),
        ("set_prediction_0_1", "Set Prediction 0.1 C", {"type": "setPrediction", "setpoint": 0.1, "mode": "removalAndResting"}),
        ("set_alarms_all_unset", "Set alarms: all 22 unset at -20 C", {"type": "setAlarms"}),
        ("set_alarms_core_high_ambient_low", "Set alarms: core high 74.5 C, ambient low 100 C", {"type": "setAlarms", "high": {"core": {"set": True, "temperature": 74.5}}, "low": {"ambient": {"set": True, "temperature": 100.0}}}),
        ("set_alarms_extremes", "Set alarms: every channel high at 799 C and low at -20 C, all set",
         {"type": "setAlarms", "high": {c: {"set": True, "temperature": 799.0} for c in CHANNELS}, "low": {c: {"set": True, "temperature": -20.0} for c in CHANNELS}}),
        ("set_alarms_tripped_bits_passed_through", "Set alarms: tripped/alarming bits are written as given (the probe ignores tripped)",
         {"type": "setAlarms", "high": {"t1": {"set": True, "tripped": True, "alarming": True, "temperature": 50.0}}}),
        ("set_alarms_resolution", "Set alarms: 0.1 C resolution and mixed channels",
         {"type": "setAlarms", "high": {"t2": {"set": True, "temperature": 12.3}, "surface": {"set": True, "temperature": 300.7}}, "low": {"t8": {"set": False, "temperature": 0.0}, "core": {"set": True, "temperature": -5.5}}}),
        ("silence_alarms", "Silence Alarms, no payload", {"type": "silenceAlarms"}),
    ]
    for name, desc, r in probe_cases:
        out("request_probe_" + name, desc, {"kind": "encodeRequest", "variant": "probe", "request": r, "expectedHex": hx(encode_probe(r))})
    rids = [0x00000001, 0xDEADBEEF, 0x00000000, 0xFFFFFFFF, 0x12345678]
    node_cases = probe_cases + [
        ("read_probe_firmware", "Probe Firmware Revision request (node only)", {"type": "readProbeFirmware"}),
        ("read_probe_hardware", "Probe Hardware Revision request (node only)", {"type": "readProbeHardware"}),
        ("read_probe_model", "Probe Model Information request (node only); 4-byte payload as sent by the Android SDK", {"type": "readProbeModel"}),
    ]
    for i, (name, desc, r) in enumerate(node_cases):
        rid = rids[i % len(rids)]
        serial = SERIAL if i % 3 else (0xFFFFFFFF if i % 2 else 0x00000001)
        out("request_node_" + name, desc + " (node: probe serial prefix and request ID)",
            {"kind": "encodeRequest", "variant": "node", "probe": "%08X" % serial, "requestId": rid, "request": r,
             "expectedHex": hx(encode_node(r, serial, rid))})

    def enc_err(name, desc, variant, r, error, **extra):
        out("request_error_" + name, desc, dict({"kind": "encodeRequest", "variant": variant, "request": r, "expectedError": error}, **extra), "hand-built")

    enc_err("setpoint_102_4", "Set point 102.4 C does not fit 10 bits", "probe", {"type": "setPrediction", "setpoint": 102.4, "mode": "timeToRemoval"}, {"kind": "outOfRange"})
    enc_err("setpoint_negative", "Negative set point", "probe", {"type": "setPrediction", "setpoint": -0.1, "mode": "timeToRemoval"}, {"kind": "outOfRange"})
    enc_err("setpoint_node_200", "Set point 200 C over a node", "node", {"type": "setPrediction", "setpoint": 200.0, "mode": "none"}, {"kind": "outOfRange"}, probe="10005A3F", requestId=1)
    enc_err("prediction_mode_reserved", "Reserved prediction mode 3 cannot be sent", "probe", {"type": "setPrediction", "setpoint": 60.0, "mode": "reserved"}, {"kind": "outOfRange"})
    enc_err("alarm_800", "Alarm temperature 800 C is above 799", "probe", {"type": "setAlarms", "high": {"core": {"set": True, "temperature": 800.0}}}, {"kind": "outOfRange"})
    enc_err("alarm_minus_20_1", "Alarm temperature -20.1 C is below -20", "probe", {"type": "setAlarms", "low": {"t1": {"set": True, "temperature": -20.1}}}, {"kind": "outOfRange"})
    enc_err("node_missing_probe", "Node requests must name the probe", "node", {"type": "readSessionInfo"}, {"kind": "missingField"}, requestId=7)
    enc_err("node_missing_request_id", "Node requests must carry a request ID", "node", {"type": "readSessionInfo"}, {"kind": "missingField"}, probe="10005A3F")
    enc_err("probe_cannot_read_firmware", "0x46-0x48 exist only on nodes", "probe", {"type": "readProbeFirmware"}, {"kind": "unknownMessageType", "type": 0x46})

    # ---- decode responses
    def dec(name, desc, variant, data, expected, source="spec"):
        out("response_" + name, desc, {"kind": "decodeResponse", "variant": variant, "hex": hx(data), "expected": expected}, source)

    def ack(mtype, ok, rid=None, sid=None): return {"messageType": mtype, "success": bool(ok), "requestId": rid, "responseId": sid, "body": {"type": "ack"}}

    def info(mtype, ok, body, rid=None, sid=None): return {"messageType": mtype, "success": bool(ok), "requestId": rid, "responseId": sid, "body": body}

    sess = u32(0x1A2B3C4D) + u16(5000)
    sbody = {"type": "sessionInfo", "probe": None, "sessionId": 0x1A2B3C4D, "samplePeriodMs": 5000}
    dec("probe_session_info", "Read Session Information response", "probe", resp_probe(3, 1, sess), info(3, 1, sbody))
    dec("probe_session_info_id_0", "Session ID 0 is reported raw by the UART response", "probe", resp_probe(3, 1, u32(0) + u16(0)),
        info(3, 1, {"type": "sessionInfo", "probe": None, "sessionId": 0, "samplePeriodMs": 0}))
    dec("probe_session_info_max", "Session ID and period at maximum", "probe", resp_probe(3, 1, u32(0xFFFFFFFF) + u16(0xFFFF)),
        info(3, 1, {"type": "sessionInfo", "probe": None, "sessionId": 0xFFFFFFFF, "samplePeriodMs": 65535}))
    dec("probe_session_info_trailing_ignored", "Extra payload bytes after the known fields are ignored", "probe", resp_probe(3, 1, sess + bytes([1, 2, 3])), info(3, 1, sbody))
    # Probe 1000D027, fw v2.3.3 (spec/replays/verify-fixes): the bytes resp_probe builds must match the wire.
    hw = resp_probe(3, 1, u32(0x0160D73D) + u16(5000))
    assert hw == bytes.fromhex("CAFEB83C0301063DD760018813"), hx(hw)
    dec("probe_session_info_hw_fw_2_3_3", "Read Session Information response captured from fw v2.3.3", "probe", hw,
        info(3, 1, {"type": "sessionInfo", "probe": None, "sessionId": 0x0160D73D, "samplePeriodMs": 5000}), source="hardware")
    dec("probe_session_info_failure", "success = 0 with no payload decodes as a failed ack", "probe", resp_probe(3, 0), ack(3, 0))
    dec("probe_session_info_failure_with_payload", "success = 0 ignores the payload", "probe", resp_probe(3, 0, sess), ack(3, 0))

    raws = [raw_of(c) for c in (20.5, 30, 40, 50, 60, 70, 80, 90)]
    dec("probe_log_record", "Read Logs response record (24-byte payload)", "probe", resp_probe(4, 1, log_payload(42, raws, PL)), info(4, 1, log_body(None, 42, raws, PL)))
    pl2 = dict(vcore=5, vsurf=3, vamb=3, state=4, mode=2, type=2, sp=1023, secs=131071, core=2047)
    dec("probe_log_record_extremes", "Log record at sequence 0xFFFFFFFF with maximum prediction fields and raw 8191 temperatures", "probe",
        resp_probe(4, 1, log_payload(0xFFFFFFFF, [8191] * 8, pl2)), info(4, 1, log_body(None, 0xFFFFFFFF, [8191] * 8, pl2)))
    pl3 = dict(vcore=2, vsurf=1, vamb=0, state=0, mode=0, type=0, sp=0, secs=0, core=0)
    dec("probe_log_record_zero", "Log record 0 with every field zero (-20 C temperatures)", "probe", resp_probe(4, 1, log_payload(0, [0] * 8, pl3)), info(4, 1, log_body(None, 0, [0] * 8, pl3)))
    pl4 = dict(vcore=1, vsurf=2, vamb=1, state=15, mode=3, type=3, sp=1, secs=1, core=1)
    dec("probe_log_record_reserved_values", "Log record with reserved state/mode/type", "probe", resp_probe(4, 1, log_payload(7, [7780] * 8, pl4)), info(4, 1, log_body(None, 7, [7780] * 8, pl4)))
    dec("probe_log_failure", "Read Logs failure (success = 0, empty payload)", "probe", resp_probe(4, 0), ack(4, 0))
    for t, nm in [(5, "set_prediction"), (0x0B, "set_alarms"), (0x0C, "silence_alarms"), (1, "set_probe_id"), (2, "set_probe_color"),
                  (7, "configure_food_safe"), (8, "reset_food_safe"), (9, "set_power_mode"), (0x0A, "reset_probe")]:
        dec("probe_ack_%s" % nm, "Response to 0x%02X with no payload, success" % t, "probe", resp_probe(t, 1), ack(t, 1))
    for t, nm in [(5, "set_prediction"), (0x0B, "set_alarms"), (0x0C, "silence_alarms")]:
        dec("probe_ack_%s_failure" % nm, "Response to 0x%02X with success = 0" % t, "probe", resp_probe(t, 0), ack(t, 0))
    dec("probe_success_byte_nonzero", "Any non-zero success byte counts as success", "probe", resp_probe(5, 7), ack(5, 1))

    def dec_err(name, desc, variant, data, error):
        out("response_error_" + name, desc, {"kind": "decodeResponse", "variant": variant, "hex": hx(data), "expectedError": error}, "hand-built")

    dec_err("probe_log_too_short", "Successful Read Logs response with only 10 payload bytes", "probe", resp_probe(4, 1, bytes(10)), {"kind": "tooShort", "expected": 24, "actual": 10})
    dec_err("probe_session_too_short", "Successful session info with 5 payload bytes", "probe", resp_probe(3, 1, bytes(5)), {"kind": "tooShort", "expected": 6, "actual": 5})
    dec_err("probe_session_empty_success", "Successful session info with no payload", "probe", resp_probe(3, 1), {"kind": "tooShort", "expected": 6, "actual": 0})
    dec_err("probe_unknown_type", "Unknown response type 0x7E", "probe", resp_probe(0x7E, 1), {"kind": "unknownMessageType", "type": 0x7E})
    dec_err("probe_type_0x46_not_a_probe_message", "0x46 does not exist on the probe's own UART", "probe", resp_probe(0x46, 1, bytes(24)), {"kind": "unknownMessageType", "type": 0x46})
    dec_err("probe_unknown_type_failed", "Unknown type with success = 0 is still unknown", "probe", resp_probe(0x7E, 0), {"kind": "unknownMessageType", "type": 0x7E})

    # node responses
    RID, SID = 0xCAFEBABE, 0x0BADF00D
    nsess = u32(SERIAL) + sess
    nbody = {"type": "sessionInfo", "probe": "%08X" % SERIAL, "sessionId": 0x1A2B3C4D, "samplePeriodMs": 5000}
    dec("node_session_info", "Node Read Session Information response (serial + 6 bytes)", "node", resp_node(3, RID, SID, 1, nsess), info(3, 1, nbody, RID, SID))
    dec("node_session_info_id_0", "Node session info with session ID 0 reported raw", "node", resp_node(3, RID, SID, 1, u32(SERIAL) + u32(0) + u16(0)),
        info(3, 1, {"type": "sessionInfo", "probe": "%08X" % SERIAL, "sessionId": 0, "samplePeriodMs": 0}, RID, SID))
    dec("node_session_info_serial_0", "Serial 0 in a node response means no probe present; passed through", "node", resp_node(3, 1, 2, 1, u32(0) + sess),
        info(3, 1, {"type": "sessionInfo", "probe": "00000000", "sessionId": 0x1A2B3C4D, "samplePeriodMs": 5000}, 1, 2))
    dec("node_session_info_failure", "Node session info failure", "node", resp_node(3, RID, SID, 0), ack(3, 0, RID, SID))
    dec("node_log_record", "Node Read Logs response record (28-byte payload)", "node", resp_node(4, RID, SID, 1, u32(SERIAL) + log_payload(42, raws, PL)),
        info(4, 1, log_body("%08X" % SERIAL, 42, raws, PL), RID, SID))
    dec("node_log_record_extremes", "Node log record with maximum fields", "node", resp_node(4, 0, 0xFFFFFFFF, 1, u32(0xFFFFFFFF) + log_payload(0xFFFFFFFF, [8191] * 8, pl2)),
        info(4, 1, log_body("FFFFFFFF", 0xFFFFFFFF, [8191] * 8, pl2), 0, 0xFFFFFFFF))
    dec("node_log_failure", "Node Read Logs failure", "node", resp_node(4, RID, SID, 0), ack(4, 0, RID, SID))
    for t, nm in [(5, "set_prediction"), (0x0B, "set_alarms")]:
        dec("node_ack_%s" % nm, "Node response to 0x%02X, no payload" % t, "node", resp_node(t, RID, SID, 1), ack(t, 1, RID, SID))
        dec("node_ack_%s_failure" % nm, "Node response to 0x%02X with success = 0" % t, "node", resp_node(t, RID, SID, 0), ack(t, 0, RID, SID))
    dec("node_ack_silence_alarms", "Node Silence Alarms response carries product type, probe serial and node serial; ignored", "node",
        resp_node(0x0C, RID, SID, 1, bytes([1]) + u32(SERIAL) + padded("DSP0000001", 10)), ack(0x0C, 1, RID, SID))
    dec("node_ack_silence_alarms_failure", "Node Silence Alarms failure", "node", resp_node(0x0C, RID, SID, 0), ack(0x0C, 0, RID, SID))
    rev = lambda kind, text: {"type": "revision", "probe": "%08X" % SERIAL, "kind": kind, "text": text}
    dec("node_firmware_revision", "Probe Firmware Revision response: serial + 20-byte NUL-padded string", "node", resp_node(0x46, RID, SID, 1, u32(SERIAL) + padded("v1.4.2-build7", 20)),
        info(0x46, 1, rev("firmware", "v1.4.2-build7"), RID, SID))
    dec("node_firmware_revision_full_20_chars", "20-character firmware string with no NUL terminator", "node", resp_node(0x46, RID, SID, 1, u32(SERIAL) + b"12345678901234567890"),
        info(0x46, 1, rev("firmware", "12345678901234567890"), RID, SID))
    dec("node_hardware_revision", "Probe Hardware Revision response: serial + 16-byte string", "node", resp_node(0x47, RID, SID, 1, u32(SERIAL) + padded("HW-B2", 16)),
        info(0x47, 1, rev("hardware", "HW-B2"), RID, SID))
    dec("node_model_information", "Probe Model Information response: serial + 50-byte string", "node", resp_node(0x48, RID, SID, 1, u32(SERIAL) + padded("PROBE|SKU-100|LOT-2024-17", 50)),
        info(0x48, 1, rev("model", "PROBE|SKU-100|LOT-2024-17"), RID, SID))
    dec("node_model_information_empty_string", "All-NUL model string decodes to an empty string", "node", resp_node(0x48, RID, SID, 1, u32(SERIAL) + bytes(50)),
        info(0x48, 1, rev("model", ""), RID, SID))
    for t, nm, k in [(0x46, "firmware", "firmware"), (0x47, "hardware", "hardware"), (0x48, "model", "model")]:
        dec("node_%s_failure" % nm, "Node %s response with success = 0" % nm, "node", resp_node(t, RID, SID, 0), ack(t, 0, RID, SID))
    dec_err("node_log_too_short", "Node log response with 20 payload bytes (needs 28)", "node", resp_node(4, RID, SID, 1, bytes(20)), {"kind": "tooShort", "expected": 28, "actual": 20})
    dec_err("node_session_too_short", "Node session info with 9 payload bytes (needs 10)", "node", resp_node(3, RID, SID, 1, bytes(9)), {"kind": "tooShort", "expected": 10, "actual": 9})
    dec_err("node_firmware_too_short", "Node firmware response with 10 payload bytes (needs 24)", "node", resp_node(0x46, RID, SID, 1, bytes(10)), {"kind": "tooShort", "expected": 24, "actual": 10})
    dec_err("node_unknown_type", "Node response type 0x7E", "node", resp_node(0x7E, RID, SID, 1), {"kind": "unknownMessageType", "type": 0x7E})

    gen_streams(out)


def gen_streams(out):
    sess = resp_probe(3, 1, u32(0x1A2B3C4D) + u16(5000))
    ack1 = resp_probe(5, 1)
    log = resp_probe(4, 1, log_payload(9, [raw_of(25.0)] * 8, PL))

    def fobj(data, direction="response", variant="probe"):
        if variant == "probe":
            hl = 7 if direction == "response" else 6
            if direction == "response":
                return frame_obj("response", data[4], None, None, bool(data[5]), data[hl:])
            return frame_obj("request", data[4], None, None, None, data[hl:])
        t = data[4]
        if t & 0x80:
            return frame_obj("response", t & 0x7F, int.from_bytes(data[5:9], "little"), int.from_bytes(data[9:13], "little"), bool(data[13]), data[15:])
        return frame_obj("request", t, int.from_bytes(data[5:9], "little"), None, None, data[10:])

    def stream(name, desc, chunks, frames, errors=(), variant="probe", direction="response", source="hand-built"):
        out("stream_" + name, desc, {"kind": "stream", "variant": variant, "direction": direction, "chunks": [hx(c) for c in chunks],
                                     "expectedFrames": [fobj(f, direction if variant == "probe" else None, variant) for f in frames],
                                     "expectedErrors": list(errors)}, source)

    bytewise = lambda d: [bytes([b]) for b in d]
    stream("single_frame", "One frame in one notification", [sess], [sess])
    stream("empty_stream", "No chunks", [], [])
    stream("empty_chunks_ignored", "Empty notifications around a frame", [b"", sess, b""], [sess])
    stream("zero_length_payload", "Frame with an empty payload", [ack1], [ack1])
    stream("split_every_byte", "Two frames delivered one byte per notification", bytewise(sess + ack1), [sess, ack1])
    stream("split_sync_bytes", "CA and FE in separate notifications", [sess[:1], sess[1:]], [sess])
    stream("split_mid_header", "Split after 3 bytes of the header", [sess[:3], sess[3:]], [sess])
    stream("split_at_header_end_minus_one", "Split one byte before the end of the 7-byte header", [sess[:6], sess[6:]], [sess])
    stream("split_at_header_end", "Split exactly at the end of the header", [sess[:7], sess[7:]], [sess])
    stream("split_mid_payload", "Split inside the payload", [log[:15], log[15:]], [log])
    stream("split_before_last_byte", "Last byte arrives alone", [log[:-1], log[-1:]], [log])
    stream("merged_two", "Two frames in one notification", [sess + ack1], [sess, ack1])
    stream("merged_three", "Three frames in one notification", [sess + ack1 + log], [sess, ack1, log])
    stream("split_across_frame_boundary", "A notification ends inside one frame and starts the next frame's tail plus another frame",
           [sess + ack1[:5], ack1[5:] + log], [sess, ack1, log])
    stream("chunks_of_7", "Four frames cut into fixed 7-byte chunks", [(sess + log + ack1 + sess)[i:i + 7] for i in range(0, len(sess + log + ack1 + sess), 7)], [sess, log, ack1, sess])
    stream("truncated_tail_stays_buffered", "A frame cut short at the end of the stream yields nothing and no error", [sess + log[:-1]], [sess])
    stream("payload_contains_sync_bytes", "Payload that itself contains CA FE CA FE is read by length, not rescanned",
           [resp_probe(3, 1, bytes([0xCA, 0xFE, 0xCA, 0xFE, 0xCA, 0xFE]))] , [resp_probe(3, 1, bytes([0xCA, 0xFE, 0xCA, 0xFE, 0xCA, 0xFE]))])
    big = resp_probe(4, 1, bytes(range(255)))
    stream("max_payload_255", "255-byte payload delivered in 20-byte notifications", [big[i:i + 20] for i in range(0, len(big), 20)], [big])

    # garbage and resync
    stream("garbage_prefix", "Garbage before the first frame", [bytes([0x00, 0x11, 0x22, 0x33]) + sess], [sess], ["badSync"])
    stream("garbage_between", "Garbage between two frames in one notification", [sess + bytes([1, 2, 3, 4, 5]) + ack1], [sess, ack1], ["badSync"])
    stream("garbage_between_separate_chunks", "Garbage arrives as its own notification", [sess, bytes([9, 9, 9]), ack1], [sess, ack1], ["badSync"])
    stream("garbage_trailing", "Garbage after the last frame", [sess + bytes([1, 2, 3])], [sess], ["badSync"])
    stream("only_garbage", "Nothing but garbage", [bytes([1, 2, 3, 4, 5])], [], ["badSync"])
    stream("ca_before_sync", "A stray CA right before CA FE", [bytes([0xCA]) + sess], [sess], ["badSync"])
    stream("single_ca_then_frame_tail", "Garbage ends in CA that is really the start of the next frame, split before FE",
           [sess + bytes([1, 2]) + ack1[:1], ack1[1:]], [sess, ack1], ["badSync"])
    stream("corrupted_sync_byte", "First sync byte of the middle frame is damaged: that frame is lost, the next resynchronizes",
           [sess + bytes([ack1[0] ^ 1]) + ack1[1:] + log], [sess, log], ["badSync"])

    # bad CRC
    bad_crc = bytearray(ack1); bad_crc[2] ^= 0xFF
    stream("bad_crc_between_frames", "A frame with a wrong CRC is reported and skipped; neighbours survive",
           [sess + bytes(bad_crc) + log], [sess, log], ["badCrc", "badSync"])
    bad_payload = bytearray(log); bad_payload[12] ^= 0x01
    stream("bad_crc_payload_bit_flip", "One flipped payload bit", [bytes(bad_payload) + sess], [sess], ["badCrc", "badSync"])
    stream("bad_crc_last_frame", "Bad CRC on the final frame", [sess + bytes(bad_crc)], [sess], ["badCrc", "badSync"])
    stream("bad_crc_split_delivery", "Bad CRC frame delivered byte by byte", bytewise(bytes(bad_crc) + sess), [sess], ["badCrc", "badSync"])

    # false syncs
    stream("false_sync_long_length_swallows_nothing", "Garbage that looks like a header claiming 200 payload bytes must not swallow the real frame behind it",
           [bytes([0xCA, 0xFE, 0x11, 0x22, 0x03, 0x01, 200]) + sess], [sess], ["badSync"])
    stream("false_sync_short_length_bad_crc", "Garbage header with a short length fails its CRC; the following frame is found",
           [bytes([0xCA, 0xFE, 0x11, 0x22, 0x03, 0x01, 0x02, 0xAA, 0xBB]) + sess], [sess], ["badCrc", "badSync"])
    long_len = bytearray(ack1); long_len[6] = 200
    stream("corrupted_length_byte_longer", "Length byte of the middle frame corrupted to 200", [sess + bytes(long_len) + log], [sess, log], ["badSync"])

    # request direction on the probe UART
    rq = req_probe(5, u16(650 | 1 << 10))
    stream("probe_request_direction", "Probe framer reading requests (6-byte header), e.g. a simulator reading the app's writes",
           [rq[:4], rq[4:] + req_probe(0x0C)], [rq, req_probe(0x0C)], direction="request")
    stream("probe_request_bad_crc", "Request stream with a damaged CRC", [bytes([rq[0], rq[1], rq[2] ^ 0xFF]) + rq[3:] + req_probe(3)], [req_probe(3)],
           ["badCrc", "badSync"], direction="request")

    # node streams
    RID, SID = 0x01020304, 0x0A0B0C0D
    nresp = resp_node(3, RID, SID, 1, u32(SERIAL) + u32(77) + u16(1000))
    nfail = resp_node(5, RID + 1, SID + 1, 0)
    nlog = resp_node(4, RID + 2, SID + 2, 1, u32(SERIAL) + log_payload(3, [raw_of(30)] * 8, PL))
    from gen_status import default_status, status_bytes
    st45 = u32(SERIAL) + status_bytes(default_status(), network=1 << 6)
    n45 = req_node(0x45, 0xAABBCCDD, st45)
    nreq = req_node(5, 0x11223344, u32(SERIAL) + u16(650 | 2 << 10))
    stream("node_response", "Node response with request and response IDs", [nresp], [nresp], variant="node")
    stream("node_notification_0x45_105_bytes", "Node Probe Status notification (request-direction frame, 105-byte payload)", [n45], [n45], variant="node", source="spec")
    stream("node_notification_0x45_split_mtu", "0x45 notification split into 20-byte notifications", [n45[i:i + 20] for i in range(0, len(n45), 20)], [n45], variant="node")
    legacy45 = req_node(0x45, 7, u32(SERIAL) + status_bytes(default_status(), network=0, layout="legacy"))
    stream("node_notification_0x45_99_bytes", "0x45 notification from a node without session fields (99-byte payload)", [legacy45], [legacy45], variant="node")
    stream("node_mixed_merged", "Response, notification, failed response and request merged in one notification", [nresp + n45 + nfail + nreq], [nresp, n45, nfail, nreq], variant="node")
    stream("node_split_every_byte", "Node frames one byte per notification", bytewise(nresp + nfail), [nresp, nfail], variant="node")
    stream("node_split_in_type_byte_area", "Split after 4 bytes, before the type byte that selects the header size", [nresp[:4], nresp[4:]], [nresp], variant="node")
    stream("node_split_after_type_byte", "Split right after the type byte", [nresp[:5], nresp[5:]], [nresp], variant="node")
    stream("node_split_mid_response_header", "Split inside the 15-byte response header", [nresp[:11], nresp[11:]], [nresp], variant="node")
    stream("node_zero_payload_response", "Node response header only", [nfail], [nfail], variant="node")
    nbad = bytearray(nfail); nbad[3] ^= 0x10
    stream("node_bad_crc", "Node response with a bad CRC between valid frames", [nresp + bytes(nbad) + nlog], [nresp, nlog], ["badCrc", "badSync"], variant="node")
    stream("node_garbage_prefix", "Garbage before a node frame", [bytes([1, 2, 3]) + nlog], [nlog], ["badSync"], variant="node")
    stream("node_false_sync_long_length", "Garbage header claiming a long payload in front of a real node frame",
           [bytes([0xCA, 0xFE, 0, 0, 0x45, 1, 2, 3, 4, 250]) + nresp], [nresp], ["badSync"], variant="node")
    stream("node_max_payload_255", "Node frame with a 255-byte payload", [req_node(0x49, 1, bytes(range(255)))[i:i + 20] for i in range(0, 10 + 255, 20)],
           [req_node(0x49, 1, bytes(range(255)))], variant="node")
