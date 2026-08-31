# cld for PowerShell (Windows, and pwsh on macOS/Linux).
# Self-contained: it does not need the POSIX `cld` script.
#
# The installer adds this line to your $PROFILE:
#     . C:\path\to\cld\shell\cld.ps1

$script:CldVersion = '1.0.0'
# Captured while the file is being dot-sourced, when $PSCommandPath is ours.
$script:CldPs1  = $PSCommandPath
$script:CldRoot = Split-Path (Split-Path $PSCommandPath -Parent) -Parent

if (-not $env:CLD_HOME) {
    $env:CLD_HOME = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.cld'
}
$script:CldMarker = '.cldrc'
# $IsWindows does not exist in Windows PowerShell 5.1, where it is always true.
$script:CldIsWindows = ($PSVersionTable.PSEdition -ne 'Core') -or $IsWindows

function Get-CldProfilesDir { Join-Path $env:CLD_HOME 'profiles' }
function Get-CldDefaultFile { Join-Path $env:CLD_HOME 'default' }
function Get-CldProfileDir([string]$Name) { Join-Path (Get-CldProfilesDir) $Name }

# These directories hold account logins. The POSIX build creates them under
# umask 077 and chmod 700s them on every run; inherited ACLs are the Windows
# equivalent only as long as nobody has changed the profile folder, redirected
# it, or pointed CLD_HOME somewhere else. Assert it instead of assuming it.
function Set-CldPrivateAcl([string]$Path) {
    if (-not $script:CldIsWindows) { return }
    try {
        $me  = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        $acl.SetAccessRuleProtection($true, $false)   # drop inheritance, keep nothing
        foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $me, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    }
    catch { Write-Verbose "cld: could not tighten $Path" }
}

function New-CldPrivateDir([string]$Path) {
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    Set-CldPrivateAcl $Path
}

# `cld add` seeds the status line the way the POSIX build does - but only where
# there is an `sh` to run it. bin/cld-statusline is a POSIX shell script, so on
# Windows this would hand every new profile a command that cannot run.
function Set-CldStatusLine([string]$ProfileDir) {
    $dst = Join-Path $ProfileDir 'settings.json'
    if (Test-Path $dst) { return }
    if (-not (Get-Command sh -ErrorAction SilentlyContinue)) { return }
    $sl = Join-Path (Join-Path $script:CldRoot 'bin') 'cld-statusline'
    if (-not (Test-Path -PathType Leaf $sl)) { return }
    # The command is read by `sh`, so the path is single-quoted there; the
    # whole thing is then a JSON string, which ConvertTo-Json escapes.
    $cmd = "sh '" + $sl.Replace("'", "'\''") + "'"
    [pscustomobject]@{ statusLine = [pscustomobject]@{ type = 'command'; command = $cmd } } |
        ConvertTo-Json -Depth 4 | Set-Content -Path $dst
}

function Get-CldProfileItems {
    # -Directory can miss links on some hosts, so ask for everything and filter.
    Get-ChildItem -Force (Get-CldProfilesDir) -ErrorAction SilentlyContinue |
        Where-Object { $_.PSIsContainer -or $_.LinkType }
}

function Test-CldName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name -eq '.' -or $Name -eq '..') { return $false }
    # A leading '-' would look like an option to anything that ever takes the
    # name unquoted. Nothing here does today; this keeps it that way.
    if ($Name.StartsWith('-')) { return $false }
    return $Name -match '^[A-Za-z0-9._-]+$'
}

function Test-CldProfile([string]$Name) {
    (Test-CldName $Name) -and (Test-Path -PathType Container (Get-CldProfileDir $Name))
}

# Delete a profile directory, link-safely.
#
# Windows PowerShell 5.1's `Remove-Item -Recurse` follows a Junction and
# deletes what it points AT. The "default" profile is a Junction to the real
# Claude setup we adopted, so -Recurse there would destroy the very thing cld
# promises never to touch. Delete a link as a link; recurse only into a real
# directory.
function Remove-CldTree([string]$Path) {
    $item = Get-Item -Force -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $item) { return }
    if ($item.LinkType) {
        if ($item.PSIsContainer) { [System.IO.Directory]::Delete($Path, $false) }
        else { [System.IO.File]::Delete($Path) }
        return
    }
    Remove-Item -Recurse -Force -LiteralPath $Path
}

