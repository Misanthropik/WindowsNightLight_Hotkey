# Night Light Toggle

![Platform](https://img.shields.io/badge/platform-Windows%2011-0078D4)
![AutoHotkey](https://img.shields.io/badge/AutoHotkey-v1.1.33%2B-334455)
![AutoHotkey](https://img.shields.io/badge/AutoHotkey-v2.0.15%2B-334455)

![License](https://img.shields.io/badge/license-MIT-green)

One hotkey to flip Windows 11 Night Light — the same thing the Quick Settings tile does, done at the registry level. No UI, no background polling. One operation per press, then idle.

> [!IMPORTANT]
> It starts in **dry run** mode. Press the hotkey once and read what it *would* write before you go live.

## Usage

- `Ctrl+Alt+N` is the default hotkey — change the last line of the script.
- Press hotkey. The box shows the current value, the value it would write and the Cloud delta - nothing is touched.
- Open the script in your text editor, search for the term DRY_RUN and change the value from **DRY_RUN := true** to **DRY_RUN := false**. After saving your changes, reload the script and you’ll be able to toggle Night Light using a hotkey now.
- To run at login, put a shortcut in`shell:startup`.  
- Note: Holding the key will not machine-gun toggles: the debounce timestamp is stamped only after the whole operation, Cloud mirror included, has finished.

## What it does

- Toggles Night Light in Windows
- Edits the `Data` value under the Current `bluelightreductionstate` key, then mirrors the counter into the matching Cloud key so sync does not revert it
- Refuses and changes nothing if the binary layout is not exactly what it expects
- Writes a `.reg` backup before the first live write of a session

## What it does not do

- Does not touch any registry value other than those two `Data` values

## Bug

- If you attempt to switch the night schedule on and off, you might run into a `Not changing anything` error. To resolve this, simply toggle the night light manually once and it should function correctly again. 

## Requirements

| | |
|---|---|
| OS | Windows 11 |
| Runtime | AutoHotkey v1.1.33+ or v2.0.15+ (**v1**, **v2**) |
| Privileges | None — everything is under `HKCU` |

## Install

1. Download the script.
## Prerequisites

This script requires **AutoHotkey** (Windows only). Choose **one** of the installation methods below depending on which version you need.

> **Note:** AutoHotkey v1 and v2 are not backward-compatible. Make sure you install the version specified for this project (you can safely have both installed on the same machine, as the v2 launcher automatically detects which version a script requires).

---

### Option 1: Install via Command Line (`winget`) — *Recommended*

Open **PowerShell** or **Command Prompt** and run the command for your required version:

* **Install AutoHotkey v2 (Current):**
  ```powershell
  winget install AutoHotkey.AutoHotkey
  ```

* **Install AutoHotkey v1.1 (Legacy):**
  ```powershell
  winget install AutoHotkey.AutoHotkey --version 1.1.37.02
  ```

---

### Option 2: Manual Installation

1. Go to the [official AutoHotkey download page](https://www.autohotkey.com/).
2. Click **Download** and select either:
   * **Download v2.0** *(recommended for new scripts)*
   * **Download v1.1** *(for legacy scripts)*
3. Run the downloaded `.exe` installer and follow the on-screen prompts.
4. Once installed, double-click any `.ahk` file to run it.






## Configuration

Edit the block at the top of the script.

| Variable | Default | Meaning |
|---|---|---|
| `DRY_RUN` | `true` | When true, nothing is written; presses only show what would happen. |
| `ENABLE_BACKUP` | `true` | Export a `.reg` backup of both keys before the first write of each session. |
| `ENABLE_LOG` | `true` | Append each live toggle to `nightlight_log.txt`, rotated at `LOG_MAX`. |
| `SHOW_TOAST` | `false` | Show the resulting state as a tooltip at the cursor. |
| `FORCE_STATE` | `""` | `""` flips, `"on"` / `"off"` set idempotently — no-op if already there. |
| `DEBOUNCE_MS` | `50` | Minimum gap between presses. |
| `MIRROR_WAIT_MS` | `150` | Wait before touching Cloud, so the shell can update it first. |


## Safety

> [!WARNING]
> Registry editing
