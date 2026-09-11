# TrueClose

A tiny macOS menu bar app that quits apps automatically when they have no windows
open — closing the last window really closes the app, like on Windows.

## Download

Choose one:

- **Just want to use the app?** → Download `TrueClose.dmg` from
  [Releases](../../releases), open it, drag `TrueClose.app` into `Applications`.
- **Want to build it yourself instead?** → Download the source code (green **Code**
  button above → **Download ZIP**, or `git clone` this repo), then see
  [Build it yourself](#build-it-yourself) below.

## First open ("unidentified developer" warning)

This app isn't signed with a paid Apple certificate, so macOS blocks it by default.

Right-click `TrueClose.app` → **Open** → click **Open** again in the popup. That's it,
it won't ask again after this.

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
./build.sh      # builds TrueClose.app
./make_dmg.sh   # packages it into TrueClose.dmg
```

## Uninstall

Quit the app, delete it from `/Applications`, and optionally run:
```bash
defaults delete com.trueclose.app
```