function __history_sync_sftp --description "Run an sftp batch (commands from stdin) against the configured host"
    # ConnectTimeout caps cold-connect time; ServerAlive* hangs up dead
    # mid-transfer sessions so background syncs never wedge forever.
    set -l args -q -b - \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o ServerAliveInterval=15 \
        -o ServerAliveCountMax=2
    if set -q history_sync_port; and test -n "$history_sync_port"
        set -a args -P $history_sync_port
    end
    if set -q history_sync_identity; and test -n "$history_sync_identity"
        set -a args -i $history_sync_identity
    end
    if set -q history_sync_ssh_options; and test -n "$history_sync_ssh_options"
        for opt in $history_sync_ssh_options
            set -a args -o $opt
        end
    end
    sftp $args $history_sync_host
end
