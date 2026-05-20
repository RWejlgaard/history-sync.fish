# history-sync.fish

Sync fish shell history between multiple machines over SFTP, S3-compatible
object storage, or a private git repo.

Each machine periodically pulls the shared history, merges with its local
`fish_history`, and pushes the result back. The merge dedupes by
`(cmd, when)` and sorts by timestamp, so the same plugin running on every
machine converges to the same history regardless of order or backend.

## How it works

- A `fish_prompt` event hook checks how long it's been since the last sync.
- If `history_sync_interval` seconds have elapsed, it spawns `history_sync`
  in the background — your prompt is never blocked.
- The configured backend does a pull → merge → push cycle. Concurrency is
  handled per backend:
  - **sftp** holds an `*.lock` file via atomic SFTP `rename` and breaks
    stale locks by TTL.
  - **s3** uses S3 conditional writes (`If-Match: <etag>` / `If-None-Match`)
    — no lock file needed.
  - **git** relies on git push's ref CAS; non-fast-forward rejections
    trigger a re-pull + re-merge.

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

```fish
history_sync_setup
```

The wizard asks which backend to use, prompts for the per-backend config,
tests the connection, and saves everything as fish universal variables.

Run the same setup on every machine you want to sync, pointing them all at
the same destination.

## Backends

| backend | needs | concurrency primitive | best for |
|---|---|---|---|
| `sftp` | SSH key access to an SFTP host | atomic `rename` lock + TTL | you have a server you SSH into |
| `s3` | `aws` CLI + bucket access | S3 conditional writes | you don't want to run a server; works with AWS, Cloudflare R2, Backblaze B2, MinIO |
| `git` | `git` CLI + a private repo | `git push` ref CAS | you want an audit trail / use existing git hosting |

Switch backend with `set -U history_sync_backend sftp\|s3\|git` and re-run
`history_sync_setup`.

### SFTP setup notes

SSH key auth only — the background sync sets `BatchMode=yes` so it can
never hang on a prompt. Verify `sftp user@host` works without a password
first.

### S3 setup notes

The `aws` CLI must be on PATH and able to authenticate (env vars,
`~/.aws/credentials`, IAM role, or `--profile`). The backend uses the S3
conditional-write headers added in late 2024 — AWS S3, Cloudflare R2,
Backblaze B2, and MinIO all support them.

### git setup notes

