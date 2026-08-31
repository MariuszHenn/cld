#!/usr/bin/env sh
# cld installer for macOS and Linux.
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/MariuszHenn/cld/main/install.sh | sh
#
# From a clone:
#   ./install.sh            install and patch your shell config
#   ./install.sh --no-shell install only, print the line to add yourself
set -eu

CLD_REPO="${CLD_REPO:-https://github.com/MariuszHenn/cld}"
CLD_DIR="${CLD_DIR:-$HOME/.cld/src}"
# Pin an exact tag or commit:  CLD_REF=v1.0.0 sh install.sh
CLD_REF="${CLD_REF:-}"

PATCH=1
[ "${1:-}" = "--no-shell" ] && PATCH=0

# Work out where the source is. Two cases:
#   1. you cloned the repo and ran ./install.sh  -> use the clone you are in
#   2. you piped this script from curl           -> clone the repo first
# The `case` is the load-bearing part. When this script is piped in, $0 is the
# bare word "sh" - and [ -f "sh" ] is a RELATIVE test, so it matches a file
# called "sh" in whatever directory you ran the one-liner from. A real script
# path always contains a slash; "sh" never does.
ROOT=""
case "$0" in
  */*)
    if [ -f "$0" ] && [ -f "$(dirname "$0")/bin/cld" ]; then
      ROOT="$(cd "$(dirname "$0")" && pwd -P)"
    fi
    ;;
esac
if [ -z "$ROOT" ]; then
  command -v git >/dev/null 2>&1 || { printf 'cld: git is required\n' >&2; exit 1; }
  if [ -d "$CLD_DIR/.git" ]; then
    printf 'cld: updating %s\n' "$CLD_DIR"
    git -C "$CLD_DIR" pull --quiet --ff-only || printf 'cld: could not update, using what is there\n' >&2
    [ -n "$CLD_REF" ] && git -C "$CLD_DIR" checkout --quiet "$CLD_REF"
  else
    printf 'cld: cloning %s into %s\n' "$CLD_REPO" "$CLD_DIR"
    # Private: profiles, and so the account logins in them, live under here.
    (umask 077 && mkdir -p "$(dirname "$CLD_DIR")")
    if [ -n "$CLD_REF" ]; then
      git clone --quiet --depth 1 --branch "$CLD_REF" "$CLD_REPO" "$CLD_DIR"
    else
      git clone --quiet --depth 1 "$CLD_REPO" "$CLD_DIR"
    fi
  fi
  ROOT="$CLD_DIR"
fi

BIN="$ROOT/bin/cld"
[ -f "$BIN" ] || { printf 'cld: cannot find %s\n' "$BIN" >&2; exit 1; }
chmod +x "$BIN"

# Say exactly what is about to be sourced into every shell you open, so it can
# be checked against the repository.
if [ -d "$ROOT/.git" ] && command -v git >/dev/null 2>&1; then
  REV="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
  [ -n "$REV" ] && printf 'cld: installing commit %s\n' "$REV"
fi

# 1. put cld on PATH
# Always your own ~/.local/bin unless you say otherwise. Never a system
# directory: this is a per-user tool, and uninstall has to find it again.
LINK_DIR="${CLD_BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$LINK_DIR"
# Somebody else's cld is not ours to replace. The uninstaller already refuses
# to remove one; the installer has no business clobbering one either.
if [ -e "$LINK_DIR/cld" ] || [ -L "$LINK_DIR/cld" ]; then
  CUR="$(readlink "$LINK_DIR/cld" 2>/dev/null || true)"
  case "$CUR" in
    /*) ;;
    ?*) CUR="$LINK_DIR/$CUR" ;;
  esac
  OURS=0
  if [ -n "$CUR" ]; then
    CUR_ROOT="$(cd "$(dirname "$CUR")/.." 2>/dev/null && pwd -P || true)"
    [ -n "$CUR_ROOT" ] && [ -f "$CUR_ROOT/bin/cld" ] && [ -f "$CUR_ROOT/shell/cld.bash" ] \
      && [ -f "$CUR_ROOT/uninstall.sh" ] && OURS=1
  fi
  if [ "$OURS" = "0" ]; then
    printf 'cld: %s already exists and is not a cld install.\n' "$LINK_DIR/cld" >&2
    printf 'cld: remove it, or install elsewhere:  CLD_BIN_DIR=~/bin sh install.sh\n' >&2
    exit 1
  fi
fi
ln -sf "$BIN" "$LINK_DIR/cld"
printf 'cld: linked %s -> %s\n' "$LINK_DIR/cld" "$BIN"
case ":$PATH:" in
  *":$LINK_DIR:"*) ;;
  *) printf 'cld: NOTE %s is not on your PATH yet.\n' "$LINK_DIR" ;;
esac

# 2. shell integration
#    The config line sources our file directly. There is no `cld hook` command:
#    if the hook is missing, `cld use` cannot work at all, so installing it is
#    the installer's job, not something to remember.
HOOK_COMMENT='# cld - Claude account manager'

config_file() {
  case "$1" in
    bash) printf '%s\n' "$HOME/.bashrc" ;;
    zsh)  printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" ;;
    fish) printf '%s\n' "$HOME/.config/fish/config.fish" ;;
  esac
}

# The path goes into a file your shell RUNS, once per terminal, forever. In
# double quotes, a checkout under a directory whose name contains $( ) would
# not be a path at all - it would be a command, executed on every shell you
# open. Single quotes, with the usual '\'' dance for a quote in the path.
# bash, zsh and fish all read it the same way.
sq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

config_line() {
  case "$1" in
    bash) printf 'source %s\n' "$(sq "$ROOT/shell/cld.bash")" ;;
    zsh)  printf 'source %s\n' "$(sq "$ROOT/shell/cld.bash")" ;;
    fish) printf 'source %s\n' "$(sq "$ROOT/shell/cld.fish")" ;;
  esac
}

add_hook() {
  file="$(config_file "$1")"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  if grep -Fq 'shell/cld.' "$file" 2>/dev/null; then
    printf 'cld: %s already loads cld, left alone\n' "$file"
    return 0
  fi
  { printf '\n%s\n' "$HOOK_COMMENT"; config_line "$1"; } >> "$file"
  printf 'cld: added the hook to %s\n' "$file"
}

if [ "$PATCH" = "1" ]; then
  # Always the shell you are actually using, even if its config file does not
  # exist yet. Without this, `cld use` fails with "needs the shell hook".
  MINE="$(basename "${SHELL:-}")"
  case "$MINE" in
    bash|zsh|fish) add_hook "$MINE" ;;
    *) MINE="" ;;
  esac

  # Then any other shell that already has a config file, so switching shells
  # later just works.
  for sh in bash zsh fish; do
    [ "$sh" = "$MINE" ] && continue
    [ -f "$(config_file "$sh")" ] || continue
    add_hook "$sh"
  done

  if [ -z "$MINE" ]; then
    printf 'cld: could not tell which shell you use (SHELL=%s)\n' "${SHELL:-unset}"
    printf 'cld: add this line to your shell config yourself:\n'
    printf 'cld:   source "%s/shell/cld.bash"\n' "$ROOT"
  fi
else
  printf '\nAdd the right line to your shell config by hand:\n'
  printf '  bash  (~/.bashrc):                  %s\n' "$(config_line bash)"
  printf '  zsh   (~/.zshrc):                   %s\n' "$(config_line zsh)"
  printf '  fish  (~/.config/fish/config.fish): %s\n' "$(config_line fish)"
fi

cat <<'DONE'

Done. Open a new terminal, then:

  cld list                # your current setup is already here as "default"
  claude                  # sign in once

  cld add work            # a second account
  cld use work
  claude                  # sign in once here too

  cd ~/projects/acme
  cld rc work             # this folder always uses "work" from now on

In any project folder:

  cld rc work             # writes .cldrc, that folder now uses "work"
DONE
