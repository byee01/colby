using System.Runtime.InteropServices;
using Combustion.Core;

namespace Combustion.Windows.Platform;

/// <summary>Prevents idle system sleep during a cook with a power request (<c>PowerCreateRequest</c> +
/// <c>PowerSetRequest(PowerRequestSystemRequired)</c>), so Bluetooth and alarms keep running (docs/02 §9).
/// The display may still turn off. Untested on Windows (built on Linux only).</summary>
public sealed class PowerRequestKeepAwake : IKeepAwake, IDisposable
{
    private const int PowerRequestSystemRequired = 1;
    private const uint PowerRequestContextVersion = 0;
    private const uint PowerRequestContextSimpleString = 0x1;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ReasonContext
    {
        public uint Version;
        public uint Flags;
        [MarshalAs(UnmanagedType.LPWStr)]
        public string SimpleReasonString;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr PowerCreateRequest(ref ReasonContext context);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PowerSetRequest(IntPtr handle, int requestType);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PowerClearRequest(IntPtr handle, int requestType);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    private static readonly IntPtr InvalidHandle = new(-1);

    private readonly object _lock = new();
    private IntPtr _request = IntPtr.Zero;

    /// <summary>True while a power request is held.</summary>
    public bool IsHeld
    {
        get
        {
            lock (_lock)
            {
                return _request != IntPtr.Zero;
            }
        }
    }

    public Task SetHeldAsync(bool held)
    {
        lock (_lock)
        {
            if (held && _request == IntPtr.Zero)
            {
                var context = new ReasonContext
                {
                    Version = PowerRequestContextVersion,
                    Flags = PowerRequestContextSimpleString,
                    SimpleReasonString = "Colby: cook in progress",
                };
                var handle = PowerCreateRequest(ref context);
                if (handle != IntPtr.Zero && handle != InvalidHandle)
                {
                    if (PowerSetRequest(handle, PowerRequestSystemRequired))
                    {
                        _request = handle;
                    }
                    else
                    {
                        CloseHandle(handle);
                    }
                }
            }
            else if (!held && _request != IntPtr.Zero)
            {
                Release();
            }
        }
        return Task.CompletedTask;
    }

    private void Release()
    {
        PowerClearRequest(_request, PowerRequestSystemRequired);
        CloseHandle(_request);
        _request = IntPtr.Zero;
    }

    public void Dispose()
    {
        lock (_lock)
        {
            if (_request != IntPtr.Zero)
            {
                Release();
            }
        }
    }
}
