# cld - Claude account manager

One terminal on your work account, another on your personal one. Drop a
`.cldrc` in a project and every terminal in that folder uses the right
account. Run `claude` as usual.

Each profile is its own Claude config: own login, MCP servers, settings,
skills and history. Nothing is shared.

## Install

macOS and Linux:

```sh
curl -fsSL https://raw.githubusercontent.com/MariuszHenn/cld/main/install.sh | sh
```

Windows:

```powershell
irm https://raw.githubusercontent.com/MariuszHenn/cld/main/install.ps1 | iex
```

Open a new terminal. The installer clones to `~/.cld/src`, puts `cld` on your
PATH, and adds one line to your shell config - `cld use` and the switch on
`cd` need it. Pass `--no-shell` (or `-NoShell`) to add that line yourself.
It prints the commit it installed, and refuses to replace a `cld` on your PATH
that is not its own.

That line is sourced by every terminal you open, so read it first if you would
rather not pipe a script into a shell:

```sh
git clone https://github.com/MariuszHenn/cld ~/.cld/src
less ~/.cld/src/install.sh
sh ~/.cld/src/install.sh
```

`CLD_REF=v1.0.0` pins the install to an exact tag or commit instead of `main`.

Your existing `~/.claude` is adopted as the `default` profile through a
symlink. Nothing is copied or moved.

## Use it

```sh
cld list             # profiles; * is this terminal
cld add work         # a new account
cld use work         # switch this terminal
claude               # sign in once per profile

cd ~/projects/acme
cld rc work          # this folder always uses "work"
```

## Commands

| Command | What it does |
| --- | --- |
| `cld list` | Show all profiles. `*` is this terminal |
| `cld add <name>` | Create a profile |
| `cld use <name>` | Switch this terminal to a profile |
| `cld rc <name> [dir]` | Make a folder always use that profile (that folder only) |
| `cld move <old> <new>` | Rename a profile |
| `cld remove <name>` | Delete a profile (needs `CLD_YES=1`) |
| `cld uninstall` | Remove `cld`, put your Claude setup back |

`cld` (or `cld help`) also prints what is active in this terminal.

## How it works

`cld` sets `CLAUDE_CONFIG_DIR` to one folder per profile; Claude Code reads
that variable and uses that folder's account.

A `.cldrc` holds one profile name. `cld` reads it from the current folder and
nowhere else - it governs that folder, not what is under it, so a `.cldrc`
left somewhere you merely happen to be working beneath cannot choose your
account. A `.cldrc` you own always wins on `cd`, even over a profile you
picked by hand; one that is a symlink, or that another user owns, or that
sits in a directory another user owns, is ignored. With no `.cldrc`, a
hand-picked profile is left alone; otherwise the default applies.

Switching account always says so, and there is no way to silence it: a folder
changing which account you are on without telling you is the one thing `cld`
must not do.

Want it to cover a whole tree? Run `cld rc <name>` in each folder you actually
work in - a subfolder does not inherit.

You sign in once per profile. Claude keys its login to the config directory,
so every profile - `default` included - needs its own `claude` then `/login`.

New profiles get a `settings.json` with a status line showing the active
profile and account (`bin/cld-statusline`).

```
~/.cld/profiles/<name>   one folder per profile
~/.cld/default           which profile applies with no .cldrc
~/.cld/src               the installed clone
```

## Uninstall

```sh
cld uninstall            # remove cld, keep profiles
cld uninstall --purge    # also delete ~/.cld
```

Takes `cld` off your PATH, removes the shell line (leaving a `.cld-backup`),
and undoes the one helper link. Your original Claude setup is untouched.

## Tests

```sh
bash tests/test.sh
```
