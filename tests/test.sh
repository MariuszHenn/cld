#!/usr/bin/env bash
# Tests for cld. They run in a throwaway CLD_HOME against a fake adopted
# setup, and never touch your real profiles, your real $HOME, or your shell
# config. Any shell that is not installed is skipped.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CLD="$ROOT/bin/cld"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export CLD_HOME="$TMP/cldhome"
# Adopt a fake Claude setup, so the tests never touch the real ~/.claude.
mkdir -p "$TMP/fake-claude"
printf '{"mcpServers":{}}\n' > "$TMP/fake-outer.json"
export CLD_ADOPT="$TMP/fake-claude"
export CLD_ADOPT_JSON="$TMP/fake-outer.json"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; }
eq()   { [ "$2" = "$3" ] && ok "$1" || bad "$1" "$2" "$3"; }
# has <needle> <haystack> -> yes/no. Kept as a function because a `case`
# inside "$( ... )" confuses bash's quote parser.
has()  { case "$2" in *"$1"*) echo yes ;; *) echo "no ($2)" ;; esac; }
yn()   { [ -e "$1" ] && echo yes || echo no; }
mode() { ls -ld "$1" 2>/dev/null | cut -c1-10; }

echo "cld tests (CLD_HOME=$CLD_HOME)"

# --- first run -------------------------------------------------------------
# Regression: the installer clones into $CLD_HOME/src, so $CLD_HOME exists
# before cld ever runs. Adoption must still happen.
mkdir -p "$CLD_HOME/src"
eq "adopts even though CLD_HOME already exists" "default" "$("$CLD" resolve "$TMP" 2>/dev/null)"
eq "adopts the existing setup as 'default'" "yes" "$([ -L "$CLD_HOME/profiles/default" ] && echo yes || echo no)"
eq "the link points at the adopted dir" "$TMP/fake-claude" "$(readlink "$CLD_HOME/profiles/default")"
eq "links the outer .claude.json in" "$TMP/fake-outer.json" "$(readlink "$TMP/fake-claude/.claude.json")"

# --- add -------------------------------------------------------------------
"$CLD" add work     >/dev/null
"$CLD" add personal >/dev/null
eq "add creates the profile dir" "yes" "$(yn "$CLD_HOME/profiles/work")"
eq "adding does not steal the default" "default" "$("$CLD" resolve "$TMP" 2>/dev/null)"
out="$("$CLD" add work)"
eq "adding twice is a no-op" "yes" "$(has "already exists" "$out")"
rc=0; out="$("$CLD" add 'bad name' 2>&1)" || rc=$?
eq "rejects an invalid name" "1" "$rc"
eq "and says why" "yes" "$(has "invalid" "$out")"
# A name that starts with '-' looks like an option to anything that ever takes
# it unquoted.
rc=0; "$CLD" add -- >/dev/null 2>&1 || rc=$?
eq "rejects a leading-dash name" "1" "$rc"

eq "add seeds a status line" "yes" \
   "$(has "$ROOT/bin/cld-statusline" "$(cat "$CLD_HOME/profiles/personal/settings.json" 2>/dev/null)")"

eq "a new profile is private"   "drwx------" "$(mode "$CLD_HOME/profiles/work")"
eq "the profiles dir is private" "drwx------" "$(mode "$CLD_HOME/profiles")"
eq "CLD_HOME itself is private"  "drwx------" "$(mode "$CLD_HOME")"

# umask only applies while CREATING. An install that predates the hardening,
# or a CLD_HOME the installer made first, must get tightened on the next run.
LOOSE="$TMP/loose"
mkdir -p "$LOOSE/profiles"
chmod 755 "$LOOSE" "$LOOSE/profiles"
CLD_HOME="$LOOSE" CLD_ADOPT="$TMP/fake-claude" "$CLD" add w >/dev/null 2>&1
eq "tightens an already-loose profiles dir" "drwx------" "$(mode "$LOOSE/profiles")"
eq "tightens an already-loose CLD_HOME"     "drwx------" "$(mode "$LOOSE")"

