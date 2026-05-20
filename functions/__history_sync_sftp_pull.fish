function __history_sync_sftp_pull --description "SFTP backend: acquire remote lock + download shared file"
    set -l local_dest $argv[1]

    __history_sync_log "acquiring remote lock"
    if not __history_sync_acquire_lock
        __history_sync_log "failed to acquire remote lock"
        return 1
    end
    __history_sync_log "remote lock acquired"

    __history_sync_log "downloading $history_sync_path"
    set -l dl_err (mktemp /tmp/fhs_dlerr.XXXXXX)
    if printf '%s\n' "get \"$history_sync_path\" \"$local_dest\"" | __history_sync_sftp >/dev/null 2>$dl_err
        __history_sync_log "  downloaded $(wc -c <$local_dest) bytes"
    else
        __history_sync_log "  remote file not found or unreadable; starting from empty"
        test "$__history_sync_verbose" = 1; and sed 's/^/  sftp: /' $dl_err >&2
        : >$local_dest
    end
    rm -f $dl_err

    # State token is unused for SFTP — the lock IS the mutex, held until push.
    echo sftp
    return 0
end
