using System.Linq;
using System.Text;
using Jellyfin.Plugin.CascadeServer.AnimatedArt;
using Xunit;

namespace Jellyfin.Plugin.CascadeServer.Tests;

public class AnimatedImageTests
{
    private static byte[] B(params object[] parts) => parts.SelectMany(p => p switch
    {
        string s => Encoding.ASCII.GetBytes(s),
        byte[] b => b,
        int i => new[] { (byte)i },
        _ => [],
    }).ToArray();

    private static readonly byte[] Png = [0x89, (byte)'P', (byte)'N', (byte)'G', 0x0D, 0x0A, 0x1A, 0x0A];

    [Fact]
    public void GifWithTheLoopExtensionIsAnimated()
    {
        Assert.True(AnimatedImage.IsAnimated(B("GIF89a", new byte[20], "!\xff\x0bNETSCAPE2.0")));
        Assert.False(AnimatedImage.IsAnimated(B("GIF89a", new byte[40])));
    }

    [Fact]
    public void WebPNeedsTheVp8xAnimationFlag()
    {
        Assert.True(AnimatedImage.IsAnimated(B("RIFF", new byte[4], "WEBP", "VP8X", new byte[4], 0x02, new byte[9])));
        Assert.False(AnimatedImage.IsAnimated(B("RIFF", new byte[4], "WEBP", "VP8X", new byte[4], 0x10, new byte[9])), "alpha only");
        Assert.False(AnimatedImage.IsAnimated(B("RIFF", new byte[4], "WEBP", "VP8 ", new byte[20])), "a plain still WebP");
    }

    [Fact]
    public void PngIsAnimatedOnlyWithActlBeforeItsImage()
    {
        Assert.True(AnimatedImage.IsAnimated(B(Png, "\0\0\0\rIHDR", new byte[17], "\0\0\0\u0008acTL", new byte[12], "IDAT")));
        Assert.False(AnimatedImage.IsAnimated(B(Png, "\0\0\0\rIHDR", new byte[17], "IDAT", new byte[8])));
        Assert.False(AnimatedImage.IsAnimated(B(Png, "IDAT", new byte[8], "acTL")), "acTL after the image is not APNG");
    }

    [Fact]
    public void AnythingElseIsNot() => Assert.False(AnimatedImage.IsAnimated(B("\xff\xd8\xff\xe0JFIF")));

    [Fact]
    public void ConcatListClampsTinyDurationsAndRepeatsTheLastFrame()
    {
        var list = AnimatedImage.ConcatList(["/f/0.png", "/f/it's.png"], [0, 40]);
        Assert.Equal("ffconcat version 1.0\nfile '/f/0.png'\nduration 0.1\nfile '/f/it'\\''s.png'\nduration 0.04\nfile '/f/it'\\''s.png'\n", list);
    }
}
