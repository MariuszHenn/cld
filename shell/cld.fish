# cld shell integration for fish.
# Add this to ~/.config/fish/config.fish:
#     source /path/to/cld/shell/cld.fish

if not set -q CLD_BIN
    set -g CLD_BIN cld
end

function __cld_apply --argument-names name
    if test -n "$name"
        set -l target (command $CLD_BIN dir $name 2>/dev/null)
        if test -z "$target"
            return 1
        end
        if test "$CLAUDE_CONFIG_DIR" != "$target"
            set -gx CLAUDE_CONFIG_DIR $target
            set -gx CLD_PROFILE $name
            # Which account you are on, changing under you, is never noise.
            # There is no way to silence this: a folder switching your account
            # without saying so is the one thing cld must not do.
            echo "cld: profile $name" >&2
        else
            set -gx CLD_PROFILE $name
        end
    else
        if set -q CLD_PROFILE
            set -e CLAUDE_CONFIG_DIR
            set -e CLD_PROFILE
            echo "cld: profile cleared" >&2
        end
    end
end

function __cld_auto
    # Only when the directory actually changed, so an untrusted .cldrc warns
    # once rather than on every prompt.
    if test "$__cld_last_pwd" = "$PWD"
        return
    end
    set -g __cld_last_pwd $PWD
    # A trusted .cldrc ALWAYS wins: entering a folder that has one switches
    # you, even if you picked a profile by hand. With no .cldrc, your
    # hand-picked profile is left alone; only a shell that has never chosen
    # anything falls back to the default.
    #
    # stderr is deliberately NOT swallowed: an untrusted or broken .cldrc has
    # to be able to tell you so.
    set -l name (command $CLD_BIN resolve --marker $PWD)
    if test -n "$name"
        __cld_apply $name
    else if not set -q CLD_PROFILE
        __cld_apply (command $CLD_BIN resolve $PWD 2>/dev/null)
    end
end

function cld --description "Claude account manager"
    switch "$argv[1]"
        case use
            if test (count $argv) -lt 2
                echo "cld: usage: cld use <name>" >&2
                return 1
            end
            __cld_apply $argv[2]; or return 1
        case rc
            # It changes what this directory resolves to, so re-read it right
            # away instead of making you cd out and back in.
            command $CLD_BIN $argv; or return 1
            set -g __cld_last_pwd ""
            __cld_auto
        case '*'
            command $CLD_BIN $argv
    end
end

function __cld_on_pwd --on-variable PWD
    __cld_auto
end

__cld_auto