eq "list shows all three" "3" "$("$CLD" list | grep -c .)"
eq "list marks the default" "yes" "$(has "default (default)" "$("$CLD" list)")"
eq "list shows the link target" "yes" "$(has "-> $TMP/fake-claude" "$("$CLD" list)")"
eq "list is just names, no state" "0" "$("$CLD" list | grep -c '\[')"
eq "help resolves a linked CLAUDE_CONFIG_DIR, like list" "yes" \
   "$(has "-> $TMP/fake-claude" "$(CLAUDE_CONFIG_DIR="$CLD_HOME/profiles/default" "$CLD" help 2>/dev/null)")"

# --- rc and resolve --------------------------------------------------------
mkdir -p "$TMP/proj/sub/deep" "$TMP/other"
eq "no .cldrc -> the default" "default" "$("$CLD" resolve "$TMP/other")"

"$CLD" rc personal "$TMP/proj" >/dev/null
eq "rc writes .cldrc" "personal" "$(cat "$TMP/proj/.cldrc")"
eq "resolve reads .cldrc" "personal" "$("$CLD" resolve "$TMP/proj")"
rc=0; "$CLD" rc ghost "$TMP/other" >/dev/null 2>&1 || rc=$?
eq "rc refuses an unknown profile" "1" "$rc"

printf '# a comment\n\n   work  \n' > "$TMP/proj/sub/.cldrc"
eq "skips comments and blank lines" "work" "$("$CLD" resolve "$TMP/proj/sub")"

# A .cldrc governs its OWN folder, nothing under it. Otherwise a .cldrc left
# anywhere you happen to work beneath - /tmp, $HOME, / - picks your account.
eq "does not walk up into a subdir"    "default" "$("$CLD" resolve "$TMP/proj/sub/deep")"
eq "the parent's .cldrc does not leak" "default" "$("$CLD" resolve "$TMP/proj/sub/deep")"

# A marker somebody else owns is not your configuration.
if [ "$(id -u)" = "0" ]; then
  echo "  skip foreign-owned .cldrc (running as root owns everything)"
else
  mkdir -p "$TMP/foreign"
  printf 'work\n' > "$TMP/foreign/.cldrc"
  if chown 65534 "$TMP/foreign/.cldrc" 2>/dev/null; then
    eq "ignores a .cldrc owned by somebody else" "default" \
       "$("$CLD" resolve "$TMP/foreign" 2>/dev/null)"
    eq "and says why" "yes" "$(has "not owned by you" "$("$CLD" resolve "$TMP/foreign" 2>&1)")"
    rm -f "$TMP/foreign/.cldrc"
  else
    echo "  skip foreign-owned .cldrc (cannot chown without privileges)"
  fi
fi

# Both -f and -O follow a symlink, so an ownership test on the link's TARGET
# says nothing about who controls the link. Anyone who can write the directory
# can point .cldrc at a file you happen to own.
mkdir -p "$TMP/linkrc"
ln -s "$TMP/proj/.cldrc" "$TMP/linkrc/.cldrc"
eq "ignores a symlinked .cldrc" "default" "$("$CLD" resolve "$TMP/linkrc" 2>/dev/null)"
eq "and says why"               "yes"     "$(has "is a symlink" "$("$CLD" resolve "$TMP/linkrc" 2>&1)")"
rm -rf "$TMP/linkrc"

# Refusing to READ a symlinked .cldrc is only half of it: `>` follows a link
# and truncates whatever is on the far end. A repo can ship a .cldrc symlink,
# git stores those.
mkdir -p "$TMP/rclink"
printf 'REAL CONTENT\n' > "$TMP/rcvictim"
ln -s "$TMP/rcvictim" "$TMP/rclink/.cldrc"
rc=0; out="$("$CLD" rc work "$TMP/rclink" 2>&1)" || rc=$?
eq "rc refuses to write through a symlinked .cldrc" "1" "$rc"
eq "and says why"                     "yes"          "$(has "is a symlink" "$out")"
eq "and the link target is untouched" "REAL CONTENT" "$(cat "$TMP/rcvictim")"
rm -rf "$TMP/rclink" "$TMP/rcvictim"