The `git` CLI must be on PATH. The plugin maintains a small local clone
at `$history_sync_git_workdir`; `fisher remove` does **not** delete it.
Most prompt-hook syncs produce no commit (the plugin skips the commit
when the file hasn't changed), but over time the repo grows — set
`history_sync_git_shallow=true` to clone with `--depth=100`, or run
`git gc --aggressive` in the workdir periodically.

## Commands

| command | purpose |
|---|---|
| `history_sync_setup` | interactive config |
| `history_sync_status` | show current config + last sync + recent log tail; exit non-zero if last attempt failed |
| `history_sync` | force a sync now (`-v` verbose, `-f` clear stale local + remote locks first, `-q` quiet) |
| `history_sync_purge <regex>` | strip matching entries from remote + local; `-a` also persists the regex into `history_sync_exclude_patterns` |

## Configuration (universal variables)

### common

| var | default | meaning |
|---|---|---|
| `history_sync_backend` | `sftp` | one of `sftp`, `s3`, `git` |
| `history_sync_interval` | `300` | seconds between prompt-hook syncs |
| `history_sync_history_file` | `~/.local/share/fish/fish_history` | local history file path |
| `history_sync_exclude_patterns` | _empty_ | list of POSIX-ERE regexes; entries whose `cmd` matches any of them are dropped during merge (both directions) |

### sftp backend

| var | default | meaning |
|---|---|---|
| `history_sync_host` | _required_ | `user@host` or `host` for SFTP |
| `history_sync_path` | _required_ | remote path of the shared history file. Must NOT start with `~/` (sftp batch doesn't expand it). Use a relative path or absolute path |
| `history_sync_port` | (default 22) | SSH port |
| `history_sync_identity` | (ssh-agent) | path to SSH key |
| `history_sync_ssh_options` | (none) | extra `-o` options, e.g. `set -U history_sync_ssh_options ProxyJump=bastion` |
| `history_sync_lock_ttl` | `120` | seconds before a stale remote lock can be broken |
| `history_sync_max_retries` | `8` | lock-acquire attempts |

### s3 backend

| var | default | meaning |
|---|---|---|
| `history_sync_s3_bucket` | _required_ | bucket name |
| `history_sync_s3_key` | `fish_history` | object key |
| `history_sync_s3_endpoint` | _AWS default_ | endpoint URL — set for R2/B2/MinIO |
| `history_sync_s3_region` | _aws CLI default_ | region |
| `history_sync_s3_profile` | _aws CLI default_ | aws profile name |

### git backend

| var | default | meaning |
|---|---|---|
| `history_sync_git_url` | _required_ | git remote URL (SSH or HTTPS) |
| `history_sync_git_branch` | `main` | branch to use |
| `history_sync_git_workdir` | `$XDG_DATA_HOME/fish-history-sync/repo` | local clone path |
| `history_sync_git_filename` | `fish_history` | filename inside the repo |
| `history_sync_git_shallow` | _unset_ | set to `true` to clone with `--depth=100` |

Set any of these directly with `set -U history_sync_interval 600` etc. —
useful if you want to provision the plugin from dotfiles without running
`history_sync_setup`.

## Excludes & secret handling

`history_sync_exclude_patterns` is a list of POSIX ERE regexes; any entry
whose `cmd` matches **any** of them is dropped during merge. Stripping
happens both for the file going up to the remote AND the file written
back to local, so old secrets in your local history get cleaned on the
next sync too.

`history_sync_setup` offers to install a recommended starter set:

```
(api[_-]?key|secret|password|token)=
Bearer\s+[A-Za-z0-9._-]{20,}
ghp_[A-Za-z0-9]{36}
gho_[A-Za-z0-9]{36}
ghs_[A-Za-z0-9]{36}
sk-[A-Za-z0-9]{20,}
AKIA[0-9A-Z]{16}
```

To recover after a secret has already synced everywhere:

```fish
# Strip it locally + remotely, AND remember the pattern so future syncs
# never resurrect it
history_sync_purge -a 'my-leaked-secret-prefix'

# Then run history_sync on every other machine; the merge there will
# drop the pattern too.
```

## Releases & contributing

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

- The plugin **never deletes** history entries by default — running
  `history delete` on one machine only purges locally. Use
  `history_sync_purge` (or add the offending pattern to
  `history_sync_exclude_patterns`) to remove cross-machine.
- Local history writes during a sync are preserved by re-merging with
  the live file just before write.
- The remote stores history in the same fish format. You can `scp` /
  download it to bootstrap a new machine, or just let the first sync
  from that machine union everything together.
- **Synced entries don't appear in your current shell** until it reloads
  fish's history. Fish caches `fish_history` in memory and only re-reads
  on `history merge` or shell restart. New shells pick them up
  automatically; existing shells need `history merge` (or `exec fish`).
- If a backend operation hangs (e.g. host unreachable), the background
  sync stays blocked — but a new sync won't start because the local PID
  lock detects the running one. The hung process is harmless and will
  eventually exit via the underlying tool's timeout (SFTP sets
  `ConnectTimeout=10`, git/aws default to a few minutes).
- After `fisher update`, existing long-lived fish sessions keep running
  the *old* prompt hook from memory until they restart.
- SFTP stale-lock detection uses the breaker's own clock so cross-machine
  clock skew can't cause spurious lock breaking.
- S3 and git backends rely on server-side CAS — no lock file, so there's
  nothing to leak or break.
- Sync failures are recorded in the universal vars
  `__history_sync_last_success` and `__history_sync_last_error`, and an
  append-only log lives at `~/.cache/fish-history-sync/sync.log`.
  Run `history_sync_status` to see the current state at a glance.
