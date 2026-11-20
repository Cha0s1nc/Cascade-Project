using System;
using System.Collections.Concurrent;
using System.Linq;
using System.Security.Cryptography;

namespace Jellyfin.Plugin.CascadeServer.LyricFormat;

/// <summary>
/// The lyrics editor's sessions. A Cascade app asks for one with the Jellyfin sign-in it
/// already has and gets an editor token: random, accepted only by the editor's routes for
/// that one song, and good for one editor window. The window claims it once as it opens
/// (a second claim is refused), checks in while open, and ends it as it closes; one not
/// heard from for <see cref="Idle"/> (a crash, a sleeping laptop) ends by itself. Held in
/// memory only: a server restart ends every session, which a short-lived token can afford.
/// Pure, no Jellyfin types, so the unit tests compile it.
/// </summary>
public static class EditorSessions
{
    /// <summary>How long a session lasts without a check-in.</summary>
    public static readonly TimeSpan Idle = TimeSpan.FromMinutes(5);

    private static readonly ConcurrentDictionary<string, Session> All = new(StringComparer.Ordinal);

    /// <summary>Gets or sets the clock, for tests.</summary>
    public static Func<DateTime> Now { get; set; } = () => DateTime.UtcNow;

    /// <summary>A session: whose, for which song, whether they may save for everyone.</summary>
    public sealed class Session
    {
        internal Session(string token, Guid userId, Guid itemId, bool admin)
        {
            Token = token;
            UserId = userId;
            ItemId = itemId;
            Admin = admin;
            LastSeenUtc = Now();
        }

        /// <summary>Gets the editor token.</summary>
        public string Token { get; }

        /// <summary>Gets the user it is for.</summary>
        public Guid UserId { get; }

        /// <summary>Gets the song it is for.</summary>
        public Guid ItemId { get; }

        /// <summary>Gets a value indicating whether the user is an administrator, who may save for everyone.</summary>
        public bool Admin { get; }

        internal bool Claimed { get; set; }

        internal DateTime LastSeenUtc { get; set; }
    }

    /// <summary>Starts a session for <paramref name="userId"/> on <paramref name="itemId"/>.</summary>
    public static Session Start(Guid userId, Guid itemId, bool admin)
    {
        Sweep();
        var s = new Session(Convert.ToHexString(RandomNumberGenerator.GetBytes(32)), userId, itemId, admin);
        All[s.Token] = s;
        return s;
    }

    /// <summary>The live session for <paramref name="token"/>, counting this as a check-in; null when there is none.</summary>
    public static Session? Find(string? token)
    {
        if (string.IsNullOrEmpty(token) || !All.TryGetValue(token, out var s)) return null;
        if (Now() - s.LastSeenUtc > Idle)
        {
            All.TryRemove(token, out _);
            return null;
        }

        s.LastSeenUtc = Now();
        return s;
    }

    /// <summary>Claims the session as its window opens. False when it was claimed already: the token opens one window only.</summary>
    public static bool Claim(Session s)
    {
        lock (s)
        {
            if (s.Claimed) return false;
            s.Claimed = true;
            return true;
        }
    }

    /// <summary>Ends the session for <paramref name="token"/>.</summary>
    public static void End(string? token)
    {
        if (!string.IsNullOrEmpty(token)) All.TryRemove(token, out _);
    }

    private static void Sweep()
    {
        var now = Now();
        foreach (var key in All.Where(e => now - e.Value.LastSeenUtc > Idle).Select(e => e.Key).ToList()) All.TryRemove(key, out _);
    }
}
