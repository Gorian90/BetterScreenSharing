<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/logo-dark.svg">
    <img src="docs/logo-light.svg" width="580" alt="BetterScreenSharing">
  </picture>
</p>

Switch what you share in Teams, Zoom, Meet or Slack with a keystroke – without stopping and restarting the share.

https://github.com/user-attachments/assets/9c7519e4-4283-4a5b-9bf3-e2c5802b9898

## Download

- [BetterScreenSharing for macOS](https://github.com/Gorian90/BetterScreenSharing/releases/download/v1.0/BetterScreenSharing.zip) – macOS 14 or later (Apple Silicon and Intel), version 1.0, released 2026-11-19

## How it works

The app creates a virtual display. You share it once in your meeting app, then choose what it shows: any window or screen, with your webcam on top, a spotlight, highlights or a countdown for breaks. Everything runs locally, with no drivers or plug-ins.

## Install

Unzip, move the app to Applications and open it. The app isn't notarized by Apple, so the first time macOS blocks it:

- **macOS 15 and later:** click **Done**, then **System Settings › Privacy & Security › Open Anyway**.
- **macOS 14:** right-click the app › **Open**.

A short guide then helps you grant screen recording access.

## Build from source

```bash
./build.sh
open build/BetterScreenSharing.app
```

Requires Xcode Command Line Tools.
