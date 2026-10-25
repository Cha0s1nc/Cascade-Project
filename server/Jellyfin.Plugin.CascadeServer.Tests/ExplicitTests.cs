using Jellyfin.Plugin.CascadeServer.Explicit;
using Jellyfin.Plugin.CascadeServer.Media;
using Xunit;

namespace Jellyfin.Plugin.CascadeServer.Tests;

public class ExplicitTests
{
    [Theory]
    [InlineData("1", "explicit")]
    [InlineData("4", "explicit")]
    [InlineData(" 1 ", "explicit")]
    [InlineData("true", "explicit")]
    [InlineData("2", "clean")]
    [InlineData("0", null)]
    [InlineData("", null)]
    [InlineData(null, null)]
    [InlineData("3", null)]
    public void TagValues(string? value, string? expected) => Assert.Equal(expected, ExplicitRules.ParseTag(value));

    [Theory]
    [InlineData(1, "explicit")]
    [InlineData(5, "explicit")]
    [InlineData(3, "clean")]
    [InlineData(4, "clean")]
    [InlineData(0, "notexplicit")]
    [InlineData(6, "notexplicit")]
    [InlineData(2, null)]
    [InlineData(null, null)]
    public void DeezerValues(int? value, string? expected) => Assert.Equal(expected, ExplicitRules.FromDeezer(value));

    [Fact]
    public void ItunesValues()
    {
        Assert.Equal("explicit", ExplicitRules.FromItunes("explicit"));
        Assert.Equal("clean", ExplicitRules.FromItunes("cleaned"));
        Assert.Equal("notexplicit", ExplicitRules.FromItunes("notExplicit"));
        Assert.Null(ExplicitRules.FromItunes("other"));
    }

    [Theory]
    [InlineData("Sigur Rós", "sigur ros")]
    [InlineData("DAMN.", "damn")]
    [InlineData("Song (Remastered 2011)", "song")]
    [InlineData("Song [Deluxe] - Single", "song")]
    [InlineData("Kid A - EP", "kid a")]
    [InlineData("君の名は", "君の名は")]
    public void Normalizing(string input, string expected) => Assert.Equal(expected, TitleMatch.Base(input));

    private static readonly string[] Kendrick = ["Kendrick Lamar"];

    [Fact]
    public void MatchesSameSongWithEditionWords() =>
        Assert.True(TitleMatch.IsMatch(Kendrick, "HUMBLE.", 177, "Kendrick Lamar", "HUMBLE. (Remastered)", 178.5));

    [Fact]
    public void RefusesKaraokeSameTitle()
    {
        Assert.False(TitleMatch.IsMatch(Kendrick, "HUMBLE.", 177, "Karaoke Stars", "HUMBLE.", 177));
        Assert.False(TitleMatch.IsMatch(Kendrick, "HUMBLE.", 177, "Kendrick Lamar", "HUMBLE. (Karaoke Version)", 177));
        Assert.False(TitleMatch.IsMatch(Kendrick, "HUMBLE.", 177, "Twinkle Twinkle Little Rock Star", "HUMBLE.", 172));
    }

    [Fact]
    public void RefusesDurationAndUnknownDuration()
    {
        Assert.False(TitleMatch.IsMatch(Kendrick, "HUMBLE.", 177, "Kendrick Lamar", "HUMBLE.", 181));
        Assert.False(TitleMatch.IsMatch(Kendrick, "HUMBLE.", null, "Kendrick Lamar", "HUMBLE.", 177));
    }

    [Fact]
    public void FeaturedArtistsStillMatch() =>
        Assert.True(TitleMatch.IsMatch(["Drake feat. Rihanna"], "Work", 200, "Drake", "Work", 200));

    [Fact]
    public void PickAgreesOrIsUnknown()
    {
        var a = new ExplicitRules.Candidate("Kendrick Lamar", "HUMBLE.", 177, "explicit");
        var b = new ExplicitRules.Candidate("Kendrick Lamar", "HUMBLE.", 177, "clean");
        var far = new ExplicitRules.Candidate("Kendrick Lamar", "HUMBLE.", 179, "clean");
        Assert.Equal("explicit", ExplicitRules.Pick(Kendrick, "HUMBLE.", 177, [a]));
        Assert.Null(ExplicitRules.Pick(Kendrick, "HUMBLE.", 177, [a, b]));
        Assert.Equal("explicit", ExplicitRules.Pick(Kendrick, "HUMBLE.", 177, [a, far]));
        Assert.Null(ExplicitRules.Pick(Kendrick, "Other", 177, [a]));
        Assert.Null(ExplicitRules.Pick(Kendrick, "HUMBLE.", 177, [new("Kendrick Lamar", "HUMBLE.", 177, null)]));
    }

    [Fact]
    public void MagicBytes()
    {
        byte[] png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0];
        byte[] jpeg = [0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0];
        byte[] webp = [(byte)'R', (byte)'I', (byte)'F', (byte)'F', 0, 0, 0, 0, (byte)'W', (byte)'E', (byte)'B', (byte)'P'];
        byte[] mp4 = [0, 0, 0, 0x18, (byte)'f', (byte)'t', (byte)'y', (byte)'p', (byte)'i', (byte)'s', (byte)'o', (byte)'m'];
        byte[] webm = [0x1A, 0x45, 0xDF, 0xA3, 0, 0, 0, 0, 0, 0, 0, 0];
        Assert.True(Sniff.Matches("image/png", png));
        Assert.False(Sniff.Matches("image/jpeg", png));
        Assert.True(Sniff.Matches("image/jpeg", jpeg));
        Assert.True(Sniff.Matches("image/webp", webp));
        Assert.True(Sniff.Matches("video/mp4", mp4));
        Assert.False(Sniff.Matches("video/mp4", png));
        Assert.True(Sniff.Matches("video/webm", webm));
        Assert.False(Sniff.Matches("video/webm", mp4));
        Assert.False(Sniff.Matches("image/gif", png));
        Assert.False(Sniff.Matches("video/mp4", new byte[3]));
        Assert.Equal("image/png", Sniff.BaseType("Image/PNG; charset=x"));
    }
}
