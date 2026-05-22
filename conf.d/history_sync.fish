# fish-history-sync — defaults + prompt hook
# Triggers a backgrounded sync at most once per $history_sync_interval seconds,
# coordinated across fish sessions via the universal var __history_sync_last.

# Defaults are session-global so $HOME (and friends) re-resolve in each new
# shell. Users who want to override should `set -U history_sync_interval 600`
# explicitly — that universal value will win over our default.
set -q history_sync_backend; or set -g history_sync_backend sftp
set -q history_sync_interval; or set -g history_sync_interval 300
set -q history_sync_lock_ttl; or set -g history_sync_lock_ttl 120
set -q history_sync_max_retries; or set -g history_sync_max_retries 8
set -q history_sync_history_file; or set -g history_sync_history_file "$HOME/.local/share/fish/fish_history"

# git backend defaults
set -q history_sync_git_branch; or set -g history_sync_git_branch main
set -q history_sync_git_filename; or set -g history_sync_git_filename fish_history
if not set -q history_sync_git_workdir
    set -l __fhs_data $XDG_DATA_HOME
    test -n "$__fhs_data"; or set __fhs_data "$HOME/.local/share"
    set -g history_sync_git_workdir "$__fhs_data/fish-history-sync/repo"
end

function __history_sync_on_reload --on-variable __history_sync_reload
    # A peer session (or this shell's own backgrounded sync) just wrote new
    # entries to the history file. Pull them into this session's in-memory
    # history so they show up in search and recall without a shell reload.
    status is-interactive; or return
    history merge
end

function __history_sync_on_prompt --on-event fish_prompt
    set -l backend $history_sync_backend
    test -n "$backend"; or set backend sftp

    # Only trigger if the current backend is fully configured. Avoids waking
    # a sync that will just error out and write to the log every prompt.
    if not __history_sync_backend_configured $backend
        return
    end

    set -l now (date +%s)
    set -l last 0
    set -q __history_sync_last; and set last $__history_sync_last
    if test (math $now - $last) -lt $history_sync_interval
        return
    end

    # Claim the slot universally so peer sessions don't race us
    set -U __history_sync_last $now

    fish -c history_sync >/dev/null 2>&1 &
end

function __history_sync_uninstall --on-event history_sync_uninstall
    functions -e __history_sync_on_prompt
    functions -e __history_sync_on_reload
    # Erase every variable this plugin reads or writes so a fisher remove
    # leaves no trace. User config is included — re-running history_sync_setup
    # after re-install is cheap.
    set -e history_sync_backend
    set -e history_sync_interval
    set -e history_sync_lock_ttl
    set -e history_sync_max_retries
    set -e history_sync_history_file
    set -e history_sync_exclude_patterns
    set -e history_sync_host
    set -e history_sync_path
    set -e history_sync_port
    set -e history_sync_identity
    set -e history_sync_ssh_options
    set -e history_sync_s3_bucket
    set -e history_sync_s3_key
    set -e history_sync_s3_endpoint
    set -e history_sync_s3_region
    set -e history_sync_s3_profile
    set -e history_sync_git_url
    set -e history_sync_git_branch
    set -e history_sync_git_workdir
    set -e history_sync_git_filename
    set -e history_sync_git_shallow
    set -e __history_sync_last
    set -e __history_sync_reload
    set -e __history_sync_last_attempt
    set -e __history_sync_last_success
    set -e __history_sync_last_error
    set -e __history_sync_lock_owned
    set -e __history_sync_verbose
end
