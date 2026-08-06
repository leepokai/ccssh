# ccssh

Get to Claude Code on another machine, fast.

The Claude Code **desktop** app can open a session on a remote machine over SSH
without making you log in again. The **CLI** cannot. `ccssh` adds that.

```
$ ccssh

  Where do you want to work?

  › ★ vps        /srv/app
    ◆ vps
    ▪ Local
    ◆ build-01
    ◆ dev-box

  connecting to vps…
  ✓ claude 2.1.4 on vps
  ✓ credentials forwarded (valid for 6.6h)

  [Claude Code starts on vps, in /srv/app]
```

Where you left off leads the list, and the same host without a directory sits
right below it — that is how you go back to a machine and pick somewhere else.
Local comes next, and is first of all on a machine you have not used yet.

`ccssh vps` skips the menu entirely and goes where you left off. Run it from
anywhere: ccssh has no opinion about your local directory and keeps no mapping
to it.

Arrow keys or `j`/`k` to move, Enter to choose. With [fzf] installed you also get
type-to-filter and mouse support.

Choosing a directory is one input, not a list and then a prompt. The
repositories it found are there to begin with; typing narrows them straight
away, with no keystroke needed first:

```
  Folder on vps: api                                            3/1660

  > ~/srv/api
    ~/work/apiary
    ~/.cache/api-docs
```

Every directory under your home on that host arrives in **one** listing, and
every keystroke after that is filtered here. Asking the host per directory
costs a round trip each time you walk into one; asking once costs about a
third of a second and makes typing, backtracking and jumping somewhere
unrelated all free. Measured on two real hosts: 1,700–4,300 directories,
87–214 KB, ~330 ms once, then ~8 ms per keystroke.

There is deliberately **no second mode** for paths — one flat list, one rule,
nothing that changes under you.

The count is matches out of total, the way fzf, lf and yazi all carry one.
Matching is case-insensitive until you type a capital — smart-case, which all
three default to. Results are ordered by where the match landed and then by
path length, so `mycode` reaches `~/mycode` rather than something buried that
merely contains the word, and a leading dot costs nothing: `ssh` finds
`~/.ssh`.

Tab takes the highlighted entry rather than completing to the prefix the
matches share — over a fuzzy result set that prefix is worthless; for
`/usr/local` and `/var/log` it is `/`. fzf made the same call.

[fzf]: https://github.com/junegunn/fzf

## What it does

