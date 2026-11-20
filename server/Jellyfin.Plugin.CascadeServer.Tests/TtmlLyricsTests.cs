using System.Text.Json;
using Jellyfin.Plugin.CascadeServer.LyricFormat;
using Xunit;

namespace Jellyfin.Plugin.CascadeServer.Tests;

public class TtmlLyricsTests
{
    // Made by the lyrics editor's own TTML writer (its amllToTtml, run on 2026-11-19): a
    // line with a word in two syllables and a background vocal, then the duet's other side.
    private const string Exported = """<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:tts="http://www.w3.org/ns/ttml#styling" xmlns:amll="http://www.example.com/ns/amll"><head><metadata><ttm:agent type="person" xml:id="v1"/><ttm:agent type="person" xml:id="v2"/></metadata></head><body dur="4.500"><div begin="1.000" end="4.500"><p begin="1.000" end="2.400" itunes:key="L1" ttm:agent="v1"><span begin="1.000" end="1.300">Hel</span><span begin="1.300" end="1.600">lo</span> <span begin="1.600" end="2.400">world</span><span ttm:role="x-bg" begin="1.800" end="2.600"><span begin="1.800" end="2.600">(ooh)</span></span></p><p begin="3.000" end="4.500" itunes:key="L2" ttm:agent="v2"><span begin="3.000" end="3.400">Say</span> <span begin="3.400" end="3.700">it</span> <span begin="3.700" end="4.500">back</span></p></div></body></tt>""";

    [Fact]
    public void TellsTtmlFromLrcByItsFirstCharacter()
    {
        Assert.True(TtmlLyrics.IsTtml(Exported));
        Assert.True(TtmlLyrics.IsTtml("﻿\n  <tt/>"));
        Assert.False(TtmlLyrics.IsTtml("[00:01.00]<00:01.00>Hello"));
        Assert.False(TtmlLyrics.IsTtml(""));
        Assert.False(TtmlLyrics.IsTtml(null));
    }

    [Fact]
    public void ReadsWordsBackgroundVocalsAndTheDuetSide()
    {
        var lines = TtmlLyrics.Parse(Exported)!;
        Assert.Equal(2, lines.Count);
        var first = lines[0];
        Assert.Equal(["Hel", "lo", "world"], first.Lead.Select(s => s.Text));
        Assert.True(first.Lead[0].IsPartOfWord, "Hel joins lo");
        Assert.False(first.Lead[1].IsPartOfWord, "a space ends Hello");
        Assert.False(first.Lead[2].IsPartOfWord, "the line's last word ends");
        Assert.Equal(1.0, first.Lead[0].Start);
        Assert.Equal(2.4, first.Lead[2].End);
        Assert.Equal("(ooh)", Assert.Single(first.Background).Text);
        Assert.False(first.Opposite);
        Assert.True(lines[1].Opposite, "v2 is the other side");
        Assert.Null(TtmlLyrics.Parse("<tt><body/></tt>"));
        Assert.Null(TtmlLyrics.Parse("<tt><p>"));
        Assert.Null(TtmlLyrics.Parse("<!DOCTYPE x [<!ENTITY a \"b\">]><tt/>"));
    }

    [Fact]
    public void ReadsEveryTimeForm()
    {
        Assert.Equal(1.5, TtmlLyrics.Time("1.500"));
        Assert.Equal(61.25, TtmlLyrics.Time("01:01.250"));
        Assert.Equal(3661.0, TtmlLyrics.Time("1:01:01"));
        Assert.Equal(2.5, TtmlLyrics.Time("2.5s"));
        Assert.Equal(1.5, TtmlLyrics.Time("1500ms"));
        Assert.Null(TtmlLyrics.Time("soon"));
        Assert.Null(TtmlLyrics.Time(null));
    }

    [Fact]
    public void GivesTheSyllableShapeTheAppsDraw()
    {
        using var doc = JsonDocument.Parse(TtmlLyrics.ToSyllableJson(TtmlLyrics.Parse(Exported)!));
        var body = doc.RootElement;
        Assert.Equal("Syllable", body.GetProperty("Type").GetString());
        Assert.Equal(4.5, body.GetProperty("EndTime").GetDouble());
        var first = body.GetProperty("Content")[0];
        Assert.False(first.GetProperty("OppositeAligned").GetBoolean());
        var syl = first.GetProperty("Lead").GetProperty("Syllables");
        Assert.Equal("Hel", syl[0].GetProperty("Text").GetString());
        Assert.True(syl[0].GetProperty("IsPartOfWord").GetBoolean());
        Assert.Equal(1.0, syl[0].GetProperty("StartTime").GetDouble());
        Assert.Equal("(ooh)", first.GetProperty("Background")[0].GetProperty("Syllables")[0].GetProperty("Text").GetString());
        Assert.True(body.GetProperty("Content")[1].GetProperty("OppositeAligned").GetBoolean());
    }

    [Fact]
    public void GivesWordLevelLrcWithoutBackgroundVocals()
    {
        var lrc = TtmlLyrics.ToEnhancedLrc(TtmlLyrics.Parse(Exported)!);
        Assert.Equal("[00:01.00]<00:01.00>Hel<00:01.30>lo <00:01.60>world <00:02.40>\n[00:03.00]<00:03.00>Say <00:03.40>it <00:03.70>back <00:04.50>", lrc);
    }

    // Made by the editor from line-level LRC: line timing, the text right in each <p>.
    private const string LineTimed = """<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Line"><body dur="22.070"><div begin="16.580" end="22.070"><p begin="16.580" end="19.470" itunes:key="L1" ttm:agent="v1">Yeah, ah</p><p begin="19.470" end="22.070" itunes:key="L2" ttm:agent="v1">Tell me what you really like</p></div></body></tt>""";

    [Fact]
    public void ReadsLineTimedTtmlAsLines()
    {
        var lines = TtmlLyrics.Parse(LineTimed)!;
        Assert.Equal(2, lines.Count);
        Assert.True(lines[0].LineTimed);
        Assert.Equal("Tell me what you really like", lines[1].Lead[0].Text);
        Assert.Equal("[00:16.58]Yeah, ah\n[00:19.47]Tell me what you really like", TtmlLyrics.ToEnhancedLrc(lines));
        using var doc = JsonDocument.Parse(TtmlLyrics.ToSyllableJson(lines));
        Assert.Equal("Line", doc.RootElement.GetProperty("Type").GetString());
        Assert.Equal(19.47, doc.RootElement.GetProperty("Content")[1].GetProperty("StartTime").GetDouble());
        Assert.Equal("Yeah, ah", doc.RootElement.GetProperty("Content")[0].GetProperty("Text").GetString());
    }
}
