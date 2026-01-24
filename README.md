# BC64Keys 🎹

**A simple, secure keyboard remapper for macOS** — the straightforward alternative to Karabiner Elements.

[![License: GPL-3.0](https://img.shields.io/badge/License-GPL%20v3-blue.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/Platform-macOS-lightgrey.svg)]()
[![Swift 5](https://img.shields.io/badge/Swift-5-orange.svg)]()

---

## Why BC64Keys?

**Frustrated with Karabiner's complexity?** You're not alone.

I created BC64Keys because I just wanted to **remap a few keys** — not learn a new configuration language, edit JSON/XML files, or navigate through hundreds of options.

### BC64Keys vs Karabiner Elements

| Feature | BC64Keys | Karabiner Elements |
|---------|----------|-------------------|
| Configuration | Visual GUI, click & press | JSON config files |
| Learning curve | ⚡ Minutes | 📚 Hours/Days |
| Codebase size | ~1,500 lines | ~100,000+ lines |
| Code auditability | ✅ Easy to review | ❌ Very complex |
| Setup time | 30 seconds | 10-30 minutes |

### 🔒 Security First

**This app has access to your keystrokes** — that's how keyboard remapping works. 

This is why BC64Keys is:
- **100% Open Source** (GPL-3.0)
- **Single file codebase** (~1,500 lines) — anyone can audit it
- **No network access** — works completely offline
- **No data collection** — your keystrokes stay on your Mac
- **No external dependencies** — pure Swift/SwiftUI

> Unlike massive, complex tools where security vulnerabilities can hide in thousands of files, BC64Keys is simple enough that **you can read and verify the entire codebase yourself**.

---

## Features ✨

- **🖱️ Visual Key Capture** — Just click and press the key you want to remap
- **🔄 Simple Key Swaps** — Remap any key to any other key
- **🎯 Navigation Actions** — Map keys to macOS shortcuts (Home → Cmd+←, etc.)
- **🚫 Key Blocking** — Disable annoying keys completely
- **🚀 Launch at Login** — Optional auto-start when you log in (toggle in Settings)
- **🌍 Multi-language** — English, Hungarian (easily extensible)
- **⚡ Instant Apply** — Changes take effect immediately, no restart needed
- **💾 Auto-save** — Your mappings persist between app restarts

### Perfect for Windows Switchers 🪟→🍎

Coming from Windows? BC64Keys includes pre-configured actions for:
- Home/End → Line start/end (⌘←/⌘→)
- Ctrl+Home/End → Document start/end
- Page Up/Down → macOS equivalents
- And many more...

---

## Screenshots

<!-- TODO: Add screenshots -->
*Coming soon*

---

## Installation

### Option 1: Download Release (Recommended)
1. Download the latest `.app` from [Releases](https://github.com/badcode64/BC64Keys/releases)
2. Move `BC64Keys.app` to your Applications folder
3. Open it and grant Accessibility permission when prompted

### Option 2: Build from Source
```bash
# Clone the repository
git clone https://github.com/badcode64/BC64Keys.git
cd BC64Keys

# Build and run
./build.sh
open BC64Keys.app
```

### Granting Accessibility Permission

BC64Keys needs Accessibility permission to remap keys:

1. Open **System Settings** → **Privacy & Security** → **Accessibility**
2. Click the **+** button
3. Add **BC64Keys** and enable it
4. Restart BC64Keys if needed

### Why Accessibility?

Keyboard remapping on macOS requires intercepting and modifying system-wide key events before they reach applications. This low-level access is protected by macOS's Accessibility permission system to prevent unauthorized keylogging or input manipulation. BC64Keys uses a `CGEventTap` to observe and transform keyboard events globally — this is the same mechanism used by system utilities like macOS's own keyboard shortcuts. Without this permission, the app cannot intercept keys and remapping won't work.

---

## Usage

### Remapping a Key

1. Go to the **Mapping** tab
2. Click **+ New Rule**
3. Click the **Source** box and press the key you want to remap
4. Choose the target:
   - **Key Swap**: Click target box and press replacement key
   - **Navigation**: Select a predefined macOS action
5. Click **Save**

### Monitoring Keys

Use the **Monitor** tab to see what keys you're pressing — useful for finding key codes and testing your mappings.

Tip: while running, BC64Keys writes status logs to `~/Library/Logs/BC64Keys/bc64keys-status.log`.

---

## Building

Requirements:
- macOS 13.0+
- Xcode Command Line Tools (`xcode-select --install`)

```bash
./build.sh
```

The app will be created as `BC64Keys.app` in the project directory.

---

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

### Areas where help is appreciated:
- Translations (add your language!)
- UI/UX improvements
- Bug fixes
- Documentation

---

## Support the Project ☕

If BC64Keys saved you time and frustration, consider buying me a coffee!

[![Buy Me A Coffee](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://buymeacoffee.com/badcode64)

Your support helps me maintain and improve BC64Keys. Thank you! 🙏

---

## License

This project is licensed under the **GNU General Public License v3.0** — see the [LICENSE](LICENSE) file for details.

This means:
- ✅ You can use, modify, and distribute this software
- ✅ You can use it commercially
- ⚠️ Any modifications must also be open source (GPL-3.0)
- ⚠️ You must include the original license and copyright notice

---

## Acknowledgments

- Built with SwiftUI and ❤️
- Inspired by the need for simplicity

---

**Made by [BadCode64](https://github.com/badcode64)** | Hungary 🇭🇺
