# cld shell integration for bash and zsh.
# Add this to ~/.bashrc or ~/.zshrc:
#     source /path/to/cld/shell/cld.bash
#
# It does two things:
#   1. wraps `cld` so that `use` can change THIS shell
#   2. switches profile automatically every time you cd, using .cldrc

: "${CLD_BIN:=cld}"

__cld_apply() {
  # $1 = profile name, or empty to clear
  local name="$1" target
  if [ -n "$name" ]; then
    target="$(command "$CLD_BIN" dir "$name" 2>/dev/null)" || return 1
    [ -n "$target" ] || return 1
    if [ "${CLAUDE_CONFIG_DIR:-}" != "$target" ]; then
      export CLAUDE_CONFIG_DIR="$target"
      export CLD_PROFILE="$name"
      # Which account you are on, changing under you, is never noise. There is
      # no way to silence this: a folder switching your account without saying
      # so is the one thing cld must not do.
      printf 'cld: profile %s\n' "$name" >&2
    else
      export CLD_PROFILE="$name"
    fi
  else
    if [ -n "${CLD_PROFILE:-}" ]; then
      unset CLAUDE_CONFIG_DIR CLD_PROFILE
      printf 'cld: profile cleared\n' >&2
    fi
  fi
}

__cld_auto() {
  # Only when the directory actually changed. The prompt hook below fires on
  # every prompt, and "this .cldrc is not trusted" must not print once per
  # keystroke - it also saves a subprocess per prompt.
  [ "${__CLD_LAST_PWD:-}" = "$PWD" ] && return 0
  __CLD_LAST_PWD="$PWD"
  # A trusted .cldrc ALWAYS wins: entering a folder that has one switches you,
  # even if you picked a profile by hand. With no .cldrc, your hand-picked
  # profile is left alone; only a shell that has never chosen anything falls
  # back to the default.
  local name
  # stderr is deliberately NOT swallowed here: an untrusted or broken .cldrc
  # has to be able to tell you so.
  name="$(command "$CLD_BIN" resolve --marker "$PWD")"
  if [ -n "$name" ]; then
    __cld_apply "$name"
  elif [ -z "${CLD_PROFILE:-}" ]; then
    __cld_apply "$(command "$CLD_BIN" resolve "$PWD" 2>/dev/null)"
  fi
}

cld() {
  case "${1:-}" in
    use)
      if [ -z "${2:-}" ]; then
        printf 'cld: usage: cld use <name>\n' >&2
        return 1
      fi
      __cld_apply "$2" || return 1
      ;;
    rc)
      # It changes what this directory resolves to, so re-read it right away
      # instead of making you cd out and back in.
      command "$CLD_BIN" "$@" || return 1
      __CLD_LAST_PWD=""
      __cld_auto
      ;;
    *)
      command "$CLD_BIN" "$@"
      ;;
  esac
}

if [ -n "${ZSH_VERSION:-}" ]; then
  # zsh has a real hook for "the directory changed".
  autoload -Uz add-zsh-hook 2>/dev/null && add-zsh-hook chpwd __cld_auto
else
  # bash has no chpwd hook, so do both:
  #  1. wrap cd/pushd/popd, which also works in scripts and non-interactive shells
  #  2. run at the prompt as a safety net, for anything that moves you some other way
  cd()    { builtin cd    "$@" && __cld_auto; }
  pushd() { builtin pushd "$@" && __cld_auto; }
  popd()  { builtin popd  "$@" && __cld_auto; }
  case "${PROMPT_COMMAND:-}" in
    *__cld_auto*) ;;
    "") PROMPT_COMMAND="__cld_auto" ;;
    *)  PROMPT_COMMAND="__cld_auto;${PROMPT_COMMAND}" ;;
  esac
fi

__cld_auto
