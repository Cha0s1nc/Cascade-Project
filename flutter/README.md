# Cascade (Flutter prototype)

A prototype of the redesigned Home for Windows, Linux and Android, built from the Figma draft (https://www.figma.com/design/5jCQuhu85omAoJsBRC57rs). It runs on mock data: nothing talks to Jellyfin, and the player keeps time without making sound.

One codebase. A window 900px or wider gets the desktop layout (top bar, sidebar, Home, player bar); narrower gets the Android layout (search bar, Home, mini player, navigation bar).

```
flutter run -d windows   # on Windows, needs Visual Studio's C++ workload
flutter build apk        # Android
flutter test
```

The Swift app in `../apple` stays the Apple client.