- Lists the hosts already in your `~/.ssh/config` — nothing new to configure
- Installs Claude Code on the remote the first time, using the official installer
- Forwards your login so you never sign in on the remote (see [Credentials](#credentials))
- Offers the git repositories it finds there, or takes a path you type
- Offers a branch or worktree when you ask for one with `-b`
- Wraps the session in tmux — installing it if the host lacks it — so a dropped
  connection does not lose your work, and uses mosh where the host has it
- Remembers, per host, the folder you were last in

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/leepokai/ccssh/main/install.sh | bash
```

That fetches ccssh into `~/.local/share/ccssh` and links it into the first
writable directory on your PATH — `~/.local/bin`, where Claude Code installs
itself, or `/usr/local/bin`. Re-run the same line to update.

If you would rather see the source first, or want to hack on it:

```sh
git clone https://github.com/leepokai/ccssh
ccssh/install.sh
```

Run from a clone, the installer links to *that* clone and leaves it in charge —
so `git pull` is how you update, and your edits take effect immediately.

Requires `bash`, `ssh` and `python3` locally; `python3` and `git` on the
remote. The installer also puts `mosh` on this machine — see
[Setting a host up](#setting-a-host-up) — which `CCSSH_SKIP_MOSH=1` skips.

Connections are much faster with multiplexing — add this to `~/.ssh/config`:

```
Host *
  ControlMaster auto
  ControlPath ~/.ssh/sockets/%C
  ControlPersist 4h
```

The first connection takes a few seconds; every later one is near-instant,
because probing, credentials and git all share that single connection.

## Usage

```
ccssh                  pick an environment, land where you left off
ccssh drive-bridge     go straight to one you have named
ccssh vps              go straight to a host
ccssh vps:/srv/other   go straight to a directory
ccssh --save <name>    name where you are going, for next time
ccssh -c               continue the session you left there
ccssh -r               pick among the sessions open there
ccssh -p               pick the directory again
ccssh -b               pick a branch or worktree too
ccssh --takeover       detach whoever else is attached
ccssh --setup <host>   get a host ready in one go, then stop
ccssh --local          run Claude Code here
ccssh --forget [host]  forget where you left off
ccssh -v               show every step instead of one status line
```

## Setting a host up

Connecting prepares a host as it goes — installing Claude Code, tmux and mosh
if they are missing, and sending a credential. `ccssh --setup my-vps` does the
same work up front and then stops, which is nicer when a package install wants
a sudo password and you would rather answer it now than halfway into starting
work.

```
  Preparing my-vps

  ✓ Linux x86_64, home at /home/me
  ✓ python3
  ✓ git
  ✓ claude 2.1.223
  ✓ tmux — sessions survive a dropped connection
  ✓ mosh installed
  ✓ credentials valid 7.2h

  ✓ my-vps is ready
    ccssh my-vps
```

Package installs go through brew where it exists, and apt / dnf / yum / pacman
/ apk / zypper otherwise — those need root, so it asks first.

mosh is part of that, and `install.sh` puts it on this machine too. It shows
your keystrokes before the host answers, so typing over a slow link feels
local, and it reattaches by itself when the network drops or your laptop wakes
somewhere else. If its UDP ports turn out to be blocked, ccssh falls back to
ssh and says so — having it costs nothing.

`CCSSH_SKIP_MOSH=1` on the installer skips it; `"useMosh": false` per host
skips it there.

## Environments

An **environment** is a name for a place you work: an SSH host, a **directory**
on it, optionally a **branch**. The words follow the desktop app, whose session
objects carry exactly `name`, `sshHost` and `remoteCwd`.

Name one as you go:

```sh
ccssh vps:/srv/drive-bridge --save drive-bridge
```

From then on `ccssh drive-bridge` goes straight there, and you have a word for
it. They live in `~/.claude/ccssh/config.json`:

```json
{
  "environments": {
    "drive-bridge": { "sshHost": "vps", "directory": "/srv/drive-bridge" },
    "api-staging":  { "sshHost": "vps", "directory": "/srv/api",
                      "branch": "staging" }
  }
}
```

Naming is optional. A bare host still works, and every host remembers the
directory you were last in either way. A name wins over a host of the same
name — you wrote it down on purpose.

Connecting prints a single line that rewrites itself and then gets out of the
way. Anything that needs you — an install, a missing credential, an expiry
running low — prints properly and stays. `-v` shows every step.

`ccssh` runs *before* Claude Code and hands the terminal over to it, so there is
nothing to switch from inside a session. To move to another host, leave and run
`ccssh <host>` again.

## Credentials

**Your login is copied to the remote host.** Read this before using it on a
machine you do not control.

`ccssh` reads your Claude Code credential locally (from the macOS Keychain, or
`~/.claude/.credentials.json` on Linux), removes the long-lived **refresh
token**, and writes only the short-lived access token to `~/.claude/` on the
remote with `0600` permissions. It travels over stdin, never on a command line
where the remote process list would expose it.

This mirrors what the desktop app does. It means a compromised remote yields a
credential that expires on its own and cannot be renewed — but it is still your
credential, on a machine whose administrator can read root-owned files.

Because the refresh token stays home, **the remote cannot renew itself**: access
tokens last about 8 hours. Reconnecting sends whatever your machine currently
holds — which only helps if that token has since been renewed here, since it is
the same token with the same expiry. If you work only on the remote, both sides
run out together.

### Turning forwarding off is not a safety measure

A host running Claude Code needs *some* credential. There are three ways it gets
one, and they differ in how much they leave behind:

| Arrangement | What sits on the host | When it makes sense |
|---|---|---|
| Forwarding (default) | An access token, dead in ~8h, unable to renew | Almost always |
| Signing in there | A full credential that renews itself for weeks | A machine you trust and use constantly |
| Neither | Nothing — Claude Code cannot run | You do not work on that host |

So `forwardAuth: false` does not harden a host. It says *this host arranges its
own authentication, leave it alone* — and signing in there is the arrangement
that leaves **more** behind, not less. On a machine you are wary of, forwarding
is the smallest credential you can give it and still get work done.

One wrinkle worth knowing: on macOS the login lives in the Keychain, which
**cannot be read over SSH**. A Mac you signed into through its GUI therefore has
no usable credential in an SSH session, and still needs forwarding. On Linux the
credential is a plain file, so signing in there does carry over.

### Configuration

`~/.claude/ccssh/config.json`, per host:

```json
{
  "hosts": {
    "linux-box-i-signed-into": { "forwardAuth": false },
    "machine-i-live-on":       { "allowRenewal": true }
  }
}
```

| Option | Default | Effect |
|---|---|---|
| `forwardAuth` | `true` | Send a credential at all |
| `allowRenewal` | `false` | Also send the refresh token — read below |
| `useMosh` | `true` | Use mosh when both ends have it |

### Why `allowRenewal` is off by default

Sending the refresh token does let the remote keep itself signed in. But refresh
tokens **rotate**: each renewal issues a new one and retires the old. Two
machines holding the same refresh token are two clients racing over one rotating
credential — whichever renews first can leave the other holding a dead token.
That may log out the remote, or your own machine.

The desktop app avoids this by being the only client that ever touches the
refresh token. A separate tool cannot make that guarantee. So `allowRenewal`
trades a known 8-hour limit for an unpredictable one.

Worse, it is *your* credential rather than a separate one. Signing in on the
host also leaves a weeks-long credential there, but a distinct one: if that
machine is compromised, your own session is untouched and you can deal with it
independently. A forwarded refresh token has no such separation — whoever holds
it can keep renewing indefinitely, and each renewal retires the copy you are
holding. Prefer signing in on the host over turning this on.

To remove a forwarded credential: `ssh <host> 'rm ~/.claude/.credentials.json'`.

## Worktrees

Choosing `+ new worktree` creates one on the remote under:

```
~/.ccssh-worktrees/<repo>-<hash>/<branch>
```

The hash comes from the repository path, so two repositories with the same name
never collide. Branch names are validated and the composed path is checked to
stay inside that root, so a branch name cannot write anywhere else.

Remove one with `git worktree remove` on the host. They are full checkouts, so
they do accumulate.

## MCP servers

Claude Code runs on the remote, so it uses **that machine's** MCP servers. Set
them up there as you normally would — `claude mcp add …`, or a `.mcp.json` in
the project — and they work natively, with direct access to the remote's files,
docker and network position.

Servers that talk to a network API (Figma, Supabase, Linear, Stripe, …) behave
identically wherever they run. The ones you lose are those that act on *your*
machine: local browser control, desktop notifications, your local filesystem.

Each remote server needs its own authentication, and OAuth flows that want a
browser are awkward over SSH. Finish those logins while you have a session open
on that host.

## What it does not do

- Windows hosts, and Windows as the local machine
- MCP servers that drive your local machine (browser control, notifications)
- Syncing files between local and remote

## How it compares to the desktop app

Both run the real Claude Code on the remote machine — the desktop app uploads a
small manager that fetches and versions the CLI there, and drives it in SDK mode
while keeping its UI local. `ccssh` installs the CLI with the official installer
and runs it as an ordinary terminal session.

That difference shows up in three places. The desktop app manages remote CLI
versions and syncs your plugins across; ccssh does neither. It renews auth
through its own channel, where ccssh can only relay what this machine has. And
its session lives in a daemon, where ccssh uses tmux — which in
exchange means you can `ssh host && tmux attach` from anywhere and land in the
same session, with no app in the middle.

## Surviving a dropped connection

Two separate problems, solved separately.

**The session outliving the connection** is tmux's job. Claude Code runs inside
a tmux session on the host, so when your network dies the session keeps running
— including any answer it was in the middle of, since that request goes from the
host, not through your laptop. Run `ccssh` again and you are back where you
were. tmux is installed for you if the host lacks it (with brew directly, with
apt/dnf/yum/pacman/apk/zypper after asking, since those need root).

**Reattaching by itself** is [mosh]'s job. Where the host has `mosh-server` and
you have `mosh`, ccssh uses it: a changed IP, a closed lid or a dead network no
longer detaches you. It is never installed for you, because it needs UDP
60000-61000 reachable — on a VPS that means a firewall or security-group change
only you can make. If mosh cannot connect, ccssh falls back to ssh and says so.

Opt out per host with `"useMosh": false`, or everywhere with `CCSSH_NO_MOSH=1`.

## Sessions

**`ccssh` starts a new session**, the way running `claude` starts a new
conversation rather than reopening your last one. Two terminals on the same
directory get two sessions, not one shared screen.

Getting back to an old one is explicit, and named after the flags `claude`
already uses:

| | |
|---|---|
| `ccssh -c` | continue the session you left there |
| `ccssh -r` | list what is open there and pick one |

`--takeover` detaches whoever else is attached, so tmux stops squeezing the
window down to the smaller of the two terminals watching it.

Sessions are named after the directory and branch, with the directory's path
hashed in, so two repositories sharing a name never collide. You can reach any
of them without ccssh at all: `ssh host` then `tmux attach`.

[mosh]: https://mosh.org

## Development

```sh
tests/run.sh
```

The end-to-end suite drives the real launcher through a real pty against a real
host, under `--dry-run` so nothing on the host changes:

```sh
CCSSH_E2E_HOST=my-vps tests/run.sh
```

It has been run against both a macOS and a Linux host.

The credential and worktree tests guard security properties — that the refresh
token is never forwarded, and that a branch name cannot escape the worktree
root. Keep them passing.

## Naming

`cssh` was the original name; it belongs to ClusterSSH. `ccssh` is Claude Code
SSH.

## License

MIT
