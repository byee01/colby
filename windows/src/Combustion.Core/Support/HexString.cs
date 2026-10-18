namespace Combustion.Core;

/// <summary>Hex helpers for replay files and traces. Encoding is uppercase; decoding accepts either case.</summary>
public static class HexString
{
    public static string Encode(ReadOnlySpan<byte> bytes) => Convert.ToHexString(bytes);

    public static byte[]? Decode(string s)
    {
        if (s.Length % 2 != 0 || !s.All(Uri.IsHexDigit))
        {
            return null;
        }
        return Convert.FromHexString(s);
    }
}
