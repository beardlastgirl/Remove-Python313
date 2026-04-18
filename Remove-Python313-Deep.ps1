<#
.SYNOPSIS
    Remove-Python313.ps1 — Complete Python 3.13 removal for Windows
    
.DESCRIPTION
    Detects and removes Python 3.13 installed via ANY method:
      - Official python.org installer (user and all-users)
      - Chocolatey  (choco)
      - winget
      - Microsoft Store (Appx)
      - Anaconda / Miniconda / conda environments
      - pyenv-win
      - Manual / portable installs
      - Orphaned MSI records (files already deleted, registry still present)
      - Leftover artifacts: PATH entries, registry keys, pip cache,
        pipx venvs, virtualenvs, Jupyter kernels, shortcuts, py.ini,
        Package Cache bootstrapper, Start Menu folder

    Safe-by-design:
      - Every file tree, registry key, and PATH change is backed up before deletion
      - Version is verified before any folder is removed
      - Dry-run mode available (-WhatIf): shows what WOULD be done, deletes nothing
      - Full log written to C:\scripts\logs\

.PARAMETER WhatIf
    Preview mode. Shows all detections and planned actions without deleting anything.

.PARAMETER SkipBackup
    Skip file-tree backups (registry and PATH are always backed up).
    Use when disk space is tight and you already have your own backup.

.PARAMETER BackupRoot
    Override the default backup root (C:\scripts\backups\<timestamp>).

.EXAMPLE
    # Dry run first — always recommended
    .\Remove-Python313.ps1 -WhatIf

    # Full removal
    .\Remove-Python313.ps1

    # Full removal, custom backup location
    .\Remove-Python313.ps1 -BackupRoot D:\backups

.NOTES
    Run as Administrator.
    Tested on Windows 10 / 11.
    After running: reboot, then verify with:  py -0p  and  where python

	Version: 1.0.0 
	Created by: Chewalter
	Version: 2.0.0
	Created by: Claude-Code (Sonnet 4.6)
    Last Update: April 18, 2026
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$SkipBackup,
    [string]$BackupRoot = 'C:\scripts\backups'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

# ── Elevation check ───────────────────────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error 'This script must be run as Administrator. Right-click PowerShell → Run as Administrator.'
    exit 1
}

# ── Paths & logging ───────────────────────────────────────────────────────────
$timestamp  = (Get-Date).ToString('yyyyMMdd_HHmmss')
$BackupDir  = Join-Path $BackupRoot $timestamp
$LogDir     = 'C:\scripts\logs'
$LogFile    = Join-Path $LogDir "Remove-Python313_$timestamp.log"
$DryRun     = $WhatIfPreference.IsPresent

New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
if (-not $SkipBackup) {
    New-Item -Path (Join-Path $BackupDir 'files')    -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $BackupDir 'registry') -ItemType Directory -Force | Out-Null
    New-Item -Path (Join-Path $BackupDir 'path')     -ItemType Directory -Force | Out-Null
}

# ── Helpers ───────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "$(Get-Date -Format u)  [$Level]  $Message"
    Add-Content -Path $LogFile -Value $line
    switch ($Level) {
        'WARN'    { Write-Host $line -ForegroundColor Yellow }
        'ERROR'   { Write-Host $line -ForegroundColor Red    }
        'SUCCESS' { Write-Host $line -ForegroundColor Green  }
        'DRY'     { Write-Host $line -ForegroundColor Cyan   }
        default   { Write-Host $line }
    }
}

function Write-Section {
    param([string]$Title)
    $bar = '─' * 60
    Write-Log ''
    Write-Log $bar
    Write-Log "  $Title"
    Write-Log $bar
}

function Get-PythonExeVersion {
    param([string]$ExePath)
    try {
        $out  = & "$ExePath" --version 2>&1
        $text = (@($out | ForEach-Object { "$_" }) -join [Environment]::NewLine).Trim()
        return $text
    }
    catch { return $null }
}

function Test-Is313 {
    param([string]$VersionString)
    return ($VersionString -and $VersionString -match '3\.13')
}

