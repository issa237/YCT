# YCT — YouTube High-Moment Clipping Tool (macOS)

A native macOS application (`YCT.app`) and installable disk image (`YCT-Installer.dmg`) that downloads YouTube videos, detects the highest-engagement **"High Moments"** (via YouTube's **Most Replayed** heatmap + **FFmpeg Audio Excitement & Energy Peak** analysis), and extracts non-overlapping ready-to-share `.mp4` clips into your chosen folder.

---

## 📥 Download & Install (For Users)

### Option 1: Direct `.dmg` Installer (Recommended)
1. Download **[`YCT-Installer.dmg`](https://github.com/issa237/YCT/releases/latest/download/YCT-Installer.dmg)** from the [Releases page](https://github.com/issa237/YCT/releases) (or click [`YCT-Installer.dmg`](./YCT-Installer.dmg) directly in this repository).
2. Double-click **`YCT-Installer.dmg`** to mount the installer window.
3. Drag **`YCT.app`** into the **`Applications`** folder shortcut.
4. Make sure `ffmpeg` and `python3` are installed on your Mac (via Homebrew):
   ```bash
   brew install ffmpeg python3
   ```
5. Open **`YCT`** from `/Applications`.
   > **Note (macOS Gatekeeper):** If macOS says the app is from an unidentified developer on first launch, right-click **`YCT.app`** → click **Open**, or run:
   > ```bash
   > xattr -cr /Applications/YCT.app
   > ```

---

## 🛠️ Build from Source (For Developers)

Anyone can clone this repository and build both `YCT.app` and `YCT-Installer.dmg` locally on macOS (macOS 13.0+ with Xcode Command Line Tools):

```bash
# 1. Clone the repository
git clone https://github.com/issa237/YCT.git
cd YCT

# 2. Ensure dependencies are installed
brew install ffmpeg python3

# 3. Build YCT.app and package YCT-Installer.dmg
./scripts/build_dmg.sh
```

After running `./scripts/build_dmg.sh`, you will find:
- **`build/YCT.app`** — The compiled native macOS application bundle.
- **`YCT-Installer.dmg`** — The distributable drag-and-drop macOS installer disk image.

---

## ✨ Key Features

- **Custom Number of Clips (`N`)**: Choose anywhere from `1` to `30` high-moment clips (with quick presets for `3`, `5`, `8`, `10` clips).
- **Flexible Clip Duration (`D` seconds)**:
  - Set a **uniform duration** for all clips (e.g., `15s`, `30s`, `45s`, `60s`, `90s`, `120s`, or any custom value).
  - Or check **"Set custom duration for each individual clip"** to specify a different duration for `Clip #1`, `Clip #2`, etc.
  - Fine-tune individual clip `Start (s)` and `Duration (s)` directly in the clip list before extracting.
- **Output Folder Picker**: Select any destination folder on your Mac using the native Finder dialog, and click **Open Clips Folder** or **Show Clip** to reveal extracted clips immediately.
- **Dual-Tier High-Moment Detection Engine**:
  1. **Tier 1 — YouTube Most Replayed Heatmap**: Parses `heatmap` replay intensity curves directly from YouTube metadata.
  2. **Tier 2 — Audio Excitement & RMS Surge Analysis**: Decodes the audio stream at 1000 Hz via FFmpeg to calculate 1-second RMS energy + dynamic surge scores across the timeline.
  3. **Smart Window Centering & Non-Overlap Guard**: Centers each clip window around the climax peak while guaranteeing no two clips overlap.
- **Export Formats**:
  - **Original (`16:9` / Source)**: Frame-accurate H.264 + AAC `.mp4`.
  - **Vertical `9:16` (Shorts / Reels / TikTok)**: Auto-crops and scales to `1080x1920` vertical `.mp4`.
- **Keep or Clean Up Full Video**: Saves only the extracted highlight clips by default, with a checkbox to also keep the full downloaded video in your output folder.

---

## 📂 Project Structure

```text
YCT/
├── YCT-Installer.dmg               # Ready-to-install macOS Disk Image
├── README.md                       # Documentation & installation guide
├── LICENSE                         # MIT License
├── Sources/
│   ├── Models.swift                # Data models for heatmap, chapters, clips, and formatters
│   ├── HighlightDetector.swift     # Peak ranking, non-overlap solver, and 1000Hz PCM RMS analyzer
│   ├── ClipEngine.swift            # Async orchestration engine for yt-dlp and ffmpeg
│   ├── ContentView.swift           # Native SwiftUI macOS interface & visual timeline
│   └── YCTApp.swift                # App entry point
├── Resources/
│   ├── Info.plist                  # macOS Bundle configuration
│   ├── AppIcon.icns                # Custom generated macOS application icon
│   └── bin/
│       └── yt-dlp                  # Bundled universal yt-dlp binary
└── scripts/
    ├── build_dmg.sh                # One-command build & DMG packaging script
    ├── generate_icon.swift         # Programmatic macOS .icns generator
    └── test_pipeline.swift         # Automated highlight detector unit tests
```
