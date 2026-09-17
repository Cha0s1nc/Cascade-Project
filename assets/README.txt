Icons
=====

This folder holds the icon SOURCE and the GENERATED icons. Do not confuse them.

  Source (edit / replace this)
    source.svg    vector master, preferred
    source.png    1024x1024 raster master, used when there is no source.svg

  Generated (do not edit - `npm run icons` overwrites them)
    icon.png      Linux, 1024x1024
    icon.icns     macOS, built from an iconset
    icon.ico      Windows, 256x256

To regenerate after new artwork:

  npm run icons

It picks source.svg if present, otherwise source.png, and prints which one it
used. If both exist it uses the SVG and says so, so a stale vector cannot
silently win over new raster artwork. To force the other one, or to generate
from a file somewhere else entirely:

  npm run icons -- assets/source.png
  npm run icons -- ~/somewhere/artwork.png

A raster source must be at least 1024x1024. The script refuses anything smaller
rather than upscaling it, because the softness shows up exactly where people
look: the dock and the installer. SVG has no such limit.

The source is deliberately named source.* rather than icon.*, because icon.png,
icon.ico and icon.icns are outputs. A source sharing one of those names would be
overwritten by its own output partway through the run.

macOS note: icon.icns needs `iconutil`, so it is only produced when the script
runs on macOS. Everything else builds anywhere.

Licensing: the artwork here is NOT GPL. It is (C) 2026 cha0s and Hxney_bun_,
all rights reserved, under assets/LICENSE. Unmodified builds may be shared;
forks and modified versions must replace it. Anything new added to this folder
falls under the same terms, so get the artist's agreement first.
To ask for permission to use the artwork, email contact@chaosinc.xyz.
