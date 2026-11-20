using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Xml;
using System.Xml.Linq;

namespace Jellyfin.Plugin.CascadeServer.LyricFormat;

/// <summary>
/// TTML lyrics, as the lyrics editor (AMLL TTML Tool) saves them, kept in an .slrc next to
/// word-level Enhanced LRC. The two are told apart by their first character: '&lt;' for
/// TTML, '[' for LRC. No header line, since one in front would stop the TTML from being
/// valid XML for other TTML tools. Only the plugin reads .slrc, so only the plugin knows
/// TTML: it hands apps that ask (<c>ttml=true</c>) the syllable shape they already draw
/// for SpicyLyrics, and everyone else word-level Enhanced LRC, which loses background
/// vocals and duet sides. Pure, no Jellyfin types, so the unit tests compile it.
/// </summary>
public static class TtmlLyrics
{
    private static readonly XNamespace TtmMeta = "http://www.w3.org/ns/ttml#metadata";

    /// <summary>One sung syllable: its text, when, and whether the next joins it into one word.</summary>
    public sealed record Syllable(string Text, double Start, double End, bool IsPartOfWord);

    /// <summary>A line: its lead syllables, any background vocal syllables, and whether it is the duet's other side.</summary>
    public sealed record Line(IReadOnlyList<Syllable> Lead, IReadOnlyList<Syllable> Background, bool Opposite)
    {
        /// <summary>Gets when the line starts: its first syllable, lead or background.</summary>
        public double Start => Math.Min(Lead.Count > 0 ? Lead[0].Start : double.MaxValue, Background.Count > 0 ? Background[0].Start : double.MaxValue);

        /// <summary>Gets when the line ends.</summary>
        public double End => Math.Max(Lead.Count > 0 ? Lead[^1].End : 0, Background.Count > 0 ? Background[^1].End : 0);
    }

    /// <summary>Whether <paramref name="text"/> is TTML: its first character, after a byte order mark and whitespace, is '&lt;'.</summary>
    public static bool IsTtml(string? text)
    {
        if (text is null) return false;
        foreach (var c in text)
        {
            if (c == '﻿' || char.IsWhiteSpace(c)) continue;
            return c == '<';
        }

        return false;
    }

    /// <summary>The lines of a TTML document, in order; null when it is not readable TTML or has no timed words.</summary>
    public static List<Line>? Parse(string ttml)
    {
        XDocument doc;
        try
        {
            // No DTDs: a lyrics file has no business declaring entities.
            using var reader = XmlReader.Create(new System.IO.StringReader(ttml), new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null });
            doc = XDocument.Load(reader, LoadOptions.PreserveWhitespace);
        }
        catch (XmlException)
        {
            return null;
        }

        var lines = new List<Line>();
        foreach (var p in doc.Descendants().Where(e => e.Name.LocalName == "p"))
        {
            var lead = new List<Syllable>();
            var background = new List<Syllable>();
            Collect(p, lead, background, inBackground: false);
            if (lead.Count == 0 && background.Count == 0) continue;
            var agent = (string?)p.Attribute(TtmMeta + "agent");
            lines.Add(new Line(lead, background, IsOtherSide(agent)));
        }

