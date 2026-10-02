using System.Runtime.CompilerServices;
using ProtoBuf.Meta;
using ProtoBuf.Serializers;

namespace Iridium.Steam;

internal static class SteamSerialization
{
    // This is a native framework entry assembly: initialization must precede every exported call.
#pragma warning disable CA2255
    [ModuleInitializer]
#pragma warning restore CA2255
    internal static void Initialize()
    {
        RuntimeTypeModel.Default.AutoCompile = false;
        // NativeAOT must see concrete value-type instantiations used by Steam's generated messages.
        _ = RepeatedSerializer.CreateList<uint>();
        _ = RepeatedSerializer.CreateList<int>();
        _ = RepeatedSerializer.CreateList<ulong>();
        _ = RepeatedSerializer.CreateList<long>();
        _ = RepeatedSerializer.CreateList<float>();
        _ = RepeatedSerializer.CreateList<double>();
        _ = RepeatedSerializer.CreateList<bool>();
    }
}