function Get-CldDefault {
    $f = Get-CldDefaultFile
    if (-not (Test-Path $f)) { return $null }
    $name = Get-Content $f -TotalCount 1 -ErrorAction SilentlyContinue
    if ($null -eq $name) { return $null }
    $name = $name.Trim()
    if (Test-CldProfile $name) { return $name }
    return $null
}

# There must always be a default. If the current one is gone, adopt the first
# profile we can find.
function Repair-CldDefault {
    if (Get-CldDefault) { return }
    $first = Get-CldProfileItems | Select-Object -First 1
    if ($first) { Set-Content -Path (Get-CldDefaultFile) -Value $first.Name }
    else { Remove-Item (Get-CldDefaultFile) -ErrorAction SilentlyContinue }
}

# First run: adopt the Claude setup you already have as a profile called
# "default", by linking to it.
#
# One wrinkle: without CLAUDE_CONFIG_DIR, Claude keeps its main config at
# ~/.claude.json, OUTSIDE ~/.claude. With CLAUDE_CONFIG_DIR set it looks for
# <dir>\.claude.json instead. So we link that file in too, or the adopted
# profile would start with no MCP servers.
#
# Windows note: a directory Junction and a file HardLink both work without
# admin rights. A plain symlink does not, so it is only the fallback.
function Invoke-CldBootstrap {
    # The sentinel is the profiles directory, NOT $env:CLD_HOME. The installer
    # clones the source into $CLD_HOME\src, so $CLD_HOME exists beforehand.
    # Tighten once per session, before the early return: an install that
    # predates this, or a CLD_HOME the installer made first, would keep
    # whatever ACL it was born with forever otherwise.
    if (-not $script:CldHardened) {
        $script:CldHardened = $true
        if (Test-Path $env:CLD_HOME)        { Set-CldPrivateAcl $env:CLD_HOME }
        if (Test-Path (Get-CldProfilesDir)) { Set-CldPrivateAcl (Get-CldProfilesDir) }
    }
    if (Test-Path (Get-CldProfilesDir)) { return }
    New-CldPrivateDir $env:CLD_HOME
    New-CldPrivateDir (Get-CldProfilesDir)

    $existing = if ($env:CLD_ADOPT) { $env:CLD_ADOPT }
                elseif ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR }
                else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude' }

    $target = Get-CldProfileDir 'default'
    $linked = $false
    if (Test-Path -PathType Container $existing) {
        # Try each link type and CHECK the result. On a non-Windows host
        # New-Item -ItemType Junction reports success but creates nothing.
        foreach ($kind in 'Junction', 'SymbolicLink') {
            try { New-Item -ItemType $kind -Path $target -Target $existing -ErrorAction Stop | Out-Null } catch { }
            if (Test-Path -PathType Container $target) { $linked = $true; break }
        }
    }
    if (-not $linked) { New-CldPrivateDir $target }
    Set-Content -Path (Get-CldDefaultFile) -Value 'default'

    if ($linked) {
        $inner = Join-Path $existing '.claude.json'
        $outer = if ($env:CLD_ADOPT_JSON) { $env:CLD_ADOPT_JSON }
                 else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.claude.json' }
        if ((-not (Test-Path $inner)) -and (Test-Path $outer)) {
            try { New-Item -ItemType HardLink -Path $inner -Target $outer -ErrorAction Stop | Out-Null }
            catch { Copy-Item $outer $inner -ErrorAction SilentlyContinue }
        }
    }

    Write-Host 'cld: first run. Your current Claude setup is now the "default" profile.'
    if ($linked) {
        Write-Host "cld: it points at $existing. Nothing was copied or moved."
        Write-Host 'cld: settings, skills and MCP servers carry over. The login does not:'
        Write-Host 'cld: Claude keys credentials to the config directory. Run claude once'
        Write-Host 'cld: and sign in. You do this once per profile.'
    }
    else { Write-Host "cld: $existing was not usable, so 'default' starts empty." }
}

# Text that came from outside cld, on its way to your terminal. Control
# characters are escape sequences: a .cldrc out of a repo you cloned must not
# be able to clear your screen or repaint the line that says which account
# you are on. This one runs from the prompt hook, on every prompt.
function Format-CldSafe([string]$Text) {
    if (-not $Text) { return $Text }
    $t = $Text -replace '[\x00-\x1f\x7f]', ''
    if ($t.Length -gt 200) { $t = $t.Substring(0, 200) }
    return $t
}

