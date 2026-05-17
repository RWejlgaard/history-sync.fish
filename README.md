# history-sync.fish

Sync fish shell history between multiple machines over SFTP.

Each machine periodically pulls the shared history file, merges with its
local `fish_history`, and pushes the result back. The merge dedupes by
`(cmd, when)` and sorts by timestamp, so the same plugin running on every
machine converges to the same history regardless of order.

## How it works

- A `fish_prompt` event hook checks how long it's been since the last sync.
- If `history_sync_interval` seconds have elapsed, it spawns `history_sync`
  in the background — your prompt is never blocked.
- `history_sync` takes a remote lock (via SFTP `put` + atomic `rename`),
  downloads the remote file, merges with the local file, writes both back,
  and releases the lock.
- Concurrent updates from other hosts are handled by retrying with
  exponential backoff. A lock older than `history_sync_lock_ttl` seconds
  is presumed stale and broken.

## Install

### fisher

```fish
fisher install RWejlgaard/history-sync.fish
```

To update later:

```fish
fisher update RWejlgaard/history-sync.fish
```

To uninstall:

```fish
fisher remove RWejlgaard/history-sync.fish
```

### manual

```fish
git clone https://github.com/RWejlgaard/history-sync.fish.git
cp history-sync.fish/conf.d/*.fish ~/.config/fish/conf.d/
cp history-sync.fish/functions/*.fish ~/.config/fish/functions/
```

## Setup

You need SSH key access to the host (password auth won't work — the
background sync sets `BatchMode=yes` so it can never hang on a prompt).
Verify `sftp user@host` works without typing a password first.

Then:

```fish
history_sync_setup
```

This prompts for host, remote path, and interval, saves them as fish
universal variables (persist across sessions), and tests the connection.

Run the same setup on every machine you want to sync, pointing them all
at the same host and path.

## Commands

| command | purpose |
|---|---|
| `history_sync_setup` | interactive config |
| `history_sync_status` | show current config + last sync + remote lock state |
| `history_sync` | force a sync right now (`-v` verbose, `-f` clear stale local + remote locks first) |

## Configuration (universal variables)

| var | default | meaning |
|---|---|---|
| `history_sync_host` | _required_ | `user@host` or `host` for SFTP |
| `history_sync_path` | _required_ | remote path of the shared history file (setup default: `.local/share/fish/fish_history`, relative to remote `$HOME`) |
| `history_sync_interval` | `300` | seconds between prompt-hook syncs |
| `history_sync_lock_ttl` | `120` | seconds before a stale lock can be broken |
| `history_sync_max_retries` | `8` | attempts to acquire the remote lock |
| `history_sync_port` | (default 22) | SSH port |
| `history_sync_identity` | (ssh-agent) | path to SSH key |
| `history_sync_ssh_options` | (none) | extra `-o` options, e.g. `(ProxyJump=bastion)` |
| `history_sync_history_file` | `~/.local/share/fish/fish_history` | local history file path |

Set any of these directly with `set -U history_sync_interval 600` etc.

> Note: `history_sync_path` must NOT start with `~/` — sftp batch commands
> don't expand the tilde. Use a path relative to the remote home directory
> (e.g. `.local/share/fish/fish_history`) or an absolute path.

## Contributing

All changes land via PRs. PR titles follow Conventional Commits — the
release workflow uses the title to decide the next version when the PR
is merged to `main`:

| PR title prefix | bump | example |
|---|---|---|
| `major:` (or `!:`) | major | `major: rewrite sync engine` → `v1.2.3` → `v2.0.0` |
| `feat:` | minor | `feat: add --force flag` → `v1.2.3` → `v1.3.0` |
| `fix:` | patch | `fix: lock acquisition race` → `v1.2.3` → `v1.2.4` |
| `chore:` | _no release_ | `chore: bump CI action` |

Optional scope (`feat(setup): ...`) and breaking marker (`feat!: ...`) are
allowed. Anything else fails the workflow.

Each release publishes three tags pointing at the same commit:

- `vX.Y.Z` — immutable per-release tag
- `vX.Y` — floating, moves with each patch
- `vX` — floating, moves with each minor or patch

Pin in `fisher` to whichever level of stability you want.

## Caveats

- The plugin **never deletes** history entries. If you want to forget a
  command everywhere, run `history delete` on every machine before they
  next sync.
- Local history writes during a sync are preserved by re-merging with
  the live file just before write.
- The remote stores history in the same fish format. You can `scp` it
  down to bootstrap a new machine, or just let the first sync from that
  machine union everything together.
- If `sftp` ever hangs (e.g. host unreachable), the background sync stays
  blocked — but a new sync won't start because the local PID lock detects
  the running one. The hung process is harmless and will eventually exit
  via SSH's `ConnectTimeout` (the plugin sets this to 10s).
- After `fisher update`, existing long-lived fish sessions keep running
  the *old* prompt hook from memory until they restart. New shells pick
  up the new version automatically; old shells need a `exec fish` (or
  just a normal exit) to refresh.
- Stale lock detection uses the breaker's own clock (it waits until *it*
  has observed the same lock for longer than `history_sync_lock_ttl`),
  so cross-machine clock skew won't cause spurious lock breaking.
- Sync failures are recorded in the universal vars
  `__history_sync_last_success` and `__history_sync_last_error`, and an
  append-only log lives at `~/.cache/fish-history-sync/sync.log`.
  Run `history_sync_status` to see the current state at a glance.
