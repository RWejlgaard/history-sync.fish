function __history_sync_log --description "Emit a verbose log line to stderr when verbose mode is on"
    set -q __history_sync_verbose; or return 0
    test "$__history_sync_verbose" = 1; or return 0
    echo "[history_sync] $argv" >&2
end