function Read-CldMarker([string]$Path) {
    # A bounded read, for the reason the POSIX build caps it: this runs on
    # every cd, and Get-Content on a .cldrc that is one huge line reads the
    # whole thing into memory. No profile name is anywhere near 4096 chars.
    $head = ''
    try {
        $sr = [System.IO.StreamReader]::new((Convert-Path -LiteralPath $Path))
        $buf = [char[]]::new(4096)
        $n = $sr.Read($buf, 0, $buf.Length)
        if ($n -gt 0) { $head = [string]::new($buf, 0, $n) }
    }
    catch { return $null }
    finally { if ($sr) { $sr.Dispose() } }
    foreach ($line in ($head -split "\r?\n")) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        return (Format-CldSafe $t)
    }
    return $null
}

# Somebody else's file is not your configuration, and neither is a file in
# somebody else's directory: whoever owns the directory can replace what is in
# it. On a shared machine anyone can drop a .cldrc into a world-writable folder
# you work in.
#
# Owners are compared as SIDs. The display-name form varies (DOMAIN\user, a
# raw SID, a renamed account), so string-comparing names both misses matches
# and invents them. Where there is no ownership model to read at all, do not
# block; where there is one and reading it fails, do.
function Test-CldMarkerMine([string]$Path) {
    # A symlink is not the file you tested: the checks below would follow it
    # to a file you happen to own. That is true on every platform, so it runs
    # BEFORE the Windows-only ownership check - otherwise pwsh on macOS and
    # Linux accepts a symlinked .cldrc the POSIX build refuses.
    try {
        $item = Get-Item -Force -LiteralPath $Path -ErrorAction Stop
        if ($item.LinkType) { return $false }
    }
    catch { return $false }
    # Owner comparison is Windows-only: there is no cross-platform owner API
    # here. On pwsh under macOS/Linux a .cldrc somebody else owns is still
    # accepted - use the POSIX build there, which checks it.
    if (-not $script:CldIsWindows) { return $true }
    try {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User
        foreach ($p in @($Path, (Split-Path -Parent $Path))) {
            $owner = (Get-Acl -LiteralPath $p -ErrorAction Stop).GetOwner(
                [Security.Principal.SecurityIdentifier])
            if ($owner -ne $me) { return $false }
        }
        return $true
    }
    catch { return $false }
}

# -MarkerOnly returns what a .cldrc says, with no fallback to the default.
#
# The marker is read from $Dir ONLY: cld does not walk up. A .cldrc governs
# the folder it sits in, so nothing you merely happen to be working under
# can quietly choose which account you use.
function Resolve-CldProfile([string]$Dir = $PWD.Path, [switch]$MarkerOnly) {
    try { $d = (Get-Item -LiteralPath $Dir -ErrorAction Stop).FullName }
    catch { if ($MarkerOnly) { return $null } else { return Get-CldDefault } }

    $marker = Join-Path $d $script:CldMarker
    if ((Test-Path -PathType Leaf $marker) -and (Test-CldMarkerMine $marker)) {
        $name = Read-CldMarker $marker
        if ($name) {
            if (Test-CldProfile $name) { return $name }
            Write-Warning "cld: $(Format-CldSafe $marker) wants profile '$name', which does not exist"
        }
    }
    if ($MarkerOnly) { return $null }
    return Get-CldDefault
}

function Set-CldActive([string]$Name) {
    if (-not $Name) { return $false }
    # Validate here too, not just in Test-CldProfile: `cld use` reaches this
    # directly, and Join-Path would happily build ...\profiles\..\..\elsewhere.
    if (-not (Test-CldName $Name)) {
        Write-Error "cld: invalid profile name: $(Format-CldSafe $Name) (allowed: letters, digits, . _ -)"
        return $false
    }
    $target = Get-CldProfileDir $Name
    if (-not (Test-Path -PathType Container $target)) {
        Write-Error "cld: no such profile: $Name (make it with: cld add $Name)"
        return $false
    }
    if ($env:CLAUDE_CONFIG_DIR -ne $target) {
        $env:CLAUDE_CONFIG_DIR = $target
        # Which account you are on, changing under you, is never noise. There
        # is no way to silence this: a folder switching your account without
        # saying so is the one thing cld must not do.
        Write-Host "cld: profile $Name" -ForegroundColor DarkGray
    }
    $env:CLD_PROFILE = $Name
    return $true
}

