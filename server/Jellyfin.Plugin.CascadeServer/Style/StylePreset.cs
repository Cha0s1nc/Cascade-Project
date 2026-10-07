using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Jellyfin.Plugin.CascadeServer.Style;

/// <summary>
/// Checks a Cascade preset before the server stores it. Pure (no Jellyfin types) so the
/// unit tests compile it directly. Cascade clamps every value itself when it applies a
/// preset (src/core/presets.ts in Cascade-Project), so the server only guards the shape:
/// JSON, size, format and version, at least one of theme or lyrics, and no stray keys.
/// </summary>
public static class StylePreset
{
    /// <summary>Largest accepted preset, the same limit Cascade puts on a pasted one.</summary>
    public const int MaxBytes = 64 * 1024;

    private static readonly string[] Kept = ["format", "version", "name", "theme", "lyrics"];

    /// <summary>
    /// Validates <paramref name="json"/> and returns it cut down to the kept keys, or an
    /// error written for a person.
    /// </summary>
    public static bool TryNormalize(string? json, out string normalized, out string error)
    {
        normalized = string.Empty;
        error = string.Empty;
        if (string.IsNullOrWhiteSpace(json)) { error = "The preset is empty."; return false; }
        if (Encoding.UTF8.GetByteCount(json) > MaxBytes) { error = "That is too large to be a Cascade preset."; return false; }

        JsonObject? root;
        try { root = JsonNode.Parse(json) as JsonObject; }
        catch (JsonException) { error = "That is not a Cascade preset (it is not valid JSON)."; return false; }
        if (root is null) { error = "That is not a Cascade preset."; return false; }

        if (!(root["format"] is JsonValue f && f.TryGetValue<string>(out var format) && format == "cascade-preset"))
        {
            error = "That is not a Cascade preset.";
            return false;
        }

        if (!(root["version"] is JsonValue v && v.TryGetValue<int>(out var version) && version == 1))
        {
            error = "That preset has an unsupported version. Only version 1 is understood.";
            return false;
        }

        if (root["theme"] is not JsonObject && root["lyrics"] is not JsonObject)
        {
            error = "That preset has no theme or lyrics settings in it.";
            return false;
        }

        var kept = new JsonObject();
        foreach (var key in Kept)
        {
            // A theme or lyrics that is present but not an object is dropped, not stored.
            if (!root.TryGetPropertyValue(key, out var value) || value is null) continue;
            if ((key is "theme" or "lyrics") && value is not JsonObject) continue;
            kept[key] = value.DeepClone();
        }

        normalized = kept.ToJsonString();
        return true;
    }
}
