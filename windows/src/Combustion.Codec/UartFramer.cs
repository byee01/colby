namespace Combustion.Codec;

/// <summary>
/// What <see cref="UartFramer.Push"/> yields: a good frame or a framing problem (<c>BadSync</c> for skipped garbage,
/// <c>BadCrc</c> for a frame that failed its CRC).
/// </summary>
public abstract record UartFramerOutput
{
    private UartFramerOutput() { }

    public sealed record FrameOutput(UartFrame Frame) : UartFramerOutput;

    public sealed record ErrorOutput(CodecError Error) : UartFramerOutput;
}

/// <summary>
/// Reassembles UART frames from BLE notifications, which may split a frame across several
/// notifications or merge several frames into one. Resynchronizes on <c>CA FE</c> after garbage or a bad CRC.
/// <para>
/// A probe's UART carries one direction per stream, chosen with <c>direction</c> (responses by default).
/// A node's frames say which they are in the type byte, so <c>direction</c> is ignored for <c>Node</c>.
/// </para>
/// Unlike the Swift struct this is a reference type; use one instance per stream.
/// </summary>
public sealed class UartFramer
{
    private readonly List<byte> _buffer = [];

    public UartFramer(UartVariant variant, UartDirection direction = UartDirection.Response)
    {
        Variant = variant;
        Direction = direction;
    }

    public UartVariant Variant { get; }

    public UartDirection Direction { get; }

    /// <summary>Bytes held while waiting for the rest of a frame.</summary>
    public int BufferedByteCount => _buffer.Count;

    public void Reset() => _buffer.Clear();

    public List<UartFramerOutput> Push(ReadOnlySpan<byte> bytes)
    {
        foreach (var b in bytes)
        {
            _buffer.Add(b);
        }
        var output = new List<UartFramerOutput>();
        while (true)
        {
            var sync = FindSync(0);
            if (sync is not { } syncIndex)
            {
                DropGarbage(output);
                return output;
            }
            if (syncIndex > 0)
            {
                Drop(syncIndex, output);
            }
            var parsed = Parse(0);
            switch (parsed)
            {
                case Parsed.Frame(var frame, var length):
                    output.Add(new UartFramerOutput.FrameOutput(frame));
                    _buffer.RemoveRange(0, length);
                    break;
                case Parsed.Invalid(var error):
                    output.Add(new UartFramerOutput.ErrorOutput(error));
                    _buffer.RemoveRange(0, 2);
                    break;
                default:
                {
                    // A false sync inside garbage can claim a length that swallows real frames.
                    // If a complete valid frame follows, the pending candidate was not a frame.
                    if (LaterValidFrame() is not { } later)
                    {
                        return output;
                    }
                    Drop(later, output);
                    break;
                }
            }
        }
    }

    private abstract record Parsed
    {
        public sealed record Frame(UartFrame Value, int Length) : Parsed;

        public sealed record Incomplete : Parsed;

        public sealed record Invalid(CodecError Error) : Parsed;
    }

    private int? FindSync(int start)
    {
        if (_buffer.Count < start + 2)
        {
            return null;
        }
        for (var i = start; i < _buffer.Count - 1; i++)
        {
            if (_buffer[i] == 0xCA && _buffer[i + 1] == 0xFE)
            {
                return i;
            }
        }
        return null;
    }

    private void Drop(int count, List<UartFramerOutput> output)
    {
        _buffer.RemoveRange(0, count);
        output.Add(new UartFramerOutput.ErrorOutput(new CodecError.BadSync()));
    }

    private void DropGarbage(List<UartFramerOutput> output)
    {
        var keep = _buffer.Count > 0 && _buffer[^1] == 0xCA ? 1 : 0;
        var count = _buffer.Count - keep;
        if (count > 0)
        {
            Drop(count, output);
        }
    }

    private int? LaterValidFrame()
    {
        var from = 1;
        while (FindSync(from) is { } sync)
        {
            if (Parse(sync) is Parsed.Frame)
            {
                return sync;
            }
            from = sync + 1;
        }
        return null;
    }

    private Parsed Parse(int start)
    {
        var available = _buffer.Count - start;
        bool isResponse;
        int headerLength;
        if (Variant == UartVariant.Probe)
        {
            isResponse = Direction == UartDirection.Response;
            headerLength = isResponse ? 7 : 6;
        }
        else
        {
            if (available < 5)
            {
                return new Parsed.Incomplete();
            }
            isResponse = (_buffer[start + 4] & 0x80) != 0;
            headerLength = isResponse ? 15 : 10;
        }
        if (available < headerLength)
        {
            return new Parsed.Incomplete();
        }
        var total = headerLength + _buffer[start + headerLength - 1];
        if (available < total)
        {
            return new Parsed.Incomplete();
        }

        var frameBytes = _buffer.GetRange(start, total).ToArray();
        var expected = CombustionCodec.Crc16Ccitt(frameBytes.AsSpan(4));
        var actual = Le.U16(frameBytes, 2);
        if (expected != actual)
        {
            return new Parsed.Invalid(new CodecError.BadCrc(expected, actual));
        }

        var node = Variant == UartVariant.Node;
        var frame = new UartFrame(
            Variant,
            isResponse ? UartDirection.Response : UartDirection.Request,
            node && isResponse ? (byte)(frameBytes[4] & 0x7F) : frameBytes[4],
            node ? Le.U32(frameBytes, 5) : null,
            node && isResponse ? Le.U32(frameBytes, 9) : null,
            isResponse ? frameBytes[headerLength - 2] != 0 : null,
            frameBytes[headerLength..]);
        return new Parsed.Frame(frame, total);
    }
}