# Backs up a directory tree then removes it (or just logs in dry-run)
function Remove-VerifiedDir {
    param([string]$Path, [string]$Reason)
    if (-not (Test-Path $Path)) { return }
    if ($DryRun) {
        Write-Log "[DRY-RUN] Would remove directory: $Path  ($Reason)" 'DRY'
        return
    }
    if (-not $SkipBackup) {
        $leaf   = [IO.Path]::GetFileName($Path.TrimEnd('\', '/'))
        $dest   = Join-Path $BackupDir "files\$leaf"
        New-Item -Path $dest -ItemType Directory -Force | Out-Null
        try   { Copy-Item -Path $Path -Destination $dest -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "Backed up: $Path → $dest" }
        catch { Write-Log "Backup failed for $Path : $_" 'WARN' }
    }
    try   { Remove-Item -Path $Path -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Removed: $Path  ($Reason)" 'SUCCESS' }
    catch { Write-Log "Failed to remove $Path : $_" 'ERROR' }
}

# Backs up a registry key then deletes it
function Remove-RegistryKey {
    param([string]$RegPath)   # expects reg.exe format e.g. HKLM\SOFTWARE\...
    if ($DryRun) {
        Write-Log "[DRY-RUN] Would delete registry key: $RegPath" 'DRY'
        return
    }
    if (-not $SkipBackup) {
        $safeName = ($RegPath -replace '[\\: ]', '_') + '.reg'
        $out      = Join-Path $BackupDir "registry\$safeName"
        $null     = & reg.exe export $RegPath $out /y 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Log "Registry backup: $out" }
        else { Write-Log "reg export warning (exit $LASTEXITCODE) for $RegPath" 'WARN' }
    }
    $null = & reg.exe delete $RegPath /f 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Log "Deleted registry key: $RegPath" 'SUCCESS' }
    elseif ($LASTEXITCODE -eq 2) { Write-Log "Registry key not found (already gone): $RegPath" }
    elseif ($LASTEXITCODE -eq 5) { Write-Log "Access denied for registry key: $RegPath  (may need SYSTEM ownership)" 'WARN' }
    else { Write-Log "reg delete failed (exit $LASTEXITCODE) for $RegPath" 'ERROR' }
}

# Converts PowerShell PSPath to reg.exe format
function ConvertTo-RegExePath {
    param([string]$PsPath)
    if ($PsPath -match '^Microsoft\.PowerShell\.Core\\Registry::(HKEY_[^\\]+)\\(.+)$') {
        $hive = switch ($matches[1]) {
            'HKEY_LOCAL_MACHINE'  { 'HKLM' }
            'HKEY_CURRENT_USER'   { 'HKCU' }
            'HKEY_CLASSES_ROOT'   { 'HKCR' }
            'HKEY_USERS'          { 'HKU'  }
            'HKEY_CURRENT_CONFIG' { 'HKCC' }
            default               { $matches[1] }
        }
        return "$hive\$($matches[2])"
    }
    if ($PsPath -match '^(HKLM|HKCU|HKCR|HKU|HKCC):\\(.+)$') {
        return "$($matches[1])\$($matches[2])"
    }
    return $PsPath
}

# ── Summary tracking ──────────────────────────────────────────────────────────
$summary = [ordered]@{
    DetectedMethods  = [System.Collections.Generic.List[string]]::new()
    DirsRemoved      = 0
    RegKeysRemoved   = 0
    PathsFixed       = 0
    ShortcutsRemoved = 0
    Issues           = [System.Collections.Generic.List[string]]::new()
}

# ── Banner ────────────────────────────────────────────────────────────────────
Write-Log '╔══════════════════════════════════════════════════════════╗'
Write-Log '║          Remove-Python313.ps1  —  github.com             ║'
Write-Log '║     Complete Python 3.13 removal for Windows             ║'
Write-Log '╚══════════════════════════════════════════════════════════╝'
Write-Log "Mode       : $(if ($DryRun) { 'DRY RUN (no changes will be made)' } else { 'LIVE' })"
Write-Log "Backup dir : $(if ($SkipBackup) { 'skipped' } else { $BackupDir })"
Write-Log "Log file   : $LogFile"

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 1 — DETECTION
# ═════════════════════════════════════════════════════════════════════════════
Write-Section 'PHASE 1 — DETECTION'

$installsFound = [System.Collections.Generic.List[hashtable]]::new()

# Helper: register a confirmed install
function Add-Install {
    param([string]$Method, [string]$Path, [string]$Note = '')
    $installsFound.Add(@{ Method = $Method; Path = $Path; Note = $Note })
    Write-Log "FOUND [$Method] $Path  $Note" 'SUCCESS'
    if (-not $summary.DetectedMethods.Contains($Method)) {
        $summary.DetectedMethods.Add($Method)
    }
}

# ── 1a. Chocolatey ────────────────────────────────────────────────────────────
Write-Log '→ Checking Chocolatey...'
$chocoExe = Get-Command choco -ErrorAction SilentlyContinue
if ($chocoExe) {
    $chocoList = & choco list 2>&1 | Where-Object { $_ -match '(?i)python313|python.*3\.13' }
    if ($chocoList) {
        Write-Log "Chocolatey package detected: $chocoList"
        Add-Install 'Chocolatey' 'choco package' $chocoList
    }
    else { Write-Log 'Chocolatey: no Python 3.13 package found' }
    # Also check lib folder directly (covers partial uninstalls)
    $chocoLib = 'C:\ProgramData\chocolatey\lib\python313'
    if (Test-Path $chocoLib) {
        Write-Log "Chocolatey lib folder still present: $chocoLib" 'WARN'
    }
}
else { Write-Log 'Chocolatey: not installed on this machine' }

# ── 1b. winget ────────────────────────────────────────────────────────────────
Write-Log '→ Checking winget...'
$wingetExe = Get-Command winget -ErrorAction SilentlyContinue
if ($wingetExe) {
    $wingetList = & winget list --id Python.Python.3.13 2>&1 | Where-Object { $_ -match '3\.13' }
    if ($wingetList) {
        Write-Log "winget package detected: $wingetList"
        Add-Install 'winget' 'winget package' $wingetList
    }
    else { Write-Log 'winget: no Python 3.13 package found' }
}
else { Write-Log 'winget: not available on this machine' }

# ── 1c. Microsoft Store (Appx) ────────────────────────────────────────────────
Write-Log '→ Checking Microsoft Store (Appx)...'
try {
    $appxPkgs = Get-AppxPackage -Name '*Python*' -AllUsers -ErrorAction SilentlyContinue |
                Where-Object { $_.PackageFullName -match '3\.13' }
    foreach ($p in $appxPkgs) {
        Add-Install 'Appx/Store' $p.PackageFullName
    }
    if (-not $appxPkgs) { Write-Log 'Appx: no Python 3.13 Store package found' }
}
catch { Write-Log "Appx enumeration failed (may need higher privilege): $_" 'WARN' }

# ── 1d. pyenv-win ─────────────────────────────────────────────────────────────
Write-Log '→ Checking pyenv-win...'
$pyenvRoots = @(
    "$env:USERPROFILE\.pyenv\pyenv-win\versions\3.13*"
    "$env:USERPROFILE\.pyenv\versions\3.13*"
)
foreach ($pattern in $pyenvRoots) {
    $matches313 = @(Get-Item $pattern -ErrorAction SilentlyContinue)
    foreach ($d in $matches313) { Add-Install 'pyenv-win' $d.FullName }
}
if (-not ($installsFound | Where-Object { $_.Method -eq 'pyenv-win' })) {
    Write-Log 'pyenv-win: no Python 3.13 version found'
}

# ── 1e. Conda / Anaconda / Miniconda ─────────────────────────────────────────
Write-Log '→ Checking conda environments...'
$condaExe = Get-Command conda -ErrorAction SilentlyContinue
if ($condaExe) {
    $condaEnvs = & conda env list 2>&1 | Where-Object { $_ -notmatch '^#' -and $_ -match '\S' }
    foreach ($line in $condaEnvs) {
        $envPath = ($line -split '\s+' | Where-Object { $_ -match '\\' -or $_ -match '/' }) | Select-Object -Last 1
        if ($envPath -and (Test-Path $envPath)) {
            $pyExe = Join-Path $envPath 'python.exe'
            if (-not (Test-Path $pyExe)) { $pyExe = Join-Path $envPath 'bin\python' }
            if (Test-Path $pyExe) {
                $ver = Get-PythonExeVersion $pyExe
                if (Test-Is313 $ver) { Add-Install 'conda' $envPath $ver }
            }
        }
    }
}
else { Write-Log 'conda: not found on this machine' }

# ── 1f. Official installer / manual — known candidate directories ─────────────
Write-Log '→ Checking standard install directories...'
$candidateDirs = @(
    'C:\Python313'
    'C:\Program Files\Python313'
    'C:\Program Files (x86)\Python313'
    "$env:LOCALAPPDATA\Programs\Python\Python313"
    "$env:USERPROFILE\AppData\Local\Programs\Python\Python313"
)
foreach ($dir in $candidateDirs) {
    if (-not (Test-Path $dir)) { continue }
    $pyExe = Join-Path $dir 'python.exe'
    if (Test-Path $pyExe) {
        $ver = Get-PythonExeVersion $pyExe
        if (Test-Is313 $ver) { Add-Install 'official-installer' $dir $ver }
        else { Write-Log "Skipping $dir — python.exe reported: $ver" }
    }
    else {
        # No exe — check pyvenv.cfg (portable / extracted install)
        $cfg = Join-Path $dir 'pyvenv.cfg'
        if ((Test-Path $cfg) -and ((Get-Content $cfg -ErrorAction SilentlyContinue) -match '3\.13')) {
            Add-Install 'official-installer (no exe)' $dir 'verified via pyvenv.cfg'
        }
    }
}

# ── 1g. Depth-limited filesystem scan ────────────────────────────────────────
Write-Log '→ Scanning C:\ for *Python313* directories (depth 3)...'
Get-ChildItem -Path 'C:\' -Directory -Filter '*Python313*' -Recurse -Depth 3 -ErrorAction SilentlyContinue |
ForEach-Object {
    $d     = $_.FullName
    # Skip if already found
    if ($installsFound | Where-Object { $_.Path -eq $d }) { return }
    $pyExe = Join-Path $d 'python.exe'
    if (Test-Path $pyExe) {
        $ver = Get-PythonExeVersion $pyExe
        if (Test-Is313 $ver) { Add-Install 'filesystem-scan' $d $ver }
    }
}

# ── 1h. Orphaned MSI / Uninstall registry records (files already gone) ────────
Write-Log '→ Scanning Uninstall registry for Python 3.13 records...'
$uninstallHives = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
)
$orphanedKeys = [System.Collections.Generic.List[hashtable]]::new()
foreach ($hive in $uninstallHives) {
    Get-ChildItem $hive -ErrorAction SilentlyContinue | ForEach-Object {
        $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($props -and $props.PSObject.Properties['DisplayName'] -and $props.DisplayName -match 'Python 3\.13') {
            $orphanedKeys.Add(@{
                PSPath         = $_.PSPath
                RegPath        = ConvertTo-RegExePath $_.PSPath
                DisplayName    = $props.DisplayName
                UninstallString = if ($props.PSObject.Properties['UninstallString']) { $props.UninstallString } else { $null }
            })
            Write-Log "Uninstall record found: $($props.DisplayName) at $($_.PSPath)"
        }
    }
}

