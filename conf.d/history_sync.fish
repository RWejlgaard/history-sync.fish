# fish-history-sync — defaults + prompt hook
# Triggers a backgrounded sync at most once per $history_sync_interval seconds,
# coordinated across fish sessions via the universal var __history_sync_last.

# Defaults are session-global so $HOME (and friends) re-resolve in each new
# shell. Users who want to override should `set -U history_sync_interval 600`
# explicitly — that universal value will win over our default.
set -q history_sync_interval; or set -g history_sync_interval 300
set -q history_sync_lock_ttl; or set -g history_sync_lock_ttl 120
set -q history_sync_max_retries; or set -g history_sync_max_retries 8
set -q history_sync_history_file; or set -g history_sync_history_file "$HOME/.local/share/fish/fish_history"

function __history_sync_on_prompt --on-event fish_prompt
    set -q history_sync_host; or return
    set -q history_sync_path; or return
    test -n "$history_sync_host"; or return
    test -n "$history_sync_path"; or return

    set -l now (date +%s)
    set -l last 0
    set -q __history_sync_last; and set last $__history_sync_last
    if test (math $now - $last) -lt $history_sync_interval
        return
    end

    # Claim the slot universally so peer sessions don't race us
    set -U __history_sync_last $now

    fish -c history_sync >/dev/null 2>&1 &
    disown 2>/dev/null
end

function __history_sync_uninstall --on-event history_sync_uninstall
    functions -e __history_sync_on_prompt
    # Erase every variable this plugin reads or writes so a fisher remove
    # leaves no trace. User config (host/path/etc.) is included — re-running
    # history_sync_setup after re-install is cheap.
    set -e history_sync_interval
    set -e history_sync_lock_ttl
    set -e history_sync_max_retries
    set -e history_sync_history_file
    set -e history_sync_host
    set -e history_sync_path
    set -e history_sync_port
    set -e history_sync_identity
    set -e history_sync_ssh_options
    set -e __history_sync_last
    set -e __history_sync_last_attempt
    set -e __history_sync_last_success
    set -e __history_sync_last_error
    set -e __history_sync_lock_owned
    set -e __history_sync_verbose
end