# read_marker runs on every cd. Unbounded, a .cldrc that is one huge line is
# read into memory in full: 200MB of it cost 26s and 1GB of RSS, with the
# shell blocked throughout.
mkdir -p "$TMP/bigrc"
head -c 64000000 /dev/zero | tr '\0' 'a' > "$TMP/bigrc/.cldrc"
start=$(date +%s)
"$CLD" resolve --marker "$TMP/bigrc" >/dev/null 2>&1
eq "a huge single-line .cldrc does not stall the shell" "yes" \
   "$([ $(( $(date +%s) - start )) -lt 3 ] && echo yes || echo no)"
rm -rf "$TMP/bigrc"

# A file in a directory you do not own is not yours either: whoever owns the
# directory can replace what is in it.
if [ "$(id -u)" != "0" ]; then
  mkdir -p "$TMP/foreigndir"
  printf 'work\n' > "$TMP/foreigndir/.cldrc"
  if chown 65534 "$TMP/foreigndir" 2>/dev/null; then
    eq "ignores a .cldrc in somebody else's directory" "default" \
       "$("$CLD" resolve "$TMP/foreigndir" 2>/dev/null)"
    chown "$(id -u)" "$TMP/foreigndir" 2>/dev/null || true
  else
    echo "  skip foreign-owned directory (cannot chown without privileges)"
  fi
  rm -rf "$TMP/foreigndir"
fi

# A .cldrc comes out of whatever repo you cloned. It must not be able to
# repaint your terminal on its way into an error message.
ESC="$(printf '\033')"
printf '%s[2J%s[H%s]0;PWNED\007fake\n' "$ESC" "$ESC" "$ESC" > "$TMP/other/.cldrc"
raw="$("$CLD" resolve "$TMP/other" 2>&1)"
eq "a hostile .cldrc cannot clear the screen" "0" "$(printf '%s' "$raw" | grep -c "$ESC\[2J")"
eq "a hostile .cldrc cannot set the title"    "0" "$(printf '%s' "$raw" | grep -c "$ESC]0;")"
eq "and it still falls back to the default"   "default" "$("$CLD" resolve "$TMP/other" 2>/dev/null)"
rm -f "$TMP/other/.cldrc"

eq "resolve --marker: nothing when no .cldrc" "" "$("$CLD" resolve --marker "$TMP/other" 2>/dev/null)"
eq "resolve --marker: the name when there is one" "personal" "$("$CLD" resolve --marker "$TMP/proj" 2>/dev/null)"

printf 'ghost\n' > "$TMP/other/.cldrc"
out="$("$CLD" resolve "$TMP/other" 2>&1)"
eq "unknown profile warns" "yes" "$(has "does not exist" "$out")"
eq "unknown profile falls back to the default" "default" "$("$CLD" resolve "$TMP/other" 2>/dev/null)"
eq "unknown profile is not invented by --marker" "" "$("$CLD" resolve --marker "$TMP/other" 2>/dev/null)"
rm -f "$TMP/other/.cldrc"

# --- move ----------------------------------------------------------------
"$CLD" add temp >/dev/null
"$CLD" move temp renamed >/dev/null 2>&1
eq "move renames the profile"   "yes" "$(yn "$CLD_HOME/profiles/renamed")"
eq "move leaves nothing behind" "no"  "$(yn "$CLD_HOME/profiles/temp")"
rc=0; "$CLD" move renamed work >/dev/null 2>&1 || rc=$?
eq "move refuses an existing name" "1" "$rc"
rc=0; "$CLD" move ghost other >/dev/null 2>&1 || rc=$?
eq "move refuses an unknown profile" "1" "$rc"

# --- remove, and the default is never lost ---------------------------------
rc=0; out="$("$CLD" remove renamed 2>&1)" || rc=$?
eq "remove refuses without CLD_YES" "1" "$rc"
eq "the profile survives the refusal" "yes" "$(yn "$CLD_HOME/profiles/renamed")"
CLD_YES=1 "$CLD" remove renamed >/dev/null
eq "remove deletes with CLD_YES=1" "no" "$(yn "$CLD_HOME/profiles/renamed")"

