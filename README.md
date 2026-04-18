# Remove-Python313

> **Complete Python 3.13 removal for Windows** — handles every installation method, including the broken uninstaller edge cases.

---

## The problem

Python 3.13 on Windows is notoriously difficult to remove cleanly. The official uninstaller fails silently in several common scenarios:

- Installed system-wide ("for all users") but uninstalled from a per-user context → **MSI scope conflict, exit code `0x80070643`**
- Installed via Chocolatey first, then Chocolatey records removed → **bootstrapper can't find its own config, aborts**
- Files already deleted manually but registry records still present → **Add/Remove Programs shows it forever**
- Multiple install methods used at different times → **partial removal, leftover PATH entries, broken shims**

This script detects all of these situations and handles them correctly.

---

## What it removes

| Source | Method |
|---|---|
| Official python.org installer (per-user and all-users) | MSI uninstall → registry cleanup |
| Chocolatey (`choco install python313`) | `choco uninstall` first, then manual cleanup |
| winget (`winget install Python.Python.3.13`) | `winget uninstall`, then manual cleanup |
| Microsoft Store (Appx) | `Remove-AppxPackage -AllUsers` |
| pyenv-win | Direct version folder removal |
| Anaconda / Miniconda / conda environments | `conda env remove`, fallback to folder removal |
| Orphaned MSI records (files gone, registry intact) | Registry key deletion |
| Burn bootstrapper in Package Cache | Cache folder removal |
| PATH entries (Machine and User scope) | Filtered and rewritten |
| Start Menu shortcuts | Backed up and deleted |
| pip cache (cp313 wheels) | Selective removal, other versions untouched |
| pipx venvs built with 3.13 | pyvenv.cfg verified before removal |
| virtualenvs (any location) | Recursive pyvenv.cfg scan |
| Jupyter kernels referencing 3.13 | kernel.json verified before removal |
| py.ini references | Backed up and deleted |

---

## Usage

```powershell
# Always do a dry run first — no files are deleted, just shows what would happen
.\Remove-Python313.ps1 -WhatIf

# Full removal
.\Remove-Python313.ps1

# Full removal with custom backup location
.\Remove-Python313.ps1 -BackupRoot D:\backups

# Skip file-tree backups (registry and PATH are always backed up)
.\Remove-Python313.ps1 -SkipBackup
```

**Must be run as Administrator.** Right-click PowerShell → Run as Administrator.

---

## How it works

The script runs in three phases:

**Phase 1 — Detection**
Scans for every known installation method before touching anything. Reports what it found and how it was installed.

**Phase 2 — Removal**
Removes using the appropriate method for each detected source. If Chocolatey is detected, it runs `choco uninstall` first. If winget is detected, it runs `winget uninstall`. Only after the proper uninstaller runs does it fall through to manual cleanup — avoiding the MSI scope conflict.

**Phase 3 — Summary**
Reports everything removed and flags anything that still needs manual attention.

---

## Safety

- Every file tree is **backed up** before deletion (default: `C:\scripts\backups\<timestamp>\`)
- Every registry key is **exported** to a `.reg` file before deletion
- Every PATH change is saved to a `.txt` file before modification
- Version is **verified** (via `python.exe --version` or `pyvenv.cfg`) before any folder is removed — other Python versions are never touched
- `-WhatIf` dry-run shows all planned actions without making any changes

---

## After running

Reboot, then verify in a new PowerShell session:

```powershell
py -0p
where python
```

Python 3.13 should not appear in either output.

---

## Why this is harder than it should be

The Python Windows installer uses the WiX Burn bootstrapper, which records the bundle as PerUser but installs the actual MSI components as PerMachine when you choose "Install for all users." When you later try to uninstall, the bundle can't cleanly orchestrate removal of its own per-machine packages — resulting in `0x80070643` (fatal MSI error). This is a known issue filed against the Python installer that has affected versions 3.11 through 3.13.

On top of that, Chocolatey stores an `unattend.xml` hook that the Python uninstaller looks for. If Chocolatey's records are cleaned up before the official uninstaller runs, the bootstrapper finds neither its Chocolatey configuration nor a clean MSI state and aborts.

This script works around both issues by handling each installation source independently.

---

## Requirements

- Windows 10 or 11
- PowerShell 5.1 or later (built into Windows)
- Administrator privileges

No external dependencies. No modules to install.

---

## Contributing

Issues and PRs welcome — especially reports of installation scenarios not yet covered.