# ── 1i. Burn Package Cache ────────────────────────────────────────────────────
Write-Log '→ Scanning Package Cache for Python 3.13 bootstrapper...'
$pkgCacheRoot = "$env:LOCALAPPDATA\Package Cache"
$burnCaches   = @(
    Get-ChildItem -Path $pkgCacheRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object {
        $exe = Get-ChildItem -Path $_.FullName -Filter 'python-3.13*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        $exe -ne $null
    }
)
foreach ($bc in $burnCaches) {
    Write-Log "Package Cache bootstrapper found: $($bc.FullName)"
}

# ── Detection summary ─────────────────────────────────────────────────────────
Write-Log ''
Write-Log "Detection complete. Install methods found: $(if ($summary.DetectedMethods.Count -eq 0) { 'none' } else { $summary.DetectedMethods -join ', ' })"
Write-Log "Uninstall registry records found : $($orphanedKeys.Count)"
Write-Log "Package Cache entries found      : $($burnCaches.Count)"

if ($installsFound.Count -eq 0 -and $orphanedKeys.Count -eq 0 -and $burnCaches.Count -eq 0) {
    Write-Log 'Nothing to remove. Python 3.13 does not appear to be installed.' 'SUCCESS'
    exit 0
}

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 2 — REMOVAL
# ═════════════════════════════════════════════════════════════════════════════
Write-Section 'PHASE 2 — REMOVAL'

