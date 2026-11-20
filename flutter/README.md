# Cascade (Flutter prototype)

A prototype of the redesigned Home for Windows, Linux and Android, built from the Figma draft (https://www.figma.com/design/5jCQuhu85omAoJsBRC57rs). It runs on mock data: nothing talks to Jellyfin, and the player keeps time without making sound.

One codebase. A window 900px or wider gets the desktop layout (top bar, sidebar, Home, player bar); narrower gets the Android layout (search bar, Home, mini player, navigation bar).

```
flutter run -d windows   # on Windows, needs Visual Studio's C++ workload
flutter build apk        # Android
flutter test
```

The Swift app in `../apple` stays the Apple client.

## Building on Linux

Besides Flutter itself, `flutter build linux` needs (Debian and Ubuntu names; mintvm has them):

```bash
sudo apt-get install clang cmake ninja-build pkg-config libgtk-3-dev libmpv-dev libwebkit2gtk-4.1-dev libsoup-3.0-dev
```

WebKitGTK 4.1 is for the lyrics editor's window (`desktop_webview_window`). The app links against it, so it is needed to run the app too, not only to build it: Linux packages must require it (`webkit2gtk-4.1` on Arch, `libwebkit2gtk-4.1-0` on Debian and Ubuntu).