# A profile name with path traversal must not escape the profiles dir.
mkdir -p "$TMP/outside"
rc=0; out="$(CLD_YES=1 "$CLD" remove ../../outside 2>&1)" || rc=$?
eq "remove rejects a traversal name" "1" "$rc"
eq "and the outside dir is untouched" "yes" "$(yn "$TMP/outside")"
rc=0; "$CLD" rc ../../outside "$TMP/other" >/dev/null 2>&1 || rc=$?
eq "rc rejects a traversal name" "1" "$rc"

CLD_YES=1 "$CLD" remove default >/dev/null 2>&1
eq "removing the default promotes another" "yes" \
   "$([ -n "$("$CLD" resolve "$TMP" 2>/dev/null)" ] && echo yes || echo no)"
eq "removing a linked profile keeps the real dir" "yes" "$(yn "$TMP/fake-claude")"
eq "the adopted config file survives"             "yes" "$(yn "$TMP/fake-outer.json")"

# --- help doubles as status ----------------------------------------------
eq "help lists the commands" "yes" "$(has "cld use <name>" "$("$CLD" help)")"
eq "help shows where profiles live" "yes" \
   "$(has "profiles stored   $CLD_HOME/profiles" "$("$CLD" help)")"
eq "help does not list the profiles" "0" \
   "$("$CLD" help 2>/dev/null | grep -c '(default)')"

# --- the trimmed surface ---------------------------------------------------
# Every alias is gone too: an undocumented command is a trap.
for gone in login auto run config current default hook pin ls rm mv set rename status trust; do
  rc=0; "$CLD" "$gone" >/dev/null 2>&1 || rc=$?
  eq "'cld $gone' is gone" "1" "$rc"
done
rc=0; "$CLD" use work >/dev/null 2>&1 || rc=$?
eq "bare 'cld use' says it needs the shell hook" "1" "$rc"
eq "and says how to get it" "yes" "$(has "install.sh" "$("$CLD" use work 2>&1)")"

# --- reached through a symlink ---------------------------------------------
# The installer puts a symlink on your PATH, so $0 is the link, not the script.
# repo_root() must still walk back to the real script: the seeded status line
# and `cld uninstall` both depend on it.
mkdir -p "$TMP/fakebin"
ln -sf "$CLD" "$TMP/fakebin/cld"
"$TMP/fakebin/cld" add viasymlink >/dev/null 2>&1
eq "via a symlink: repo_root finds the real source" "yes" \
   "$(has "$ROOT/bin/cld-statusline" "$(cat "$CLD_HOME/profiles/viasymlink/settings.json" 2>/dev/null)")"
CLD_YES=1 "$CLD" remove viasymlink >/dev/null 2>&1
eq "via a symlink: uninstall.sh is where cld looks for it" "yes" "$(yn "$ROOT/uninstall.sh")"

# --- a checkout under a hostile path ---------------------------------------
# The seeded status line is a shell command inside a JSON string, so a path
# with a quote in it must break out of neither. This one would create PWNED.
INJ="$TMP/re'po \$(touch \"$TMP/PWNED\")"
mkdir -p "$INJ/bin"
cp "$ROOT/bin/cld" "$ROOT/bin/cld-statusline" "$INJ/bin/"
CLD_HOME="$TMP/injhome" CLD_ADOPT="$TMP/no-such" "$INJ/bin/cld" add demo >/dev/null 2>&1
seeded="$(sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' \
  "$TMP/injhome/profiles/demo/settings.json" | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g')"
sl_out="$(printf '{"display_name":"M","cwd":"/tmp"}' | sh -c "$seeded" 2>/dev/null)"
eq "a quoted path still runs the status line" "yes" "$(has "M" "$sl_out")"
eq "and executes nothing it should not"       "no"  "$(yn "$TMP/PWNED")"

