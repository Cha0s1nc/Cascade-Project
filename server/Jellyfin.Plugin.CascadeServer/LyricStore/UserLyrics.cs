using System;
using System.IO;
using MediaBrowser.Common.Configuration;

namespace Jellyfin.Plugin.CascadeServer.LyricStore;

/// <summary>
/// Each user's own copy of a song's lyrics, made with the lyrics editor or saved by a
/// user who is not an administrator: {DataPath}/cascade-lyrics/user-lyrics/{userId}/{itemId}.slrc
/// (word-level, LRC or TTML) or .lrc (line-level). Kept in the plugin's folder, never next
/// to the audio file, so the music folder can stay read-only to Jellyfin and two people's
/// saves never touch the same file. Only an administrator's save reaches the shared
/// sidecar every user gets.
/// </summary>
public static class UserLyrics
{
    private static string Folder(IApplicationPaths paths, Guid userId) => Path.Combine(DataDir.Root(paths), "user-lyrics", userId.ToString("N"));

    /// <summary>Gets the user's own copy and whether it is line-level (.lrc); null when they have none.</summary>
    public static (string Text, bool Synced)? Read(IApplicationPaths paths, Guid userId, Guid itemId)
    {
        if (userId == Guid.Empty) return null;
        foreach (var (ext, synced) in new[] { (".slrc", false), (".lrc", true) })
        {
            var file = Path.Combine(Folder(paths, userId), itemId.ToString("N") + ext);
            if (File.Exists(file)) return (File.ReadAllText(file), synced);
        }

        return null;
    }

    /// <summary>Saves the user's own copy, replacing any they had in the other kind.</summary>
    public static void Write(IApplicationPaths paths, Guid userId, Guid itemId, string text, bool synced)
    {
        var dir = Folder(paths, userId);
        Directory.CreateDirectory(dir);
        Delete(paths, userId, itemId);
        var file = Path.Combine(dir, itemId.ToString("N") + (synced ? ".lrc" : ".slrc"));
        var tmp = file + ".tmp";
        File.WriteAllText(tmp, text);
        File.Move(tmp, file, overwrite: true);
    }

    /// <summary>Drops the user's own copy (back to the shared lyrics). False when there was none.</summary>
    public static bool Delete(IApplicationPaths paths, Guid userId, Guid itemId)
    {
        var any = false;
        foreach (var ext in new[] { ".slrc", ".lrc" })
        {
            var file = Path.Combine(Folder(paths, userId), itemId.ToString("N") + ext);
            if (!File.Exists(file)) continue;
            File.Delete(file);
            any = true;
        }

        return any;
    }
}