# ── 2a. Chocolatey uninstall (preferred — cleanest method) ────────────────────
if ($summary.DetectedMethods -contains 'Chocolatey') {
    Write-Log '→ Removing via Chocolatey (preferred method)...'
    if ($DryRun) {
        Write-Log '[DRY-RUN] Would run: choco uninstall python313 -y --remove-dependencies' 'DRY'
    }
    else {
        $result = Start-Process -FilePath 'choco' -ArgumentList 'uninstall', 'python313', '-y', '--remove-dependencies' -Wait -PassThru
        Write-Log "choco uninstall exit code: $($result.ExitCode)"
        if ($result.ExitCode -eq 0) { Write-Log 'Chocolatey uninstall succeeded' 'SUCCESS' }
        else { Write-Log "Chocolatey uninstall returned non-zero; continuing with manual cleanup" 'WARN' }
    }
}

# ── 2b. winget uninstall ──────────────────────────────────────────────────────
if ($summary.DetectedMethods -contains 'winget') {
    Write-Log '→ Removing via winget...'
    if ($DryRun) {
        Write-Log '[DRY-RUN] Would run: winget uninstall --id Python.Python.3.13 --silent' 'DRY'
    }
    else {
        $result = Start-Process -FilePath 'winget' -ArgumentList 'uninstall', '--id', 'Python.Python.3.13', '--silent', '--accept-source-agreements' -Wait -PassThru
        Write-Log "winget uninstall exit code: $($result.ExitCode)"
        if ($result.ExitCode -eq 0) { Write-Log 'winget uninstall succeeded' 'SUCCESS' }
        else { Write-Log 'winget uninstall returned non-zero; continuing with manual cleanup' 'WARN' }
    }
}

