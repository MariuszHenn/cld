# cld uninstaller for Windows PowerShell / pwsh.
#
#   .\uninstall.ps1            remove cld, keep your profiles
#   .\uninstall.ps1 -Purge     also delete ~/.cld and every profile in it
#
# This never deletes the Claude setup you had before cld. The "default"
# profile is a link to it, and removing a link does not touch the target.
param([switch]$Purge)

$ErrorActionPreference = 'Stop'
$home_ = [Environment]::GetFolderPath('UserProfile')
$cldHome = if ($env:CLD_HOME) { $env:CLD_HOME } else { Join-Path $home_ '.cld' }

function Say($m) { Write-Host "cld: $m" }

# 1. take the loader line out of the PowerShell profile
foreach ($p in @($PROFILE.CurrentUserAllHosts, $PROFILE.CurrentUserCurrentHost) | Select-Object -Unique) {
    if (-not $p -or -not (Test-Path $p)) { continue }
    if (-not (Select-String -Path $p -SimpleMatch 'cld.ps1' -Quiet)) { continue }
    Copy-Item $p "$p.cld-backup" -Force
    (Get-Content $p) |
        Where-Object { $_ -notmatch 'cld\.ps1' -and $_ -notmatch '^\s*#\s*cld - Claude account manager\s*$' } |
        Set-Content $p
    Say "removed the loader from $p (backup: $p.cld-backup)"
}

# 2. put the adopted setup back the way it was
#    On first run cld linked <adopted>\.claude.json to ~\.claude.json, because
#    Claude looks in a different place once CLAUDE_CONFIG_DIR is set.
$defaultLink = Join-Path (Join-Path $cldHome 'profiles') 'default'
if (Test-Path $defaultLink) {
    $item = Get-Item $defaultLink -Force
    if ($item.LinkType) {
        $adopted = $item.Target | Select-Object -First 1
        $inner = Join-Path $adopted '.claude.json'
        if (Test-Path $inner) {
            $innerItem = Get-Item $inner -Force
            if ($innerItem.LinkType -eq 'HardLink') {
                Remove-Item $inner -Force
                Say "removed the helper link $inner"
            }
            else {
                Say "left $inner alone: it is a real file, not our link"
            }
        }
    }
}

# 3. profiles
if ($Purge) {
    if (Test-Path $cldHome) {
        # Take every profile link out as a link FIRST. Windows PowerShell 5.1's
        # Remove-Item -Recurse follows a Junction and deletes what it points at,
        # and "default" points at the real Claude setup we adopted.
        $profilesDir = Join-Path $cldHome 'profiles'
        if (Test-Path $profilesDir) {
            foreach ($p in @(Get-ChildItem -Force $profilesDir -ErrorAction SilentlyContinue |
                             Where-Object { $_.LinkType })) {
                if ($p.PSIsContainer) { [System.IO.Directory]::Delete($p.FullName, $false) }
                else { [System.IO.File]::Delete($p.FullName) }
                Say "unlinked $($p.Name) (its target is untouched)"
            }
        }
        Remove-Item -Recurse -Force $cldHome
        Say "deleted $cldHome and every profile in it"
        Say 'NOTE the accounts you logged in with are gone. Your original setup is not.'
    }
}
elseif (Test-Path $cldHome) {
    Say "kept your profiles in $cldHome"
    Say "delete them later with: Remove-Item -Recurse -Force '$cldHome'"
}

# 4. clear this session
Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
Remove-Item Env:CLD_PROFILE       -ErrorAction SilentlyContinue
Remove-Item Env:CLD_PINNED        -ErrorAction SilentlyContinue

Write-Host @'

cld is uninstalled.

Open a new terminal. CLAUDE_CONFIG_DIR is no longer set, so `claude` uses your
original setup again, exactly as before you installed cld.
'@
