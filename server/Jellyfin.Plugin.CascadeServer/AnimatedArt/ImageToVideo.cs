using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using Jellyfin.Plugin.CascadeServer.LyricStore;
using MediaBrowser.Common.Configuration;
using Microsoft.Extensions.Logging;
using SkiaSharp;

namespace Jellyfin.Plugin.CascadeServer.AnimatedArt;

/// <summary>
/// Turns an animated GIF, WebP or APNG sidecar into an MP4 once, with Jellyfin's own ffmpeg, and
/// keeps it in the data folder (animated-art/converted) beside a stamp of the source's path, size
/// and time. A changed source is converted again; one that fails is not retried until it changes.
/// One conversion runs at a time.
/// </summary>
public static class ImageToVideo
{
    private static readonly SemaphoreSlim Gate = new(1, 1);
    private static readonly ConcurrentDictionary<Guid, Task> Running = new();
    private static readonly TimeSpan Timeout = TimeSpan.FromMinutes(2);

    /// <summary>The converted MP4 for this source, when it is done and still matches the source.</summary>
    public static string? Ready(IApplicationPaths paths, Guid albumId, string source)
    {
        var mp4 = Path.Combine(Dir(paths), $"{albumId:N}.mp4");
        return File.Exists(mp4) && ReadStamp(Path.ChangeExtension(mp4, ".src")) == Stamp(source) ? mp4 : null;
    }

    /// <summary>Whether converting this exact source already failed.</summary>
    public static bool Failed(IApplicationPaths paths, Guid albumId, string source)
        => ReadStamp(Path.Combine(Dir(paths), $"{albumId:N}.fail")) == Stamp(source);

    /// <summary>Every file kept for the album, for removing them.</summary>
    public static string[] Files(IApplicationPaths paths, Guid albumId)
        => [.. new[] { ".mp4", ".src", ".fail" }.Select(ext => Path.Combine(Dir(paths), $"{albumId:N}{ext}"))];

    /// <summary>Starts converting, unless a conversion for the album is already running.</summary>
    public static void Start(IApplicationPaths paths, string ffmpeg, ILogger logger, Guid albumId, string source)
    {
        if (Running.TryGetValue(albumId, out var running) && !running.IsCompleted) return;
        Running[albumId] = Task.Run(async () =>
        {
            await Gate.WaitAsync();
            var dir = Dir(paths);
            var temp = Path.Combine(dir, $"{albumId:N}.tmp.mp4");
            var frames = Path.Combine(dir, $"{albumId:N}.frames");
            try
            {
                var stamp = Stamp(source);
                var input = AnimatedImage.IsWebP(source) ? DecodeWebP(source, frames) : source;
                await RunFfmpegAsync(ffmpeg, input, temp, concat: input != source);
                File.Move(temp, Path.Combine(dir, $"{albumId:N}.mp4"), overwrite: true);
                File.WriteAllText(Path.Combine(dir, $"{albumId:N}.src"), stamp);
                File.Delete(Path.Combine(dir, $"{albumId:N}.fail"));
            }
            catch (Exception ex)
            {
                // Anything at all, Skia failing to load included: remember it and leave the still cover.
                logger.LogInformation("Turning {File} into a video cover failed: {Message}", Path.GetFileName(source), ex.Message);
                try { File.WriteAllText(Path.Combine(dir, $"{albumId:N}.fail"), Stamp(source)); }
                catch (IOException) { /* Tried again next time. */ }
            }
            finally
            {
                try
                {
                    File.Delete(temp);
                    if (Directory.Exists(frames)) Directory.Delete(frames, recursive: true);
                }
                catch (IOException) { /* Overwritten next time. */ }

                Gate.Release();
                Running.TryRemove(albumId, out _);
            }
        });
    }

    /// <summary>
    /// Decodes an animated WebP's frames to PNGs with SkiaSharp (Jellyfin ships it) and returns the
    /// concat list ffmpeg reads them from. Each frame is drawn over the one before, since WebP frames
    /// are often partial updates.
    /// </summary>
    private static string DecodeWebP(string source, string framesDir)
    {
        Directory.CreateDirectory(framesDir);
        using var codec = SKCodec.Create(source) ?? throw new InvalidDataException("Skia could not read the WebP.");
        var info = codec.Info.WithColorType(SKColorType.Rgba8888).WithAlphaType(SKAlphaType.Premul);
        var frameInfo = codec.FrameInfo;
        if (frameInfo.Length < 2) throw new InvalidDataException("The WebP has one frame.");

        using var bitmap = new SKBitmap(info);
        var files = new string[frameInfo.Length];
        var durations = new int[frameInfo.Length];
        for (var i = 0; i < frameInfo.Length; i++)
        {
            var options = new SKCodecOptions(i, i > 0 ? i - 1 : -1);
            var result = codec.GetPixels(info, bitmap.GetPixels(), options);
            if (result is not (SKCodecResult.Success or SKCodecResult.IncompleteInput)) throw new InvalidDataException($"Skia stopped at frame {i}: {result}.");
            files[i] = Path.Combine(framesDir, $"{i:D5}.png");
            using (var stream = File.Create(files[i])) bitmap.Encode(stream, SKEncodedImageFormat.Png, 100);
            durations[i] = frameInfo[i].Duration;
        }

        var list = Path.Combine(framesDir, "frames.txt");
        File.WriteAllText(list, AnimatedImage.ConcatList(files, durations));
        return list;
    }

    private static async Task RunFfmpegAsync(string ffmpeg, string input, string output, bool concat)
    {
        var psi = new ProcessStartInfo(ffmpeg) { RedirectStandardError = true, UseShellExecute = false };
        foreach (var a in new[] { "-hide_banner", "-loglevel", "error", "-y" }) psi.ArgumentList.Add(a);
        if (concat) foreach (var a in new[] { "-f", "concat", "-safe", "0" }) psi.ArgumentList.Add(a);
        // Square-ish covers up to 1080 wide, even sizes for H.264, no sound, at most a minute.
        foreach (var a in new[]
                 {
                     "-i", input, "-an", "-t", "60", "-vf", "scale=trunc(min(iw\\,1080)/2)*2:-2,format=yuv420p",
                     "-c:v", "libx264", "-preset", "veryfast", "-crf", "22", "-movflags", "+faststart", "-f", "mp4", output,
                 })
        {
            psi.ArgumentList.Add(a);
        }

        using var process = Process.Start(psi) ?? throw new IOException("ffmpeg did not start.");
        var stderr = process.StandardError.ReadToEndAsync();
        using var cts = new CancellationTokenSource(Timeout);
        try
        {
            await process.WaitForExitAsync(cts.Token);
        }
        catch (OperationCanceledException)
        {
            process.Kill(entireProcessTree: true);
            throw new TimeoutException("ffmpeg took longer than two minutes.");
        }

        if (process.ExitCode != 0) throw new IOException($"ffmpeg exited {process.ExitCode}: {(await stderr).Trim()}");
    }

    private static string Stamp(string source)
    {
        var f = new FileInfo(source);
        return f.Exists ? $"{source}|{f.Length}|{f.LastWriteTimeUtc.Ticks}" : string.Empty;
    }

    private static string? ReadStamp(string path)
    {
        try { return File.Exists(path) ? File.ReadAllText(path) : null; }
        catch (IOException) { return null; }
    }

    private static string Dir(IApplicationPaths paths)
    {
        var dir = Path.Combine(DataDir.Root(paths), "animated-art", "converted");
        Directory.CreateDirectory(dir);
        return dir;
    }
}
