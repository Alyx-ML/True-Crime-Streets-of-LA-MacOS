# True Crime: Streets of LA for Apple silicon — preview

Requires an Apple silicon Mac running macOS 27 or later and your own copy of
the English PC version of True Crime: Streets of LA. This is an unofficial port
with a native Metal renderer. Game compatibility is still incomplete.

## Install

1. Download `True-Crime-Mac-ARM64.zip` from the [latest release](../../releases)
   and unzip it.
2. Copy your installed game into **Put game files here**. `TrueCrime.exe` and the
   `DATA` folder must sit directly inside that folder.
3. Open **True Crime.app**.
4. First launch only: a window says **Preparing True Crime for this Mac** for
   about 1–2 minutes.
5. The game starts. From then on it opens straight away.

```
True Crime Mac/
  True Crime.app
  Put game files here/
    TrueCrime.exe
    DATA/
    Movies/
    ...
```

No Terminal, scripts, Xcode or Homebrew are needed.

## Why the first launch takes a minute

The download contains no game files and none of the game's code. True Crime is
not a reimplementation: the app runs the game's own program, converted from
Windows x86 to Apple silicon. That conversion happens on your Mac, from your
copy of `TrueCrime.exe`, the first time you open the app. The result is kept in
`~/Library/Application Support/TrueCrimeNative/GameCode/` (about 25 MB) and is
redone automatically only after you install a new version of the app.

## Your game copy

- Use the installed game folder from your disc or digital copy, not a setup
  EXE or installer archive. Copy it from a Windows PC or a Wine/CrossOver
  installation if needed.
- Only the English PC `TrueCrime.exe` is supported: 2,932,736 bytes, SHA-256
  `2b965435039c425b4bb0f4ab9079d8ce8a87c8022e40a5038301cfac2db59efc`.
  Unmodified originals only; no-CD or patched executables are refused.
- `TrueCrime.exe` is read, never run or changed. Saves are written to the
  `Saves` folder inside your game folder.
- If the files are not found, the app opens a folder picker. Hold **Option**
  while opening the app to choose a different installation.

## Features

- Native Metal renderer with 2x MSAA and alpha-to-coverage, forced 16x
  anisotropic filtering, MetalFX spatial upscaling and HDR (EDR) output.
- Modern display resolutions, frame-rate limit and V-Sync, all in the in-game
  Display menu.
- Game controller support with remappable bindings, stick settings, deadzone,
  look sensitivity and inversion options, in the in-game Controls menu.
- Bink movies and music through a minimal LGPL FFmpeg build.

Settings live in `~/Library/Application Support/TrueCrimeNative/`.

## Gatekeeper

This preview has an ad-hoc signature, not a Developer ID signature or Apple
notarization. The first time you open it, macOS may block it. Open
**System Settings → Privacy & Security** and choose **Open Anyway**.

## Building from source

See [native/BUILDING.md](native/BUILDING.md). Building the app does not need the
game; the repository contains only the port's source.

## Credits and licences

Static recompilation uses [SR / SRW / LLasm](https://github.com/M-HT/SR) by
Roman Pauer (M-HT), MIT, with the changes in `native/srw-macos.patch`. The app
bundles LLVM and LLD, CPython, SDL 3 and FFmpeg; their notices are inside the app
at `Contents/Resources/Licenses`. The unmodified FFmpeg source is attached to
each release.

True Crime: Streets of LA is a trademark of its owners. This project is not
affiliated with or endorsed by them and does not include any of the game.
