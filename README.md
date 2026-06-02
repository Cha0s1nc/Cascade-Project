# Cascade

A Jellyfin music client for desktop, inspired by the Cider Collective's design language.

![Electron](https://img.shields.io/badge/Electron-29-blue) ![License](https://img.shields.io/badge/license-MIT-green)

## Features

- Browse albums, artists, songs, and playlists from your Jellyfin server
- Full playback with queue management — drag to reorder, click to remove
- Synced lyrics with click-to-seek and auto-translation for non-English tracks
- Full-screen now-playing overlay with queue and lyrics panel
- Right-click context menu on now-playing art (instant mix, add to playlist, media info, download, and more)
- Like/favourite tracks synced back to Jellyfin
- Expandable sidebar, dark theme, Cha0s Stream-inspired design

## Requirements

- [Node.js](https://nodejs.org) 18+
- A running [Jellyfin](https://jellyfin.org) server

## Getting started

```bash
git clone https://github.com/Cha0s1nc/Cascade-Project.git
cd Cascade-Project
npm install
npm start
```

On first launch, enter your Jellyfin server URL, username, and password. Cascade will authenticate and load your library.

## Settings

Open **Settings** (gear icon in the sidebar) to:
- Change server URL or credentials
- Select which Jellyfin music libraries to include (supports merging multiple)

## Built with

- [Electron](https://www.electronjs.org)
- [electron-store](https://github.com/sindresorhus/electron-store) for persistent settings
- Jellyfin REST API
- MyMemory API for lyrics translation
