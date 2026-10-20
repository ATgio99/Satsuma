# Satsuma

A macOS menu bar app that converts files by dragging them onto a wheel of formats. It is a reimplementation of an existing drag-and-drop converter. The Swift code is written from scratch. It contains no assets, scripts, JavaScript or Java taken from the original app's bundle, and no RevenueCat or paywall.

## Usage
1. Start drag-and-dropping one or more files (Finder, desktop, any app).
2. While dragging, tap a modifier:
   - **⇧** opens the conversion wheel;
   - **⌘** the tools wheel;
   - **⌃** the file actions wheel.
3. Drop on a petal. The result is saved next to the original (never overwritten: `name 2.ext`).

The modifiers are configured in Settings (menu bar icon → Settings…). If the original app is open too, both wheels appear: quit one of the two or change the shortcuts.

## Build
```bash
./scripts/build_app.sh          # → build/Satsuma.app (ad-hoc signed)
./scripts/make_dmg.sh           # → build/Satsuma-1.0.dmg (drag Satsuma onto Applications)
swift test --scratch-path ~/Library/Caches/Satsuma-build
```
The DMG window (760×440, 128 pt icons, Satsuma's own background with an arrow drawn by `scripts/dmg_background.swift`) is written by [dmgbuild](https://pypi.org/project/dmgbuild/) 1.6.7, which `make_dmg.sh` installs once in a venv in `~/Library/Caches/Satsuma-build`: no Finder scripting or Automation permission needed.

The app is Apple silicon only (arm64) and signed ad hoc, not notarized. On the Mac that built it the DMG opens normally. On another Mac, a downloaded copy is blocked the first time: right-click Satsuma → Open, or System Settings → Privacy & Security → Open Anyway.
The build runs in `~/Library/Caches/Satsuma-build` because the iCloud-synced Desktop adds extended attributes that `codesign` rejects.

Debug modes:
- `Satsuma --convert <file> <format>`
- `Satsuma --tool <tool> <file>…`
- `Satsuma --render-wheel out.png <conversions|fileTools|fileActions> <file>… [--highlight N] [--metallic]`
- `Satsuma --test-welcome` clicks Continue/Back/Close in the Welcome window with synthetic events and prints what happened.
- `Satsuma --test-progress` clicks ✕ on a "Couldn’t finish" progress panel and checks that it closes.
- `Satsuma --render-ui <welcome N | settings <tab> | float [--expanded] [--list] <file>… | progress [done|errors]> out.png [--dark]`. Offscreen snapshots can't draw Liquid Glass, so these use the pre-macOS 26 materials.

## Different from the original
- **Engines**: the original app bundles ffmpeg, cwebp, a Java runtime with Apache POI, ExifTool and a JavaScript Pages writer. Satsuma uses ffmpeg/cwebp installed on the Mac (Homebrew), ImageIO/PDFKit/Vision, and **Pages, Keynote and Numbers via AppleScript** for `.pages`, `.ppt/.pptx` and `.xls/.ods`. Without those apps the matching petals don't appear.
- **OGG** is encoded with Opus (the installed ffmpeg has no libvorbis).
- **iWork import**: when Pages, Numbers or Keynote open a foreign file (.docx, .xls, .ppt…), `open` returns an import handle ("export id …") instead of a document, and `save`/`export` on it fail with -1708. Satsuma waits for the new document to appear and works on that.
- **Sound**: the original plays its bundled `HighlightSound.wav`. Satsuma doesn't ship it: it synthesizes its own click at launch (`HighlightClick`), with the same character (60 ms at 48 kHz, a ~5 ms bright tick around 8.5–10 kHz that dies out within 6 ms).

## Interface (version 2)
The interface is modelled on the original app's official screenshots and demo video, plus the wheel geometry the original app publishes, which is identical to the binary's (a test checks the petal path down to the thousandth):
- **Wheel**: SwiftUI with Liquid Glass on macOS 26, layered as in the binary's wheel body: a `Glass.clear` ring tinted 50 % grey, or 50 % black in dark mode; then a `GlassEffectContainer(spacing: 0)` holding only the `.regular.interactive()` petals, each with a `glassEffectID`; then the labels and the center capsule above the glass. `#FF5200` highlight (the binary's `AccentColor`), SF Pro Rounded labels, SF Symbol icons for tools and actions, center capsule. "Metallic" theme and a fallback for earlier systems.
- **Menu bar menu**: rebuilt on every open. It shows "Satsuma is working/ready", the shortcut summary (⇧ Convert · ⌘ Tools · ⌃ Actions), active tasks ("source → target"), a "Launch at Login" checkmark item, Settings…, Getting Started…, About and Quit.
- **Menu bar icon** (Satsuma's own option, Settings → General → Appearance): "Show icon in menu bar" hides the status item while Satsuma keeps running. Opening the app again (Finder, Spotlight) shows Settings, so the icon can be turned back on.
- **Launch at login** is on by default: the first launch from the app bundle registers `SMAppService.mainApp` once. Turning it off (menu bar, Settings → General → Startup, or the Welcome's last page) sticks.
- **Progress panel**: 360×108 glass pill with corner radius 24, ✕, title and status. The 5 pt orange bar sweeps while indeterminate. The finished state shows "Show in Finder" (opens Finder with the files selected), "Finished with errors" / "Couldn’t finish" plus the error list, and closes itself after 4 s on success. Clicking the background reveals the files, but clicks on ✕ and on buttons go to the button.
- **Float**: decoded `FloatingTabLayout`:
  - compact 100–116 × 115/131 pt;
  - expanded with icons (row 92) or list (row 38), viewport up to 472 pt;
  - attaches to the nearest screen edge with square corners on that side;
  - a stack of up to 3 cards with Satsuma's own paper clip, which lifts when files are added;
  - drag to select and keyboard navigation (Space = Quick Look, ⌫ = remove, arrows);
  - context menu: Quick Look, Show in Finder, Open With, Duplicate, Move to Trash, Remove, Clear All.
- **Welcome**: borderless capsule window, 875×565 canvas scaled 0.8 to 700×452 with radius 226:
  - first page #FF6A00 orange with a yellow #FFD900 glow, "Welcome to" 42 / "Satsuma" 96 with a gradient, white Continue;
  - next pages on the window background (light or dark): wheel on the left, column on the right with Back, title, steps and the #FF7901 Continue (169 pt), page dots at the bottom;
  - close and minimize placed on the top-left curve, with the zoom light disabled;
  - pages: File Converter, File Tools, File Actions (wheel + dark keys showing the user's real shortcuts), Folder access, Finish setup (menu bar illustration and Launch at login card);
  - Folder access has an orange "Allow Access to Home Folder" button. The panel opens inside the home folder, so one click on Allow Access grants it; any allowed folder that contains home (e.g. `/Users`) counts. Once granted, a green checkmark draws itself, with the system "Glass" sound.
- **Wheel animation** (Satsuma's own): the wheel opens like a bubble, growing from the pointer with a spring that overshoots by about 20 % and wobbles back two or three times in about 0.3 s (width and height on slightly different springs). On close it swells for a moment, then shrinks back into the pointer and fades (0.25 s); the panel is ordered out only afterwards, and keeps 32 pt of room around the wheel for the overshoot. With Reduce Motion it only fades.
- **Wheel drop area**: a 1/255 alpha disc under the petals keeps the window server from letting drags fall through Liquid Glass's empty pixels, so a petal highlights anywhere over its area, not only over the label.
- **Settings**: 456×560 window with toolbar tabs:
  - General: Startup (launch at login, first), appearance, drag modifiers, Float, Terminal;
  - Formats: search, group chips, "<FMT> Settings", Restore Defaults;
  - Compression: image/video presets used by the Compress tool, Restore Compression Defaults;
  - Compatibility: input → output matrix per group, with legend;
  - Folders: allowed folders with Choose Again / Remove access;
  - About.
- **22 tool windows** and the **QR** panel, as before.
- App **icon** from `Resources/AppIconArtwork.png` (`scripts/make_icon.swift` → `Resources/AppIcon.icns`).

Debug: `Satsuma --render-tool <tool> out.png <file>…` renders a tool window to PNG.

## Not rebuilt yet / differences
- Merged cells are recognised only in ruled tables (where the missing rule shows the merge); borderless tables are a plain grid, as in the original.
- The video previews in the windows use AVPlayer: formats AVFoundation can't read (e.g. MKV/WebM) open without a preview, but export still works through ffmpeg.
- The paper clip, the folder and the menu bar illustration are Satsuma's own drawings, not the original app's assets.
- There's no paywall: the original's "free uses", Unlock and RevenueCat screens are not rebuilt, by choice.
