namespace Combustion.Codec.Tests;

/// <summary>
/// Random streams of valid frames, garbage and damaged frames, cut into random notifications:
/// every valid frame must come out exactly once and in order.
/// </summary>
public class FramerFuzzTests
{
    public static IEnumerable<object[]> Seeds() => Enumerable.Range(100, 300).Select(s => new object[] { (ulong)s });

    private static UartFrame RandomFrame(SeededRng r, UartVariant variant, UartDirection direction)
    {
        var isResponse = variant == UartVariant.Node ? r.Bool() : direction == UartDirection.Response;
        var length = r.Bool() ? (int)r.Int(0, 12) : (int)r.Int(0, 255);
        // Payloads often contain sync bytes on purpose.
        var payload = Enumerable.Range(0, length).Select(_ => r.Pick(new byte[] { 0xCA, 0xFE, r.Byte() })).ToArray();
        return new UartFrame(
            variant, isResponse ? UartDirection.Response : UartDirection.Request, r.Byte(0, 0x7F),
            variant == UartVariant.Node ? r.U32(0, uint.MaxValue) : null,
            variant == UartVariant.Node && isResponse ? r.U32(0, uint.MaxValue) : null,
            isResponse ? r.Bool() : null,
            payload);
    }

    private static byte[] Garbage(SeededRng r) =>
        // Bias toward bytes that look like frame starts.
        Enumerable.Range(0, (int)r.Int(1, 40)).Select(_ => r.Pick(new byte[] { 0xCA, 0xFE, 0x00, r.Byte() })).ToArray();

    private static byte[] Damaged(byte[] bytes, SeededRng r)
    {
        var output = (byte[])bytes.Clone();
        switch (r.Int(0, 2))
        {
            case 0: // flip one bit anywhere after the sync
                output[r.Int(2, output.Length - 1)] ^= (byte)(1 << (int)r.Int(0, 7));
                return output;
            case 1: // break the sync
                output[r.Int(0, 1)] ^= 0x01;
                return output;
            default: // cut off the tail
                return output[..^(int)r.Int(1, output.Length - 1)];
        }
    }

    [Theory, MemberData(nameof(Seeds))]
    public void ValidFramesSurviveGarbageDamageAndArbitraryChunking(ulong seed)
    {
        var rng = new SeededRng(seed);
        var variant = rng.Bool() ? UartVariant.Node : UartVariant.Probe;
        var direction = rng.Bool() ? UartDirection.Request : UartDirection.Response;

        var stream = new List<byte>();
        var expected = new List<UartFrame>();
        var count = (int)rng.Int(1, 25);
        for (var i = 0; i < count; i++)
        {
            if (rng.Int(0, 2) == 0)
            {
                stream.AddRange(Garbage(rng));
            }
            var frame = RandomFrame(rng, variant, direction);
            var bytes = frame.Encoded();
            if (rng.Int(0, 3) == 0)
            {
                stream.AddRange(Damaged(bytes, rng));
            }
            stream.AddRange(bytes);
            expected.Add(frame);
        }

        var framer = new UartFramer(variant, direction);
        var received = new List<UartFrame>();
        var index = 0;
        var all = stream.ToArray();
        while (index < all.Length)
        {
            var size = (int)rng.Int(0, rng.Int(1, 60));
            var end = Math.Min(all.Length, index + size);
            foreach (var output in framer.Push(all.AsSpan(index, end - index)))
            {
                if (output is UartFramerOutput.FrameOutput f)
                {
                    received.Add(f.Frame);
                }
            }
            index += size;
        }
        Assert.True(received.SequenceEqual(expected), $"seed {seed}: got {received.Count} frames, expected {expected.Count}");
    }

    [Fact]
    public void ACutOffTailStaysBufferedUntilTheRestArrives()
    {
        var frame = new UartFrame(UartVariant.Probe, UartDirection.Response, 3, success: true, payload: Enumerable.Range(1, 20).Select(i => (byte)i).ToArray());
        var bytes = frame.Encoded();
        var framer = new UartFramer(UartVariant.Probe);
        for (var cut = 1; cut < bytes.Length; cut++)
        {
            framer.Reset();
            Assert.DoesNotContain(framer.Push(bytes.AsSpan(0, cut)), o => o is UartFramerOutput.FrameOutput);
            Assert.Equal(cut, framer.BufferedByteCount);
            Assert.Equal(new UartFramerOutput[] { new UartFramerOutput.FrameOutput(frame) }, framer.Push(bytes.AsSpan(cut)));
            Assert.Equal(0, framer.BufferedByteCount);
        }
    }

    [Fact]
    public void ResetDropsBufferedBytes()
    {
        var framer = new UartFramer(UartVariant.Node);
        framer.Push([0xCA, 0xFE, 0x00]);
        Assert.Equal(3, framer.BufferedByteCount);
        framer.Reset();
        Assert.Equal(0, framer.BufferedByteCount);
    }
}