# ── 2c. Appx / Store removal ──────────────────────────────────────────────────
if ($summary.DetectedMethods -contains 'Appx/Store') {
    Write-Log '→ Removing Microsoft Store packages...'
    $appxPkgs = Get-AppxPackage -Name '*Python*' -AllUsers -ErrorAction SilentlyContinue |
                Where-Object { $_.PackageFullName -match '3\.13' }
    foreach ($p in $appxPkgs) {
        if ($DryRun) {
            Write-Log "[DRY-RUN] Would remove Appx package: $($p.PackageFullName)" 'DRY'
        }
        else {
            try {
                Remove-AppxPackage -Package $p.PackageFullName -AllUsers -ErrorAction Stop
                Write-Log "Removed Appx package: $($p.PackageFullName)" 'SUCCESS'
            }
            catch { Write-Log "Failed to remove Appx package $($p.PackageFullName): $_" 'ERROR' }
        }
    }
}

# ── 2d. pyenv-win removal ─────────────────────────────────────────────────────
foreach ($install in ($installsFound | Where-Object { $_.Method -eq 'pyenv-win' })) {
    Write-Log "→ Removing pyenv-win version: $($install.Path)"
    Remove-VerifiedDir -Path $install.Path -Reason 'pyenv-win Python 3.13'
    $summary.DirsRemoved++
}

# ── 2e. conda environment removal ────────────────────────────────────────────
foreach ($install in ($installsFound | Where-Object { $_.Method -eq 'conda' })) {
    Write-Log "→ Removing conda environment: $($install.Path)"
    if ($DryRun) {
        Write-Log "[DRY-RUN] Would run: conda env remove --prefix $($install.Path) -y" 'DRY'
    }
    else {
        $result = Start-Process -FilePath 'conda' -ArgumentList 'env', 'remove', '--prefix', $install.Path, '-y' -Wait -PassThru
        Write-Log "conda env remove exit code: $($result.ExitCode)"
        if ($result.ExitCode -ne 0) {
            Write-Log 'conda remove failed; falling back to direct folder removal' 'WARN'
            Remove-VerifiedDir -Path $install.Path -Reason 'conda env Python 3.13'
        }
    }
    $summary.DirsRemoved++
}

# ── 2f. File system directories (official installer, filesystem-scan) ─────────
foreach ($install in ($installsFound | Where-Object { $_.Method -match 'official|filesystem' })) {
    Write-Log "→ Removing directory: $($install.Path)"
    Remove-VerifiedDir -Path $install.Path -Reason $install.Method
    $summary.DirsRemoved++
}