# --- a hostile repo cannot forge the status line ---------------------------
# The line exists to say which account you are on, so text from a repo you
# cd into must never be able to repaint it.
mkdir -p "$TMP/hostile/.git"
printf 'ref: refs/heads/main\033[2J\033[Hnot-your-account' > "$TMP/hostile/.git/HEAD"
raw="$(printf '{"display_name":"M","current_dir":"%s"}' "$TMP/hostile" \
  | sh "$ROOT/bin/cld-statusline" 2>/dev/null)"
eq "a hostile git HEAD cannot clear the line" "0" \
   "$(printf '%s' "$raw" | grep -c "$(printf '\033')\[2J")"

# --- shell integrations ----------------------------------------------------
# Paths go through the environment, never pasted into a shell string: this
# repo can live under a path containing "&".
#
# The contract: a .cldrc ALWAYS wins on cd. With no .cldrc, a profile you
# picked by hand is left alone.
# The shell integration shells out to `cld`. Point it at the copy under test,
# not at whatever is installed on this machine.
export CLD_BIN="$CLD"
export T_PROJ="$TMP/proj"
export T_SUB="$TMP/proj/sub"
export CLD_BASH="$ROOT/shell/cld.bash"
export CLD_FISH="$ROOT/shell/cld.fish"
export WANT_WORK="$CLD_HOME/profiles/work"
export T_HOSTILE="$TMP/hostile-rc"
mkdir -p "$T_HOSTILE"
printf '%s[2J%s[Hfake\n' "$ESC" "$ESC" > "$T_HOSTILE/.cldrc"

run_shell_checks() { # $1 = label, $2 = output
  eq "$1: cd into a .cldrc folder switches"       "yes" "$(has "A=personal" "$2")"
  eq "$1: each folder's own .cldrc applies"       "yes" "$(has "B=work"     "$2")"
  eq "$1: 'cld use' switches"                     "yes" "$(has "C=personal" "$2")"
  eq "$1: a .cldrc overrides what you picked"     "yes" "$(has "D=work"     "$2")"
  eq "$1: leaving a .cldrc keeps what you have"   "yes" "$(has "E=work"     "$2")"
  eq "$1: exports CLAUDE_CONFIG_DIR"              "yes" "$(has "F=$WANT_WORK" "$2")"
}

bash_out="$(bash -c '
  source "$CLD_BASH"
  cd "$T_PROJ" && printf "A=%s " "$CLD_PROFILE"
  cd "$T_SUB"  && printf "B=%s " "$CLD_PROFILE"
  cd /tmp;           cld use personal; printf "C=%s " "$CLD_PROFILE"
  cd "$T_SUB";       printf "D=%s " "$CLD_PROFILE"
  cd /tmp;           printf "E=%s " "$CLD_PROFILE"
  printf "F=%s" "$CLAUDE_CONFIG_DIR"
' 2>/dev/null)"
run_shell_checks bash "$bash_out"

if command -v zsh >/dev/null 2>&1; then
  zsh_out="$(zsh -f -c '
    source "$CLD_BASH"
    cd "$T_PROJ"; printf "A=%s " "$CLD_PROFILE"
    cd "$T_SUB";  printf "B=%s " "$CLD_PROFILE"
    cd /tmp;      cld use personal; printf "C=%s " "$CLD_PROFILE"
    cd "$T_SUB";  printf "D=%s " "$CLD_PROFILE"
    cd /tmp;      printf "E=%s " "$CLD_PROFILE"
    printf "F=%s" "$CLAUDE_CONFIG_DIR"
  ' 2>/dev/null)"
  run_shell_checks zsh "$zsh_out"
else
  echo "  skip zsh integration (zsh not installed)"
fi

if command -v fish >/dev/null 2>&1; then
  fish_out="$(fish -c '
    source $CLD_FISH
    cd $T_PROJ; printf "A=%s " "$CLD_PROFILE"
    cd $T_SUB;  printf "B=%s " "$CLD_PROFILE"
    cd /tmp;    cld use personal; printf "C=%s " "$CLD_PROFILE"
    cd $T_SUB;  printf "D=%s " "$CLD_PROFILE"
    cd /tmp;    printf "E=%s " "$CLD_PROFILE"
    printf "F=%s" "$CLAUDE_CONFIG_DIR"
  ' 2>/dev/null)"
  run_shell_checks fish "$fish_out"
else
  echo "  skip fish integration (fish not installed)"
fi

if command -v pwsh >/dev/null 2>&1; then
  export CLD_PS1="$ROOT/shell/cld.ps1"
  export T_TMP="$TMP"
  ps_out="$(pwsh -NoProfile -Command '
    . $env:CLD_PS1
    Set-Location $env:T_PROJ; Invoke-CldAuto; Write-Host -NoNewline "A=$env:CLD_PROFILE "
    Set-Location $env:T_SUB;  Invoke-CldAuto; Write-Host -NoNewline "B=$env:CLD_PROFILE "
    Set-Location /tmp;        Invoke-CldAuto
    cld use personal;                         Write-Host -NoNewline "C=$env:CLD_PROFILE "
    Set-Location $env:T_SUB;  Invoke-CldAuto; Write-Host -NoNewline "D=$env:CLD_PROFILE "
    Set-Location /tmp;        Invoke-CldAuto; Write-Host -NoNewline "E=$env:CLD_PROFILE "
    Write-Host -NoNewline "F=$env:CLAUDE_CONFIG_DIR"
  ' 2>/dev/null)"
  run_shell_checks pwsh "$ps_out"

  # The PowerShell build is a separate implementation, so exercise its own
  # commands too, not just the cd hook.
  mkdir -p "$TMP/psrc"
  export T_RC="$TMP/psrc"
  ps_core="$(pwsh -NoProfile -Command '
    $env:CLD_HOME = Join-Path $env:T_TMP "pshome"
    . $env:CLD_PS1
    cld add alpha | Out-Null
    cld add beta  | Out-Null
    Write-Host -NoNewline "L=$((cld list).Count) "
    cld move beta gamma 2>$null | Out-Null
    cld rc gamma $env:T_RC | Out-Null
    Write-Host -NoNewline "RC=$(Get-Content (Join-Path $env:T_RC ".cldrc")) "
    Write-Host -NoNewline "P=$(cld resolve $env:T_RC) "
    Write-Host -NoNewline "M=$(cld resolve --marker $env:T_TMP) "
    cld remove gamma -Force | Out-Null
    Write-Host -NoNewline "G=$(Test-CldProfile gamma)"
  ' 2>/dev/null)"
  eq "pwsh: adopts and adds, 3 profiles" "yes" "$(has "L=3" "$ps_core")"
  eq "pwsh: rc writes .cldrc"            "yes" "$(has "RC=gamma" "$ps_core")"
  eq "pwsh: resolve reads .cldrc"        "yes" "$(has "P=gamma" "$ps_core")"
  eq "pwsh: --marker gives nothing without a .cldrc" "yes" "$(has "M= " "$ps_core")"
  eq "pwsh: remove deletes the profile"  "yes" "$(has "G=False" "$ps_core")"

  # The PowerShell build validates the name in Set-CldActive too, not just in
  # Test-CldProfile: `cld use` reaches it directly, and Join-Path would happily
  # build ...\profiles\..\..\elsewhere.
  mkdir -p "$TMP/outside-ps"
  ps_use="$(pwsh -NoProfile -Command '
    $env:CLD_HOME = Join-Path $env:T_TMP "pshome2"
    $env:CLD_ADOPT = Join-Path $env:T_TMP "fake-claude"
    . $env:CLD_PS1 *> $null
    cld add solo *> $null
    cld use solo *> $null
    cld use "../../outside-ps" *> $null
    Write-Host -NoNewline "CCD=$env:CLAUDE_CONFIG_DIR"
  ' 2>/dev/null)"
  eq "pwsh: 'cld use' refuses a traversal name" "0" \
     "$(printf '%s' "$ps_use" | grep -c 'outside-ps')"
  eq "pwsh: and leaves the real profile active" "yes" "$(has "profiles/solo" "$ps_use")"

  # Remove-Item -Recurse follows a Junction on Windows PowerShell 5.1 and
  # deletes what it points AT. "default" points at the real Claude setup.
  ps_link="$(pwsh -NoProfile -Command '
    $env:CLD_HOME = Join-Path $env:T_TMP "pshome3"
    $env:CLD_ADOPT = Join-Path $env:T_TMP "fake-claude"
    . $env:CLD_PS1 *> $null
    cld remove default -Force *> $null
    Write-Host -NoNewline "GONE=$(-not (Test-CldProfile 'default')) KEPT=$(Test-Path $env:CLD_ADOPT)"
  ' 2>/dev/null)"
  eq "pwsh: removing a linked profile drops the link" "yes" "$(has "GONE=True" "$ps_link")"
  eq "pwsh: and keeps the real dir it points at"      "yes" "$(has "KEPT=True" "$ps_link")"

  # A .cldrc out of a repo you cloned must not repaint the prompt.
  ps_esc="$(pwsh -NoProfile -Command '
    $env:CLD_HOME = Join-Path $env:T_TMP "pshome4"
    $env:CLD_ADOPT = Join-Path $env:T_TMP "fake-claude"
    . $env:CLD_PS1 *> $null
    Set-Location $env:T_HOSTILE
    Invoke-CldAuto
  ' 2>&1)"
  eq "pwsh: a hostile .cldrc cannot clear the screen" "0" \
     "$(printf '%s' "$ps_esc" | grep -c "$(printf '\033')\[2J")"
else
  echo "  skip pwsh integration (pwsh not installed)"
fi

# --- install and uninstall, in a sandbox HOME ------------------------------
# NEVER run these against the real $HOME.
U="$TMP/uhome"
mkdir -p "$U/adopted"
printf '{"mcpServers":{"demo":{"command":"echo"}}}\n' > "$U/.claude.json"
printf 'echo hello\n' > "$U/.bashrc"

# The installer clones, so point it at a scratch repo built from the WORKING
# TREE. Cloning $ROOT itself would test the last commit, not the code you just
# changed. No network needed either way.
SRC_REPO="$TMP/srcrepo"
mkdir -p "$SRC_REPO"
tar -c -C "$ROOT" --exclude .git . | tar -x -C "$SRC_REPO"
git -C "$SRC_REPO" init -q
git -C "$SRC_REPO" add -A
git -C "$SRC_REPO" -c user.email=t@example.com -c user.name=test commit -qm "working tree"

# Piped through stdin, so install.sh takes the "you curled me" path and
# clones, exactly like the published one-liner.
HOME="$U" SHELL=/bin/bash CLD_HOME="$U/.cld" CLD_DIR="$U/.cld/src" \
  CLD_REPO="$SRC_REPO" sh < "$ROOT/install.sh" > "$TMP/install.log" 2>&1
eq "install puts cld on PATH"        "yes" "$(yn "$U/.local/bin/cld")"
eq "install clones the source"       "yes" "$(yn "$U/.cld/src/bin/cld")"
eq "install adds the hook"           "yes" "$(grep -q 'shell/cld.bash' "$U/.bashrc" && echo yes || echo no)"
eq "install keeps the rest of .bashrc" "yes" "$(grep -q 'echo hello' "$U/.bashrc" && echo yes || echo no)"
eq "install adopts the setup"        "1"   "$(HOME="$U" CLD_HOME="$U/.cld" CLD_ADOPT="$U/adopted" CLD_ADOPT_JSON="$U/.claude.json" "$U/.local/bin/cld" list 2>/dev/null | grep -c default)"

# The loader line is a path inside a file your shell RUNS, once per terminal.
# A checkout under a directory whose name holds $( ) must go in as a path, not
# as a command. This one would create PWNED in every new shell.
IHOME="$TMP/injhome2"
IROOT="$TMP/inj/re\$(touch \"$TMP/RC_PWNED\")po"
mkdir -p "$IHOME" "$IROOT"
tar -c -C "$ROOT" --exclude .git . | tar -x -C "$IROOT"
HOME="$IHOME" SHELL=/bin/bash CLD_HOME="$IHOME/.cld" \
  sh "$IROOT/install.sh" > "$TMP/install-inj.log" 2>&1
HOME="$IHOME" bash -c 'source "$HOME/.bashrc"' >/dev/null 2>&1
eq "a \$( ) in the checkout path does not run from .bashrc" "no" "$(yn "$TMP/RC_PWNED")"
eq "and the line still sources the real file" "yes" \
   "$(has "shell/cld.bash" "$(cat "$IHOME/.bashrc" 2>/dev/null)")"

# Piped through stdin, $0 is the bare word "sh" - and [ -f "sh" ] is a test
# against the CURRENT DIRECTORY, not a check that we were run from a clone.
PIPED="$TMP/piped"
mkdir -p "$PIPED/bin" "$PIPED/shell" "$PIPED/phome"
printf '#!/bin/sh\necho evil\n' > "$PIPED/bin/cld"
printf 'echo evil\n' > "$PIPED/shell/cld.bash"
printf 'x\n' > "$PIPED/sh"
rc=0
(cd "$PIPED" && HOME="$PIPED/phome" SHELL=/bin/bash CLD_HOME="$PIPED/phome/.cld" \
   CLD_DIR="$PIPED/phome/.cld/src" CLD_REPO="$SRC_REPO" sh < "$ROOT/install.sh") \
   > "$TMP/piped.log" 2>&1 || rc=$?
eq "a piped install ignores a ./bin/cld in the current directory" "yes" \
   "$(yn "$PIPED/phome/.cld/src/bin/cld")"
eq "and links to the clone, not to the local copy" "$PIPED/phome/.cld/src/bin/cld" \
   "$(readlink "$PIPED/phome/.local/bin/cld" 2>/dev/null)"

# Somebody else's cld, in a directory the uninstaller sweeps. It is not our
# symlink, so it has to survive.
mkdir -p "$U/bin"
printf 'echo not ours\n' > "$U/bin/cld"

# Nor is somebody else's cld that IS a symlink ending in /bin/cld - which is
# exactly what a package manager installs.
mkdir -p "$U/other/bin"
printf 'echo not ours either\n' > "$U/other/bin/cld"
ln -sf "$U/other/bin/cld" "$U/.local/bin/cld-foreign"
mkdir -p "$U/foreignbin"
ln -sf "$U/other/bin/cld" "$U/foreignbin/cld"

HOME="$U" CLD_BIN_DIR="$U/foreignbin" CLD_HOME="$U/.cld" \
  sh "$U/.cld/src/uninstall.sh" > "$TMP/uninstall.log" 2>&1
eq "uninstall takes cld off PATH"      "no"  "$(yn "$U/.local/bin/cld")"
eq "uninstall leaves a foreign cld alone" "yes" "$(yn "$U/bin/cld")"
eq "uninstall leaves a foreign cld SYMLINK alone" "yes" "$(yn "$U/foreignbin/cld")"
eq "uninstall removes the hook"        "no"  "$(grep -q 'shell/cld' "$U/.bashrc" && echo yes || echo no)"
eq "uninstall keeps the rest of .bashrc" "yes" "$(grep -q 'echo hello' "$U/.bashrc" && echo yes || echo no)"
eq "uninstall leaves a backup"         "yes" "$(yn "$U/.bashrc.cld-backup")"
eq "uninstall keeps your Claude config" "yes" "$(grep -q demo "$U/.claude.json" && echo yes || echo no)"
eq "uninstall keeps profiles"          "yes" "$(yn "$U/.cld/profiles")"

HOME="$U" CLD_HOME="$U/.cld" sh "$U/.cld/src/uninstall.sh" --purge > "$TMP/purge.log" 2>&1
eq "--purge deletes the profiles"      "no"  "$(yn "$U/.cld")"
eq "--purge keeps your Claude config"  "yes" "$(grep -q demo "$U/.claude.json" && echo yes || echo no)"

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