function Invoke-CldAuto {
    # Only when the directory actually changed. This runs from the prompt, so
    # "this .cldrc is not trusted" must not print once per keystroke.
    if ($script:CldLastPwd -eq $PWD.Path) { return }
    $script:CldLastPwd = $PWD.Path
    Invoke-CldBootstrap
    # A trusted .cldrc ALWAYS wins: entering a folder that has one switches
    # you, even if you picked a profile by hand. With no .cldrc, your
    # hand-picked profile is left alone; only a shell that has never chosen
    # anything falls back to the default.
    $marker = Resolve-CldProfile $PWD.Path -MarkerOnly
    if ($marker) { [void](Set-CldActive $marker) }
    elseif (-not $env:CLD_PROFILE) { [void](Set-CldActive (Resolve-CldProfile $PWD.Path)) }
}

function Show-CldUsage {
@'
cld - one Claude Code account per terminal, and per project.

Put a .cldrc file in a project holding one profile name, and every terminal
in that folder uses that account. It applies to that folder itself, not to
what is under it. Run claude as usual.

  cld list                  Show all profiles. * is this terminal
  cld add <name>            Create a profile
  cld use <name>            Switch this terminal to a profile
  cld rc <name> [dir]       Make a folder always use that profile
  cld move <old> <new>      Rename a profile
  cld remove <name>         Delete a profile (needs -Force)
  cld uninstall             Remove cld and put your Claude setup back
'@ | Write-Host
}

# help doubles as status: the command list, then what is active here and
# where everything lives. The profile list is `cld list`, not this.
function Show-CldHelp {
    Show-CldUsage
    $here = if ($env:CLD_PROFILE) { $env:CLD_PROFILE }
            else {
                $n = Resolve-CldProfile $PWD.Path
                if ($n) { "$n (not active in this shell yet)" } else { '<none>' }
            }
    $ccd = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { '<unset>' }
    # Show where it really goes, the same way `cld list` does, so a linked
    # profile does not look like two different places.
    if ($env:CLAUDE_CONFIG_DIR) {
        $i = Get-Item -Force $env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
        if ($i -and $i.LinkType) { $ccd = "$ccd -> $($i.Target | Select-Object -First 1)" }
    }
    Write-Host ''
    Write-Host "active here       $here"
    Write-Host "CLAUDE_CONFIG_DIR $ccd"
    Write-Host ''
    Write-Host "profiles stored   $(Get-CldProfilesDir)"
    Write-Host "default profile   $(Get-CldDefault)"
    Write-Host "cld version       $script:CldVersion"
}

