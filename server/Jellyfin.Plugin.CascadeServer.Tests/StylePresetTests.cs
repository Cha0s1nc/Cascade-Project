using System.Text.Json.Nodes;
using Jellyfin.Plugin.CascadeServer.Style;
using Xunit;

namespace Jellyfin.Plugin.CascadeServer.Tests;

public class StylePresetTests
{
    private const string Good = """{"format":"cascade-preset","version":1,"name":"Sunset","theme":{"gradStart":"#f97316"},"extra":1}""";

    [Fact]
    public void KeepsOnlyKnownKeys()
    {
        Assert.True(StylePreset.TryNormalize(Good, out var json, out _));
        var o = JsonNode.Parse(json)!.AsObject();
        Assert.False(o.ContainsKey("extra"));
        Assert.Equal("Sunset", (string?)o["name"]);
    }

    [Theory]
    [InlineData("")]
    [InlineData("not json")]
    [InlineData("[1]")]
    [InlineData("""{"format":"other","version":1,"theme":{}}""")]
    [InlineData("""{"format":"cascade-preset","version":2,"theme":{}}""")]
    [InlineData("""{"format":"cascade-preset","version":"1","theme":{}}""")]
    [InlineData("""{"format":"cascade-preset","version":1}""")]
    [InlineData("""{"format":"cascade-preset","version":1,"theme":"x","lyrics":[]}""")]
    public void RefusesBadPresets(string text) => Assert.False(StylePreset.TryNormalize(text, out _, out var error) || error == "");

    [Fact]
    public void RefusesOversize()
    {
        var big = """{"format":"cascade-preset","version":1,"theme":{},"name":"%"}""".Replace("%", new string('a', StylePreset.MaxBytes));
        Assert.False(StylePreset.TryNormalize(big, out _, out _));
    }

    [Fact]
    public void LyricsAloneIsEnough() =>
        Assert.True(StylePreset.TryNormalize("""{"format":"cascade-preset","version":1,"lyrics":{"lyricScale":1}}""", out _, out _));
}
