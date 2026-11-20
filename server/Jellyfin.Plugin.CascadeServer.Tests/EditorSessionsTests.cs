using Jellyfin.Plugin.CascadeServer.LyricFormat;
using Xunit;

namespace Jellyfin.Plugin.CascadeServer.Tests;

public class EditorSessionsTests
{
    [Fact]
    public void ATokenOpensOneWindowLivesWhileItChecksInAndEndsOnClose()
    {
        var now = new DateTime(2026, 11, 19, 12, 0, 0, DateTimeKind.Utc);
        EditorSessions.Now = () => now;
        try
        {
            var user = Guid.NewGuid();
            var song = Guid.NewGuid();
            var s = EditorSessions.Start(user, song, admin: false);
            Assert.Equal(64, s.Token.Length);
            Assert.NotEqual(s.Token, EditorSessions.Start(user, song, admin: false).Token);

            Assert.Same(s, EditorSessions.Find(s.Token));
            Assert.True(EditorSessions.Claim(s), "the window opening claims it");
            Assert.False(EditorSessions.Claim(s), "a second window is refused");
            Assert.Null(EditorSessions.Find("not-a-token"));
            Assert.Null(EditorSessions.Find(null));

            // Checking in keeps it alive past the idle limit; silence ends it.
            now += TimeSpan.FromMinutes(4);
            Assert.NotNull(EditorSessions.Find(s.Token));
            now += TimeSpan.FromMinutes(4);
            Assert.NotNull(EditorSessions.Find(s.Token));
            now += EditorSessions.Idle + TimeSpan.FromSeconds(1);
            Assert.Null(EditorSessions.Find(s.Token));

            var t = EditorSessions.Start(user, song, admin: true);
            Assert.True(t.Admin);
            EditorSessions.End(t.Token);
            Assert.Null(EditorSessions.Find(t.Token));
        }
        finally
        {
            EditorSessions.Now = () => DateTime.UtcNow;
        }
    }
}
