# cld installer for Windows PowerShell / pwsh.
#
# One-liner:
#   irm https://raw.githubusercontent.com/MariuszHenn/cld/main/install.ps1 | iex
#
# From a clone:
#   .\install.ps1              install and patch your $PROFILE
#   .\install.ps1 -NoShell     print the line to add yourself

param([switch]$NoShell)

$ErrorActionPreference = 'Stop'

$repo = if ($env:CLD_REPO) { $env:CLD_REPO } else { 'https://github.com/MariuszHenn/cld' }
$src  = if ($env:CLD_DIR)  { $env:CLD_DIR }
        else { Join-Path (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cld') 'src' }

# Work out where the source is. Two cases:
#   1. you cloned the repo and ran .\install.ps1  -> use the clone you are in
#   2. you piped this script through iex          -> clone the repo first
$root = $null
if ($PSCommandPath) {
    $maybe = Split-Path -Parent $PSCommandPath
    if (Test-Path (Join-Path $maybe 'shell/cld.ps1')) { $root = $maybe }
}
if (-not $root) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'cld: git is required' }
    if (Test-Path (Join-Path $src '.git')) {
        Write-Host "cld: updating $src"
        git -C $src pull --quiet --ff-only 2>$null
    }
    else {
        Write-Host "cld: cloning $repo into $src"
        New-Item -ItemType Directory -Force -Path (Split-Path $src -Parent) | Out-Null
        git clone --quiet --depth 1 $repo $src
    }
    $root = $src
}

$ps1 = Join-Path $root 'shell/cld.ps1'
if (-not (Test-Path $ps1)) { throw "cld: cannot find shell/cld.ps1 under $root" }
$ps1 = (Resolve-Path $ps1).Path

# The path goes into a file PowerShell RUNS, once per session, forever. In a
# double-quoted string a checkout under a directory whose name contains $( )
# would not be a path at all - it would be a command, executed at every prompt
# start. A single-quoted literal expands nothing; '' escapes a quote.
$line = ". '" + $ps1.Replace("'", "''") + "'"

if ($NoShell) {
    Write-Host "Add this line to your PowerShell `$PROFILE:"
    Write-Host "  $line"
}
else {
    $profilePath = if ($PROFILE.CurrentUserAllHosts) { $PROFILE.CurrentUserAllHosts } else { [string]$PROFILE }
    New-Item -ItemType Directory -Force -Path (Split-Path $profilePath -Parent) | Out-Null
    if (-not (Test-Path $profilePath)) { New-Item -ItemType File -Force -Path $profilePath | Out-Null }
    if (Select-String -Path $profilePath -SimpleMatch 'cld.ps1' -Quiet) {
        Write-Host "cld: $profilePath already loads cld, left alone"
    }
    else {
        Add-Content -Path $profilePath -Value "`n# cld - Claude profile manager`n$line"
        Write-Host "cld: added the hook to $profilePath"
    }
}

Write-Host @'

Done. Open a new terminal, then:

  cld list                # your current setup is already here as "default"
  claude                  # sign in once

  cld add work            # a second account
  cld use work
  claude                  # sign in once here too

In any project folder:

  cld rc work             # writes .cldrc, that folder now uses "work"
'@