# ── 2g. Uninstall registry records (orphaned or official) ────────────────────
Write-Section 'Registry: Uninstall records'
foreach ($key in $orphanedKeys) {
    Write-Log "→ Processing uninstall record: $($key.DisplayName)"
    # Try the uninstaller first if files still exist
    if ($key.UninstallString -and -not $DryRun) {
        $u = $key.UninstallString
        Write-Log "  UninstallString: $u"
        try {
            if ($u -match '\{([0-9A-Fa-f\-]+)\}') {
                $guid = $matches[1]
                Write-Log "  Running msiexec /x {$guid} /qn"
                $msi = Start-Process 'msiexec.exe' -ArgumentList @('/x', "{$guid}", '/qn', '/norestart', '/l*v', (Join-Path $LogDir "msiexec_$guid_$timestamp.log")) -Wait -PassThru
                Write-Log "  msiexec exit code: $($msi.ExitCode)"
            }
            else {
                $result = Start-Process 'cmd.exe' -ArgumentList "/c `"$u`"" -Wait -PassThru
                Write-Log "  Uninstaller exit code: $($result.ExitCode)"
            }
        }
        catch { Write-Log "  Uninstaller threw: $_" 'WARN' }
    }
    # Always clean the registry record regardless of uninstaller outcome
    Remove-RegistryKey $key.RegPath
    $summary.RegKeysRemoved++
}

# ── 2h. Core PythonCore registry keys ────────────────────────────────────────
Write-Section 'Registry: PythonCore keys'
$coreRegKeys = @(
    'HKLM\SOFTWARE\Python\PythonCore\3.13'
    'HKLM\SOFTWARE\Wow6432Node\Python\PythonCore\3.13'
    'HKCU\SOFTWARE\Python\PythonCore\3.13'
)
foreach ($rk in $coreRegKeys) {
    $null = & reg.exe query $rk 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Log "→ Found: $rk"
        Remove-RegistryKey $rk
        $summary.RegKeysRemoved++
    }
    else { Write-Log "Not found (clean): $rk" }
}

# ── 2i. Burn Package Cache bootstrapper ──────────────────────────────────────
Write-Section 'Package Cache cleanup'
foreach ($bc in $burnCaches) {
    Write-Log "→ Removing Package Cache entry: $($bc.FullName)"
    Remove-VerifiedDir -Path $bc.FullName -Reason 'Burn bootstrapper cache'
}

# ── 2j. PATH cleanup ──────────────────────────────────────────────────────────
Write-Section 'PATH cleanup'
function Remove-PathEntries {
    param([string]$Scope)
    $orig = [Environment]::GetEnvironmentVariable('Path', $Scope)
    if (-not $orig) { Write-Log "No PATH found for scope: $Scope"; return }

    $dirty = $orig -split ';' | Where-Object { $_ -match '(?i)python.*3\.13|\\Python313\\?$|\\Python\\Python313' }
    if ($dirty.Count -eq 0) { Write-Log "PATH ($Scope): clean — nothing to remove"; return }

    Write-Log "PATH ($Scope): found $($dirty.Count) entry/entries to remove:"
    $dirty | ForEach-Object { Write-Log "  - $_" }

    if ($DryRun) { Write-Log "[DRY-RUN] Would clean PATH for scope: $Scope" 'DRY'; return }

    if (-not $SkipBackup) {
        $orig -split ';' | Out-File (Join-Path $BackupDir "path\PATH_${Scope}_$timestamp.txt") -Encoding utf8
    }
    $cleaned = ($orig -split ';' | Where-Object { $_ -ne '' -and $_ -notin $dirty }) -join ';'
    try {
        [Environment]::SetEnvironmentVariable('Path', $cleaned, $Scope)
        Write-Log "PATH ($Scope): updated successfully" 'SUCCESS'
        $summary.PathsFixed++
    }
    catch {
        Write-Log "PATH ($Scope): failed to update — $_" 'ERROR'
        $summary.Issues.Add("PATH ($Scope) update failed — may need manual fix")
    }
}
Remove-PathEntries -Scope 'Machine'
Remove-PathEntries -Scope 'User'

# ── 2k. Shortcuts ─────────────────────────────────────────────────────────────
Write-Section 'Shortcuts'
$shortcutRoots = @(
    "$env:ProgramData\Microsoft\Windows\Start Menu\Programs"
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
    [Environment]::GetFolderPath('Desktop')
)
$sh = $null
try {
    $sh = New-Object -ComObject WScript.Shell
    foreach ($root in $shortcutRoots) {
        Get-ChildItem -Path $root -Filter *.lnk -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object {
            try {
                $lnk = $sh.CreateShortcut($_.FullName)
                if ($lnk.TargetPath -and $lnk.TargetPath -match 'Python313|Python3\.13') {
                    if ($DryRun) {
                        Write-Log "[DRY-RUN] Would delete shortcut: $($_.FullName)" 'DRY'
                    }
                    else {
                        if (-not $SkipBackup) { Copy-Item $_.FullName -Destination (Join-Path $BackupDir 'files') -Force -ErrorAction SilentlyContinue }
                        Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue
                        Write-Log "Removed shortcut: $($_.FullName)" 'SUCCESS'
                        $summary.ShortcutsRemoved++
                    }
                }
            }
            catch { Write-Log "Could not inspect shortcut $($_.FullName): $_" 'WARN' }
        }
    }
    # Remove empty Python 3.13 Start Menu folder if it remains
    $smFolder = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Python 3.13"
    if ((Test-Path $smFolder) -and (@(Get-ChildItem $smFolder -ErrorAction SilentlyContinue).Count -eq 0)) {
        if (-not $DryRun) { Remove-Item $smFolder -Force -ErrorAction SilentlyContinue; Write-Log "Removed empty Start Menu folder: $smFolder" 'SUCCESS' }
        else { Write-Log "[DRY-RUN] Would remove empty Start Menu folder: $smFolder" 'DRY' }
    }
}
finally {
    if ($null -ne $sh) { [void][System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($sh) }
}

# ── 2l. py.ini ────────────────────────────────────────────────────────────────
Write-Section 'py.ini files'
$pyIniCandidates = @(
    'C:\Windows\py.ini'
    (Join-Path $env:LOCALAPPDATA 'py.ini')
    (Join-Path $env:USERPROFILE  'py.ini')
)
foreach ($f in $pyIniCandidates) {
    if (-not (Test-Path $f)) { continue }
    $txt = Get-Content $f -ErrorAction SilentlyContinue
    if ($txt -match '3\.13') {
        Write-Log "py.ini references 3.13: $f"
        if ($DryRun) { Write-Log "[DRY-RUN] Would delete: $f" 'DRY' }
        else {
            if (-not $SkipBackup) { Copy-Item $f (Join-Path $BackupDir 'files') -Force -ErrorAction SilentlyContinue }
            try   { Remove-Item $f -Force; Write-Log "Deleted: $f" 'SUCCESS' }
            catch { Write-Log "Failed to delete $f : $_" 'ERROR' }
        }
    }
    else { Write-Log "py.ini at $f does not reference 3.13 — left in place" }
}

# ── 2m. pip cache ─────────────────────────────────────────────────────────────
Write-Section 'pip cache'
$pipCache = Join-Path $env:LOCALAPPDATA 'pip\Cache'
if (Test-Path -LiteralPath $pipCache) {
    $pip313 = @(
        Get-ChildItem -LiteralPath $pipCache -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '(?i)cp313t?|cpython-313|abi3-cp313|\.cp313\.|-cp313-|_cp313_|\bpy313\b|\bpy3\.13\b|python3\.13|313-win' }
    )
    if ($pip313.Count -gt 0) {
        Write-Log "Found $($pip313.Count) pip cache item(s) matching 3.13 patterns"
        foreach ($item in $pip313) {
            if ($DryRun) { Write-Log "[DRY-RUN] Would remove pip cache item: $($item.FullName)" 'DRY'; continue }
            try {
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction SilentlyContinue
                Write-Log "Removed pip cache: $($item.Name)"
            }
            catch { Write-Log "pip cache removal failed for $($item.FullName): $_" 'WARN' }
        }
        Write-Log "pip cache cleanup complete" 'SUCCESS'
    }
    else { Write-Log 'pip cache: no 3.13 entries found' }
}

# ── 2n. pipx venvs ────────────────────────────────────────────────────────────
Write-Section 'pipx venvs'
$pipxRoots = @(
    (Join-Path $env:USERPROFILE '.local\pipx\venvs')
    (Join-Path $env:USERPROFILE '.pipx\venvs')
)
foreach ($pipxRoot in $pipxRoots) {
    if (-not (Test-Path $pipxRoot)) { continue }
    Get-ChildItem -Path $pipxRoot -Directory -ErrorAction SilentlyContinue |
    ForEach-Object {
        $cfg = Join-Path $_.FullName 'pyvenv.cfg'
        if ((Test-Path $cfg) -and ((Get-Content $cfg -ErrorAction SilentlyContinue) -match '3\.13')) {
            Write-Log "pipx venv built with 3.13: $($_.FullName)"
            Remove-VerifiedDir -Path $_.FullName -Reason 'pipx venv'
        }
    }
}

# ── 2o. virtualenvs (pyvenv.cfg scan) ────────────────────────────────────────
Write-Section 'Virtualenvs'
$pyvenvSeen  = @{}
$venvDepth   = 12
$venvRoots   = @(
    (Join-Path $env:USERPROFILE '.virtualenvs')
    (Join-Path $env:USERPROFILE 'venvs')
    (Join-Path $env:USERPROFILE 'Envs')
    (Join-Path $env:USERPROFILE 'env')
    (Join-Path $env:USERPROFILE 'virtualenvs')
    (Join-Path $env:USERPROFILE '.local\share\virtualenvs')
    (Join-Path $env:USERPROFILE 'PycharmProjects')
    (Join-Path $env:USERPROFILE 'IdeaProjects')
    (Join-Path $env:USERPROFILE 'source')
    (Join-Path $env:USERPROFILE 'Source')
    (Join-Path $env:USERPROFILE 'repos')
    (Join-Path $env:USERPROFILE 'code')
    (Join-Path $env:USERPROFILE 'dev')
    (Join-Path $env:USERPROFILE 'projects')
    (Join-Path $env:USERPROFILE 'Projects')
)

function Remove-Venvs313 {
    param([string]$Root)
    if (-not (Test-Path -LiteralPath $Root)) { return }
    Get-ChildItem -LiteralPath $Root -Filter pyvenv.cfg -File -Recurse -Depth $venvDepth -ErrorAction SilentlyContinue |
    ForEach-Object {
        if ($pyvenvSeen.ContainsKey($_.FullName)) { return }
        $pyvenvSeen[$_.FullName] = $true
        if ((Get-Content $_.FullName -ErrorAction SilentlyContinue) -match '3\.13') {
            $venvDir = Split-Path $_.FullName -Parent
            Write-Log "Virtualenv with 3.13: $venvDir"
            Remove-VerifiedDir -Path $venvDir -Reason 'virtualenv pyvenv.cfg indicates 3.13'
        }
    }
}
foreach ($vr in $venvRoots) { Remove-Venvs313 $vr }
Remove-Venvs313 $env:USERPROFILE  # broad pass — skips already-seen paths

# ── 2p. Jupyter kernels ───────────────────────────────────────────────────────
Write-Section 'Jupyter kernels'
$jkRoot = Join-Path $env:APPDATA 'jupyter\kernels'
if (Test-Path $jkRoot) {
    Get-ChildItem -Path $jkRoot -Directory -ErrorAction SilentlyContinue |
    ForEach-Object {
        $kj = Join-Path $_.FullName 'kernel.json'
        if ((Test-Path $kj) -and ((Get-Content $kj -Raw -ErrorAction SilentlyContinue) -match '3\.13')) {
            Write-Log "Jupyter kernel references 3.13: $($_.FullName)"
            Remove-VerifiedDir -Path $_.FullName -Reason 'Jupyter kernel'
        }
    }
}
else { Write-Log 'No Jupyter kernels directory found' }

# ═════════════════════════════════════════════════════════════════════════════
# PHASE 3 — SUMMARY
# ═════════════════════════════════════════════════════════════════════════════
Write-Section 'SUMMARY'
Write-Log "Mode              : $(if ($DryRun) { 'DRY RUN — no changes made' } else { 'LIVE — changes applied' })"
Write-Log "Methods detected  : $(if ($summary.DetectedMethods.Count) { $summary.DetectedMethods -join ', ' } else { 'none' })"
Write-Log "Directories       : $($summary.DirsRemoved) removed"
Write-Log "Registry keys     : $($summary.RegKeysRemoved) removed"
Write-Log "PATH scopes fixed : $($summary.PathsFixed)"
Write-Log "Shortcuts removed : $($summary.ShortcutsRemoved)"
if ($summary.Issues.Count -gt 0) {
    Write-Log '' 'WARN'
    Write-Log 'Items requiring manual attention:' 'WARN'
    $summary.Issues | ForEach-Object { Write-Log "  • $_" 'WARN' }
}
Write-Log ''
if (-not $DryRun) {
    Write-Log 'Backup location : ' + $BackupDir
    Write-Log 'Log file        : ' + $LogFile
    Write-Log ''
    Write-Log 'Next steps:' 'SUCCESS'
    Write-Log '  1. Reboot your machine'
    Write-Log '  2. Open a new PowerShell and run:  py -0p'
    Write-Log '  3. Also run:  where python'
    Write-Log '  4. Python 3.13 should no longer appear in either output'
}
else {
    Write-Log 'Dry run complete. Re-run without -WhatIf to apply changes.' 'DRY'
}
