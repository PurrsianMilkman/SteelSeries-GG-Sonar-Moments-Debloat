# Steelseries debloater

This patch disabled everything but the mixer and moments. Account requirment and telemetry is removed.

## Easy install (one file)

To install and use:

1. Download the original installer from the Internet Archive: https://archive.org/details/steel-series-gg-123.0.0-setup (`SteelSeriesGG123.0.0Setup.exe`)
2. Download the patch: https://github.com/PurrsianMilkman/SteelSeries-GG-Sonar-Moments-Debloat/releases/download/v1.0.0/GG-Debloat-123.bat
3. Put both the installer and the bat file in the same folder and run the bat file (click **Yes** on the administrator prompt). It installs and patches GG for you.
4. Start GG from the Start menu. Sonar and Moments work without signing in.

Your support is greatly appreciated. Nothing is paywalled: https://www.patreon.com/cw/Purrsian

## Details

A one-file patch that turns **SteelSeries GG 123.0.0** into just the two parts many people actually want, the **Sonar mixer** and **Moments**, with:

- **no telemetry**: every GG program is blocked from the network, so nothing is sent to `void.steelseries.com` or anywhere else
- **no account**: no login screen, no "sign in to use Sonar" wall, no account needed at all
- **no ads**: News, Giveaways, promo banners and the Discord/Feedback buttons are gone
- **everything else off**: Engine, Prism, 3D Aim Trainer, Performance Coach and Loadouts are disabled

> Unofficial. Not affiliated with, endorsed by, or supported by SteelSeries. This repository contains **no SteelSeries files**: it works on your own copy of the official installer. Use at your own risk.

## More about using it

The installer is **`SteelSeriesGG123.0.0Setup.exe`** (SHA-256 `E8846A8793B707E2829702112FE47314ED3DD2433AB80DC42099E33B68288BCC`, 413.6 MB, signed by GN Hearing A/S). Any copy works as long as its SHA-256 matches. Start GG from the Start menu, not from the patch window.

The patch installs GG 123.0.0 for you if it isn't installed yet. If it is already installed, the installer file isn't needed.

It refuses to touch anything else: it only accepts that exact installer (by SHA-256) and an unmodified GG 123.0.0 `app.asar`. If you are on another version, it stops and explains why.

**Undo everything:** open a command prompt in that folder and run `GG-Debloat-123.bat -Undo`. It restores the original UI, removes the firewall blocks, re-enables the updater and restores the settings it changed.

Other options: `-Allow-Moments-Network` (see below) and `-SelfTest` (checks everything without changing anything).

## What it changes

| Where | Change |
|---|---|
| `resources\app.asar` (the UI) | 23 small edits: no login screen or route guard, no sign-in splash on Sonar/Moments, signed-out start-up no longer switches Sonar off, News/Giveaways/Loadouts/Engine/Aim Tools removed, footer reduced to Settings, promo toast/flyout removed, the UI's own crash-report DSN blanked, start-up no longer waits for the Engine. A backup of the original is kept in `C:\ProgramData\GG-Debloat\backup`. |
| GG databases (`C:\ProgramData\SteelSeries\GG\db`) | Engine, 3D Aim Trainer and Performance Coach switched off; personalisation and automatic game scanning switched off; promo list emptied. Backed up first. |
| Windows Firewall | One outbound **Block** rule for every `.exe` under the GG folder (group `SSGG-Debloat`). This is the telemetry switch: GG's core has no opt-out setting and forwards every app's analytics upstream. |
| Update service | `SteelSeriesGGUpdateServiceProxy` set to Disabled (an update would undo the patch). |

Nothing is installed besides GG itself; a log of each run is written to `C:\ProgramData\GG-Debloat\last-run.log`.

## Trade-offs, read these

- **Moments sharing/upload is blocked.** Moments ships its own Sentry crash reporting, and a program-level firewall can't separate that from its sharing features. Local recording and clipping are not affected. If you want sharing, run `GG-Debloat-123.bat -Allow-Moments-Network` (Moments then stays open to the network, including its crash reporting).
- **A SteelSeries headset's hardware ChatMix dial stops working** without the Engine (the on-screen ChatMix slider still works). Sonar itself only uses the Engine for that hardware integration.
- **No automatic updates.** To update GG later, run `-Undo` first, update, then wait for a patch that supports the new version.
- Windows may show "Windows protected your PC" for a downloaded `.bat`. It is plain text: open it in Notepad first if you want to read it, then choose *More info > Run anyway*.

## Tested (honest status)

Tested on one machine (Windows 11 24H2, GG 123.0.0):

| | |
|---|---|
| Installer check refuses a wrong file name, wrong bytes, or a non-stock UI file | tested |
| Full flow from the real 413 MB installer: install, patch, firewall, databases, updater | tested |
| Patch, backup, `-Undo` (restores the stock UI), patch again | tested |
| UI starts (reaches its main loop) signed out, Engine off; Sonar starts and routes Game/Chat/Media/Aux | tested |
| Zero connections outside the PC from any GG process after the patch | tested |
| Works from a path with spaces | tested |
| A completely fresh machine that has never run GG | **not tested**: the databases don't exist yet, so the tool patches the UI and firewall and asks you to start GG once, close it, and run the patch again to switch the Engine off |
| Moments recording itself | process runs without errors; a recording was **not** exercised |
| Moments sharing | blocked by design |

## How it works, and how to check it

`GG-Debloat-123.bat` is plain text: a few lines of batch, then readable PowerShell and C# (SQLite goes through the `winsqlite3.dll` that ships with Windows, so no extra tools or Python are needed). Open it and read it before running it.

GG's UI is a minified React bundle whose variable names change every release, so each edit is a regular expression that captures those names and anchors on words that don't change (`.startupAllowed`, `getIsLoginSkipped`, route paths, ...). Every edit has an expected match count, and after patching the tool checks that the result is **byte-for-byte the exact build the author tested** (SHA-256 `28AAE505...`); if anything differs, nothing is installed.

The regular expressions have one source of truth, `dev/patch_ui.py`; `build.py` turns them into the `.bat`:

```
python build.py --setup-sha256 E8846A8793B707E2829702112FE47314ED3DD2433AB80DC42099E33B68288BCC ^
                --orig-asar-sha256 CE8A49176EB1CB0F3C07023A9C9E8ECD251EF590487B477D08F45E9D4929561D ^
                --patched-asar-sha256 28AAE50517272F3CCC707E1D1443B49B1BAAB8A52848A451315B7FECE48C5CC3
```

`dev/patch_ui.py` also works on its own (`--dry-run`, `--extract`) for anyone porting this to a newer GG release: it aborts if any edit stops matching.

## License

MIT, see [LICENSE](LICENSE). SteelSeries, GG, Sonar and Moments are trademarks of their owners.
