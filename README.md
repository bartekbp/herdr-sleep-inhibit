# herdr-sleep-inhibit

Keep a Linux machine awake while [herdr](https://github.com/herdr-dev/herdr) agent
panes are actively working, and let it sleep normally the rest of the time.

An AI coding agent can work unattended for many minutes with no keyboard or mouse
input. GNOME's idle timer is driven by input, not by CPU, network or terminal
output, so the desktop treats a busy agent as an idle machine and suspends it
mid-run: the turn dies, the network drops, and whatever the agent was doing is
lost.

## What it does

A daemon polls `herdr agent list` every 10 seconds. While at least one agent
reports `agent_status: working`, it holds a two-layer inhibitor:

```
systemd-inhibit --what=sleep --who=herdr --mode=block     # logind: suspend + IdleAction
  gnome-session-inhibit --inhibit suspend                 # gnome-settings-daemon's sleep-inactive-*-timeout
    marker process                                        # killed to release; both layers exit with it
```

Only `working` counts. A `blocked` agent is waiting on a human, and the human
being away is exactly when suspending is the right behavior.

The hold is released after `IDLE_GRACE` **consecutive** idle polls (60 s by
default), not on the first one. Agents dip out of `working` for a few seconds
between turns; releasing on every dip re-exposes the machine to an idle-suspend
timer that expired hours ago, because the inhibitor masks that timer rather than
resetting it.

By default the screen still blanks and locks on its normal timer -- only suspend
is inhibited. Set `INHIBIT_IDLE=1` if you want the screen kept awake too.

## Install

```sh
git clone https://github.com/bartekbp/herdr-sleep-inhibit
cd herdr-sleep-inhibit
./install.sh
```

That installs both entry points, which run the same script from this checkout:

- a **systemd user service** (`herdr-inhibit.service`) that starts with the
  graphical session, restarts on failure, and logs to the journal;
- the **herdr plugin**, whose `app.startup` / agent events start the daemon if
  nothing else has. Every start is deduplicated by a `flock`, so running both is
  not double coverage, it is a fallback.

Use `./install.sh --systemd` or `--plugin` for one of them only, and
`./install.sh --uninstall` to remove them.

Requirements: Linux with logind, `python3`, `flock`, and (for the GNOME layer)
`gnome-session-inhibit`. On a non-GNOME desktop the GNOME layer is skipped and
the logind layer still applies. macOS would need `caffeinate -i` instead of both;
the manifest declares `platforms = ["linux"]`.

## Use

```sh
sh inhibit.sh status     # daemon state, active hold, config, working agents
sh inhibit.sh logs       # journal when installed as a service, log file otherwise
sh inhibit.sh stop       # stop the daemon and release the hold
systemctl --user stop herdr-inhibit.service    # the same, via systemd
```

The same four are exposed as herdr plugin actions:

```sh
herdr plugin action invoke status --plugin sleep-inhibit
```

Note that a GNOME session inhibitor does **not** appear in `systemd-inhibit
--list`; the two layers are visible in two different places, which is why
`status` queries both.

## Configure

`install.sh` writes defaults to
`~/.config/herdr/plugins/config/sleep-inhibit/config.env`. See
[`config.env.example`](config.env.example) for every setting:

| Setting | Default | Meaning |
| --- | --- | --- |
| `POLL_SECONDS` | 10 | Seconds between agent-state polls |
| `IDLE_GRACE` | 6 | Consecutive idle polls before releasing |
| `INHIBIT_IDLE` | 0 | 1 also stops screen blank and lock |
| `INHIBIT_LID` | 0 | 1 also blocks suspend-on-lid-close |
| `MAX_HOLD_MINUTES` | 720 | Give up after this long; 0 disables |

## Failure modes it is built around

- **A missed event cannot cost you a run.** Plugin events only ever *start* the
  daemon; the daemon polls, so nothing has to be delivered on time for the hold
  to be taken.
- **A crash cannot pin the machine awake.** The hold is a child process chain of
  the daemon. Killing the marker tears down both inhibitors, `KillMode=control-group`
  reaps the chain if the daemon is SIGKILLed, and a new daemon clears any stale
  hold on startup.
- **A dead herdr server releases the hold.** Agent queries start failing, and a
  failed query counts as "not working".
- **A stuck agent releases the hold.** `MAX_HOLD_MINUTES` gives up on an agent
  that reports `working` forever, and does not re-acquire until agents next
  report idle.

## Test

```sh
sh tests/test-inhibit.sh
```

Runs the daemon against a stub herdr in its own state dir (so the live daemon is
untouched) and asserts that a hold registers a real logind inhibitor, survives a
short idle blip, is released after sustained idle with both layers gone, and does
not outlive the daemon.

## License

MIT
