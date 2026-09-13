# TrueClose

A tiny macOS menu bar app that quits apps automatically when they have no windows
open — closing the last window really closes the app, like on Windows.

## Download

Go to [Releases](../../releases) and grab the latest version. You'll find two install
options attached — pick whichever you prefer:

- **`TrueClose.pkg`** (recommended) — double-click, click through the installer like
  any normal Mac app. It copies TrueClose into `Applications` for you automatically.
- **`TrueClose.dmg`** — open it, then drag `TrueClose.app` into the `Applications`
  folder shortcut shown inside.

**Want to build it yourself instead?** Download the source code (green **Code**
button above → **Download ZIP**, or `git clone` this repo), then see
[Build it yourself](#build-it-yourself) below.

## First open ("unidentified developer" warning)

This app isn't signed with a paid Apple certificate, so macOS blocks it the first
time, regardless of whether you installed via `.pkg` or `.dmg`. This is normal and
only happens once.

**If you installed via `.pkg`:**
Right-click `TrueClose.pkg` → **Open** → click **Open** again in the popup, then go
through the installer as usual. After install, the app opens with no further warnings.

**If you installed via `.dmg`:**
After dragging `TrueClose.app` into `Applications`, right-click it → **Open** → click
**Open** again in the popup. That's it, it won't ask again after this.

If macOS still refuses to open it, go to **System Settings → Privacy & Security**,
scroll down, and click **Open Anyway** next to the TrueClose warning.

## Grant permission

TrueClose needs Accessibility permission to see how many windows an app has open.

On first launch, click **"Open System Settings to grant permission"** and turn on
TrueClose in **Privacy & Security → Accessibility**.

## How to use it

Click the icon in the menu bar to Pause/Resume, open Settings, or Quit.

In Settings:
- **General** — pause, launch at login, delay before quitting, hide the menu bar icon
- **Rules** — choose apps to exclude (Blacklist) or include (Whitelist)
- **Accessibility** — permission status

## Build it yourself

```bash
./build.sh
```

This builds `TrueClose.app`, signs it, and packages both `TrueClose.dmg` and
`TrueClose.pkg` for you — no extra steps needed.

## Uninstall

Quit the app, delete it from `/Applications`, and optionally run:
```bash
defaults delete com.trueclose.app
```