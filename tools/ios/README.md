# LAS Recomp on iPhone / iPad

An iOS build of LAS Recomp: the same recompiled game and runtime, drawn with Metal, with an on-screen controller and
phone settings. Like the desktop versions it contains nothing from the game: the app you install is built from **your
own** extracted game files (v1.0.0, v1.0.1 or v1.1.0), and you copy the game's data onto the phone yourself.

## What you need

- Your extracted game: the `exefs` and `romfs` folders (not `.nsp` / `.xci` packages). How to get them isn't covered.
- An iPhone or iPad with **6 GB of memory or more** (iPhone 13 Pro / 14 / 15 / 16 and later, M-series iPads), iOS 17+.
- About 7 GB free on it.
- A way to sideload with your Apple ID that keeps the app's entitlements: SideStore or AltStore.
- On a PC: the GitHub CLI (`gh`), signed in.

## Build the IPA (Windows, one command)

```
powershell -ExecutionPolicy Bypass -File tools\ios\build_ipa.ps1 -GameFiles "D:\path\to\your\extracted\game"
```

It uploads only your `exefs` (the game's code, ~40 MB) to a **private** repository of yours, runs the iOS build on
GitHub's Macs (`.github/workflows/ios.yml` in this public repository), and downloads the IPA to `build\ios`. The IPA
holds game code built from your files: it goes only to your private repository, never to the public one - keep it to
yourself.

On a Mac with Xcode, by hand: `make deps-ios`, put your files in `extracted/`, `make gen PLATFORM=ios`, `make ipa`.

## Install

**With the game files inside the IPA** (one ~6 GB file, nothing to copy afterwards - e.g. sent to the phone and
installed in LiveContainer):

```
powershell -ExecutionPolicy Bypass -File tools\ios\add_game_files.ps1 -Ipa build\ios\LASRecomp-<version>-ios.ipa -GameFiles "D:\path\to\your\extracted\game"
```

It runs on your PC only and writes `...-with-game.ipa` next to the IPA. It holds your whole game: keep it to yourself.
The app uses these files when its own folder has none (files copied in later win).

**LiveContainer**: apps inside it run with LiveContainer's own signature, so the game's entitlements (extended virtual
addressing, increased memory limit) must be in how LiveContainer itself was signed; without them LAS Recomp says at
start that it couldn't reserve its memory. Its folder is in LiveContainer's: Files > On My iPhone > LiveContainer >
Data > Application > (LAS Recomp's) > Documents.

**Or copy them in after installing:**

1. Install the IPA with SideStore, AltStore or LiveContainer.
2. Open LAS Recomp once (it creates its folder), then copy your `exefs` and `romfs` folders into
   **Files > On My iPhone > LAS Recomp > extracted** (or from a computer: Finder / the Apple Devices app > your iPhone >
   Files > LAS Recomp). The romfs is about 6 GB.
3. On the start screen tap **Check game files**, then **Play**.

## Playing

- **Touch controls**: an Xbox-style controller over the game - stick and d-pad on the left, A/B/X/Y on the right
  (Xbox A, the bottom button, is the Switch's B: buttons go by position, as with a real controller), LB/LT and RB/RT
  at the top, View (Minus) and Menu (Plus) in the middle. Slide between the face buttons; hold the d-pad to repeat.
- **The gear** (top, next to Menu) opens LAS Recomp's menu on the **Phone** tab. Tap a row to change it, drag to
  scroll, the X (top right) closes it.
- **A controller** (Xbox, PlayStation, Switch Pro, MFi): connect it and the touch controls hide by themselves; Minus +
  Plus opens the menu as on the desktop.

### Phone tab

| Setting | Values |
| --- | --- |
| Resolution | Native (the screen's own), 2106x1084, 1920x1080, 1600x900, 1280x720 |
| Aspect Ratio | iPhone Default, 1.943:1, 16:9, 4:3 |
| Screen Scaling | Fit (black bars), Stretch |
| Frame Rate | 30 FPS, 60 FPS, 120 FPS (ProMotion) |
| Show FPS | Off / On |
| UI Size | Small, Default, Large |
| Touch Controls | Off / On |
| Touch Opacity | 20% - 100% |
| Touch Size | 70% - 150% |
| Left Stick | Fixed, Floating |
| Vibration | Off / On (taps on the touch controls, and the game's rumble on the phone without a controller) |

Below them: the upscaler (MetalFX), anti-aliasing, blur removal and the Hero Mode icon, as in the desktop Video tab.

## What's different from the desktop versions

- The game code is built into the app when the IPA is built, not on the device: a new game version needs a new IPA.
- The randomizer's seed generator doesn't run on iOS. Seeds made with the desktop version can be copied into
  **LAS Recomp > rando** and played.
- The game's memory sits at a different place in the address space (`runtime/rt.h`, `GUEST_ORIGIN`): the iPhone's
  address space ends far below where the desktop versions put it. The app needs the *extended virtual addressing* and
  *increased memory limit* entitlements for it (`tools/ios/entitlements.plist`); without them it says so at start.
- iPhone GPUs can't sample BC textures: they're decoded when loaded (`runtime/nvn/bcdec.c`, checked against the
  GPU's own decoding on every build).
- Logs: **LAS Recomp > lasrecomp.log** in the Files app (attach it to bug reports).