function cld {
    # Note: the parameter is NOT called $Args. That is an automatic PowerShell
    # variable, and using the name here silently swallows every argument.
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CldArgs)

    Invoke-CldBootstrap
    $cmd = if ($CldArgs -and $CldArgs.Count -gt 0) { $CldArgs[0] } else { 'help' }
    # The @( ) must wrap the WHOLE if, not the value inside it. PowerShell
    # unrolls a one-element array on its way out of an if, so a single argument
    # would arrive as a plain string and $rest[0] would return its first LETTER.
    $rest = @(if ($CldArgs -and $CldArgs.Count -gt 1) { $CldArgs[1..($CldArgs.Count - 1)] })

    switch ($cmd) {
        'use' {
            if ($rest.Count -lt 1) { Write-Error 'cld: usage: cld use <name>'; return }
            [void](Set-CldActive $rest[0])
        }
        'add' {
            if ($rest.Count -lt 1) { Write-Error 'cld: usage: cld add <name>'; return }
            $name = $rest[0]
            if (-not (Test-CldName $name)) { Write-Error "cld: invalid profile name: $name"; return }
            if (Test-CldProfile $name) { Write-Host "cld: profile $name already exists"; return }
            New-CldPrivateDir (Get-CldProfileDir $name)
            Set-CldStatusLine (Get-CldProfileDir $name)
            Repair-CldDefault
            Write-Host "cld: created profile $name"
            Write-Host "cld: use it with:  cld use $name   then run claude and sign in"
        }
        'rc' {
            if ($rest.Count -lt 1) { Write-Error 'cld: usage: cld rc <name> [dir]'; return }
            if (-not (Test-CldProfile $rest[0])) { Write-Error "cld: no such profile: $($rest[0]) (make it with: cld add $($rest[0]))"; return }
            $target = if ($rest.Count -ge 2) { $rest[1] } else { $PWD.Path }
            if (-not (Test-Path -PathType Container $target)) { Write-Error "cld: not a directory: $target"; return }
            $file = Join-Path $target $script:CldMarker
            # Set-Content follows a link and truncates its target, and a
            # symlinked .cldrc is ignored on read anyway.
            $existing = Get-Item -Force -LiteralPath $file -ErrorAction SilentlyContinue
            if ($existing -and $existing.LinkType) {
                Write-Error "cld: $file is a symlink; refusing to write through it"; return
            }
            Set-Content -LiteralPath $file -Value $rest[0]
            $script:CldLastPwd = $null   # so the next prompt re-reads this folder
            Write-Host "cld: $target now uses profile $($rest[0])"
            Write-Host "cld: wrote $file"
        }
        'list' {
            $default = Get-CldDefault
            $any = $false
            foreach ($p in (Get-CldProfileItems)) {
                $any = $true
                $mark = if ($p.Name -eq $env:CLD_PROFILE) { '* ' } else { '  ' }
                $suffix = if ($p.Name -eq $default) { ' (default)' } else { '' }
                $link = if ($p.LinkType) { " -> $($p.Target | Select-Object -First 1)" } else { '' }
                Write-Output "$mark$($p.Name)$suffix$link"
            }
            if (-not $any) { Write-Host 'cld: no profiles yet. Make one with: cld add work' }
        }
        'move' {
            if ($rest.Count -lt 2) { Write-Error 'cld: usage: cld move <old> <new>'; return }
            $old = $rest[0]; $new = $rest[1]
            if (-not (Test-CldProfile $old)) { Write-Error "cld: no such profile: $old"; return }
            if (-not (Test-CldName $new))    { Write-Error "cld: invalid profile name: $new"; return }
            if ($old -eq $new) { Write-Host "cld: $old is already called that"; return }
            if (Test-CldProfile $new) { Write-Error "cld: a profile called $new already exists"; return }
            Move-Item (Get-CldProfileDir $old) (Get-CldProfileDir $new)
            if ((Get-CldDefault) -eq $old -or -not (Get-CldDefault)) {
                Set-Content -Path (Get-CldDefaultFile) -Value $new
            }
            Repair-CldDefault
            if ($env:CLD_PROFILE -eq $old) { [void](Set-CldActive $new) }
            Write-Host "cld: moved $old to $new"
            Write-Warning "cld: any $($script:CldMarker) that says '$old' now points at nothing"
        }
        'remove' {
            if ($rest.Count -lt 1) { Write-Error 'cld: usage: cld remove <name>'; return }
            $name = $rest[0]
            if (-not (Test-CldProfile $name)) { Write-Error "cld: no such profile: $name"; return }
            if ($rest -notcontains '-Force') {
                Write-Warning "cld: this deletes $(Get-CldProfileDir $name), including that account login."
                Write-Warning 'cld: re-run as: cld remove <name> -Force'
                return
            }
            Remove-CldTree (Get-CldProfileDir $name)
            Write-Host "cld: removed profile $name"
            Repair-CldDefault
        }
        'uninstall' {
            $script = Join-Path $script:CldRoot 'uninstall.ps1'
            if (-not (Test-Path $script)) { Write-Error "cld: cannot find $script"; return }
            & $script @rest
        }
        # used by the shell integration and the tests, not advertised
        'resolve' {
            $markerOnly = $rest -contains '--marker'
            $d = @($rest | Where-Object { $_ -ne '--marker' })
            $d = if ($d.Count -ge 1) { $d[0] } else { $PWD.Path }
            $n = Resolve-CldProfile $d -MarkerOnly:$markerOnly
            if ($n) { Write-Output $n }
        }
        'dir' {
            $name = if ($rest.Count -ge 1) { $rest[0] } else { Resolve-CldProfile $PWD.Path }
            if (-not $name) { return }
            if (-not (Test-CldProfile $name)) { Write-Error "cld: no such profile: $name"; return }
            Write-Output (Get-CldProfileDir $name)
        }
        { $_ -in 'version', '--version', '-v' } { Write-Output $script:CldVersion }
        { $_ -in 'help', '--help', '-h' } { Show-CldHelp }
        default { Show-CldUsage }
    }
}

# Switch on directory change, by hooking the prompt.
if (-not $script:CldPromptHooked) {
    $script:CldPromptHooked = $true
    $script:CldOldPrompt = $function:prompt
    function global:prompt {
        Invoke-CldAuto
        if ($script:CldOldPrompt) { & $script:CldOldPrompt } else { "PS $($PWD.Path)> " }
    }
}

Invoke-CldAuto
