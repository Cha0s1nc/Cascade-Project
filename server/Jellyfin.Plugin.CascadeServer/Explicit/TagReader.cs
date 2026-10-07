using System;
using System.IO;
using System.Linq;
using TagLib;

namespace Jellyfin.Plugin.CascadeServer.Explicit;

/// <summary>
/// Reads the advisory tag from the audio file itself. Jellyfin's scanner ignores it, so this
/// opens the file with TagLib# (the same TagLibSharp 2.3.0 Jellyfin ships) and reads, by format:
/// the <c>rtng</c> atom in MP4/M4A, the <c>TXXX:ITUNESADVISORY</c> frame in ID3v2, and the
/// <c>ITUNESADVISORY</c> or <c>EXPLICIT</c> comment in Vorbis, FLAC and Opus.
/// </summary>
public static class TagReader
{
    /// <summary>What the file says: a rating (or null) and an ISRC (or null).</summary>
    public record Result(string? Rating, string? Isrc);

    /// <summary>
    /// The album barcode (UPC or EAN) a tagger such as MusicBrainz Picard wrote: the <c>BARCODE</c> or
    /// <c>UPC</c> comment in Vorbis, FLAC and Opus, the <c>TXXX</c> frame of that name in ID3v2, and
    /// the <c>com.apple.iTunes</c> freeform atom of that name in MP4. Null when there is none.
    /// </summary>
    public static string? ReadBarcode(string path)
    {
        try
        {
            using var file = TagLib.File.Create(path, ReadStyle.None);
            foreach (var name in new[] { "BARCODE", "UPC" })
            {
                string? v = null;
                if (file.GetTag(TagTypes.Xiph, false) is TagLib.Ogg.XiphComment xiph) v = xiph.GetField(name).FirstOrDefault();
                if (v is null && file.GetTag(TagTypes.Id3v2, false) is TagLib.Id3v2.Tag id3)
                {
                    v = TagLib.Id3v2.UserTextInformationFrame.Get(id3, name, false)?.Text.FirstOrDefault();
                }

                if (v is null && file.GetTag(TagTypes.Apple, false) is TagLib.Mpeg4.AppleTag apple) v = apple.GetDashBox("com.apple.iTunes", name);
                if (!string.IsNullOrWhiteSpace(v)) return v.Trim();
            }

            return null;
        }
        catch (Exception ex) when (ex is CorruptFileException or UnsupportedFormatException or IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    /// <summary>Reads the file. Any file TagLib# cannot open is just "unknown"; it never throws for a bad file.</summary>
    public static Result Read(string path)
    {
        try
        {
            using var file = TagLib.File.Create(path, ReadStyle.None);

            string? raw = null;
            if (file.GetTag(TagTypes.Apple, false) is TagLib.Mpeg4.AppleTag apple)
            {
                var box = apple.DataBoxes(new ReadOnlyByteVector("rtng")).FirstOrDefault();
                if (box is not null && box.Data.Count > 0) raw = box.Data[0].ToString();
            }

            if (raw is null && file.GetTag(TagTypes.Id3v2, false) is TagLib.Id3v2.Tag id3)
            {
                raw = TagLib.Id3v2.UserTextInformationFrame.Get(id3, "ITUNESADVISORY", false)?.Text.FirstOrDefault();
            }

            if (file.GetTag(TagTypes.Xiph, false) is TagLib.Ogg.XiphComment xiph)
            {
                raw ??= xiph.GetField("ITUNESADVISORY").FirstOrDefault();
                raw ??= xiph.GetField("EXPLICIT").FirstOrDefault();
            }

            var isrc = file.Tag?.ISRC;
            return new Result(ExplicitRules.ParseTag(raw), string.IsNullOrWhiteSpace(isrc) ? null : isrc.Trim());
        }
        catch (Exception ex) when (ex is CorruptFileException or UnsupportedFormatException or IOException or UnauthorizedAccessException)
        {
            return new Result(null, null);
        }
    }
}