        return lines.Count == 0 ? null : lines;
    }

    // Apple's duets: v1 sings on the left, v2 (or any later singer) on the other side,
    // v1000 is everyone together.
    private static bool IsOtherSide(string? agent) => agent is not null && agent != "v1" && agent != "v1000";

    private static void Collect(XElement parent, List<Syllable> lead, List<Syllable> background, bool inBackground)
    {
        foreach (var node in parent.Nodes())
        {
            if (node is XText text)
            {
                // Space between two spans ends the word before it.
                if (string.IsNullOrWhiteSpace(text.Value)) MarkWordEnd(inBackground ? background : lead);
                continue;
            }

            if (node is not XElement span || span.Name.LocalName != "span") continue;
            var role = (string?)span.Attribute(TtmMeta + "role");
            if (role == "x-bg")
            {
                Collect(span, lead, background, inBackground: true);
                continue;
            }

            // Translations and romanizations ride along in the same line; not sung.
            if (role is not null) continue;
            if (span.Elements().Any(e => e.Name.LocalName == "span"))
            {
                Collect(span, lead, background, inBackground);
                continue;
            }

            var start = Time((string?)span.Attribute("begin"));
            var end = Time((string?)span.Attribute("end"));
            var value = span.Value;
            if (start is null || string.IsNullOrEmpty(value)) continue;
            var list = inBackground ? background : lead;
            var trimmed = value.TrimEnd();
            list.Add(new Syllable(trimmed.TrimStart(), start.Value, end ?? start.Value, IsPartOfWord: trimmed.Length == value.Length));
            if (trimmed.Length != value.Length) MarkWordEnd(list);
        }

        MarkWordEnd(inBackground ? background : lead);
    }

    private static void MarkWordEnd(List<Syllable> list)
    {
        if (list.Count > 0 && list[^1].IsPartOfWord) list[^1] = list[^1] with { IsPartOfWord = false };
    }

    /// <summary>A TTML time in seconds: clock time (hh:mm:ss.fff, mm:ss.fff, ss.fff) or an offset (1.5s, 1500ms).</summary>
    public static double? Time(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)) return null;
        var v = value.Trim();
        var inv = CultureInfo.InvariantCulture;
        if (v.EndsWith("ms", StringComparison.Ordinal))
            return double.TryParse(v[..^2], NumberStyles.Float, inv, out var ms) ? ms / 1000 : null;
        if (v.EndsWith('s'))
            return double.TryParse(v[..^1], NumberStyles.Float, inv, out var s) ? s : null;
        double total = 0;
        foreach (var part in v.Split(':'))
        {
            if (!double.TryParse(part, NumberStyles.Float, inv, out var n) || n < 0) return null;
            total = (total * 60) + n;
        }

        return total;
    }

    /// <summary>
    /// The lines in SpicyLyrics' syllable shape (seconds, the Body of their answer), which
    /// every Cascade app already draws: lead and background syllables and the duet side.
    /// </summary>
    public static string ToSyllableJson(IReadOnlyList<Line> lines)
    {
        object Group(IReadOnlyList<Syllable> s) => new
        {
            StartTime = s[0].Start,
            EndTime = s[^1].End,
            Syllables = s.Select(x => new { x.Text, StartTime = x.Start, EndTime = x.End, x.IsPartOfWord }),
        };

        var body = new
        {
            Type = "Syllable",
            StartTime = lines.Count > 0 ? lines[0].Start : 0,
            EndTime = lines.Count > 0 ? lines.Max(l => l.End) : 0,
            Content = lines.Select(l => new
            {
                Type = "Vocal",
                OppositeAligned = l.Opposite,
                Lead = l.Lead.Count > 0 ? Group(l.Lead) : Group(l.Background),
                Background = l.Lead.Count > 0 && l.Background.Count > 0 ? new[] { Group(l.Background) } : [],
            }),
        };
        return JsonSerializer.Serialize(body);
    }

    /// <summary>
    /// The lead vocals as word-level Enhanced LRC (<c>[mm:ss.xx]&lt;mm:ss.xx&gt;word...</c>), as
    /// the plugin's other .slrc files are, for apps that do not ask for TTML. Background
    /// vocals and the duet side do not fit and are left out.
    /// </summary>
    public static string ToEnhancedLrc(IReadOnlyList<Line> lines)
    {
        var sb = new StringBuilder();
        foreach (var line in lines)
        {
            if (line.Lead.Count == 0) continue;
            sb.Append('[').Append(Clock(line.Lead[0].Start)).Append(']');
            foreach (var s in line.Lead)
            {
                sb.Append('<').Append(Clock(s.Start)).Append('>').Append(s.Text);
                if (!s.IsPartOfWord) sb.Append(' ');
            }

            // The last word's end, so it does not run on to the next line.
            sb.Append('<').Append(Clock(line.Lead[^1].End)).Append(">\n");
        }

        return sb.ToString().TrimEnd('\n');
    }

    private static string Clock(double seconds)
    {
        var cs = (long)Math.Round(Math.Max(0, seconds) * 100);
        return $"{cs / 6000:D2}:{cs / 100 % 60:D2}.{cs % 100:D2}";
    }
}
