function history_sync_status --description "Show fish-history-sync configuration and state"
    echo "fish-history-sync status"
    echo "  host:         "(set -q history_sync_host; and echo $history_sync_host; or echo "(unset)")
    echo "  path:         "(set -q history_sync_path; and echo $history_sync_path; or echo "(unset)")
    echo "  port:         "(set -q history_sync_port; and echo $history_sync_port; or echo "(default)")
    echo "  identity:     "(set -q history_sync_identity; and echo $history_sync_identity; or echo "(ssh-agent / default)")
    echo "  interval:     $history_sync_interval s"
    echo "  lock TTL:     $history_sync_lock_ttl s"
    echo "  max retries:  $history_sync_max_retries"
    echo "  history file: $history_sync_history_file"

    if set -q __history_sync_last
        set -l now (date +%s)
        set -l ago (math $now - $__history_sync_last)
        echo "  last sync:    $__history_sync_last ($ago s ago)"
    else
        echo "  last sync:    never"
    end

    if set -q history_sync_host; and set -q history_sync_path
        echo
        echo "Probing remote lock..."
        set -l probe (mktemp /tmp/fhs_probe.XXXXXX)
        if printf '%s\n' "get $history_sync_path.lock $probe" | __history_sync_sftp >/dev/null 2>&1
            echo "  remote lock IS held:"
            sed 's/^/    /' $probe
        else
            echo "  remote lock not held"
        end
        rm -f $probe
    end
end
