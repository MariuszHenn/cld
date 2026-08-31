#!/usr/bin/env sh
# cld uninstaller for macOS and Linux.
#
#   sh uninstall.sh              remove cld, keep your profiles
#   sh uninstall.sh --purge      also delete ~/.cld and every profile in it
#
# This never deletes the Claude setup you had before cld. The "default"
# profile is a link to it, and removing a link does not touch the target.
set -eu

CLD_HOME="${CLD_HOME:-$HOME/.cld}"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

say() { printf 'cld: %s\n' "$1"; }

# 1. take the launcher off PATH.
#    install.sh only ever makes a symlink into a cld checkout, so the link has
#    to land in one. Matching the tail of the target is not enough: another
#    tool called cld, installed by a package manager, is also a symlink ending
#    in /bin/cld - Homebrew's is exactly that.
is_ours() {
  r="$(cd "$(dirname "$1")/.." 2>/dev/null && pwd -P)" || return 1
  [ -f "$r/bin/cld" ] && [ -f "$r/shell/cld.bash" ] && [ -f "$r/uninstall.sh" ]
}
for d in "${CLD_BIN_DIR:-}" "$HOME/.local/bin" "/usr/local/bin" "$HOME/bin"; do
  [ -n "$d" ] || continue
  [ -L "$d/cld" ] || continue
  target="$(readlink "$d/cld")"
  case "$target" in
    /*) ;;
    *)  target="$d/$target" ;;
  esac
  if ! is_ours "$target"; then
    say "left $d/cld alone: it is not our link"
    continue
  fi
  rm -f "$d/cld"
  say "removed $d/cld"
done

# 2. take the hook out of the shell configs
strip_hook() {
  file="$1"
  [ -f "$file" ] || return 0
  grep -q 'shell/cld\.' "$file" 2>/dev/null || return 0
  cp "$file" "$file.cld-backup"
  awk '
    /^# cld - Claude account manager$/ { next }
    /shell\/cld\./                     { next }
    { print }
  ' "$file" > "$file.cld-tmp"
  mv "$file.cld-tmp" "$file"
  say "removed the hook from $file (backup: $file.cld-backup)"
}
strip_hook "$HOME/.bashrc"
strip_hook "${ZDOTDIR:-$HOME}/.zshrc"
strip_hook "$HOME/.config/fish/config.fish"

# 3. put the adopted setup back the way it was
#    On first run cld linked <adopted>/.claude.json to ~/.claude.json, because
#    Claude looks in a different place once CLAUDE_CONFIG_DIR is set. Undo that,
#    but only if it is still our link and not a real file someone created.
DEFAULT_LINK="$CLD_HOME/profiles/default"
if [ -L "$DEFAULT_LINK" ]; then
  adopted="$(readlink "$DEFAULT_LINK")"
  inner="$adopted/.claude.json"
  if [ -L "$inner" ] && [ "$(readlink "$inner")" = "$HOME/.claude.json" ]; then
    rm -f "$inner"
    say "removed the helper link $inner"
  fi
fi

# 4. profiles
if [ "$PURGE" = "1" ]; then
  if [ -d "$CLD_HOME" ]; then
    rm -rf "$CLD_HOME"
    say "deleted $CLD_HOME and every profile in it"
    say "NOTE the accounts you logged in with are gone. Your original setup is not."
  fi
else
  if [ -d "$CLD_HOME" ]; then
    say "kept your profiles in $CLD_HOME"
    say "delete them later with: rm -rf \"$CLD_HOME\"   (or re-run: sh uninstall.sh --purge)"
  fi
fi

cat <<'DONE'

cld is uninstalled.

Open a new terminal. CLAUDE_CONFIG_DIR is no longer set, so `claude` uses your
original setup again, exactly as before you installed cld.
DONE
