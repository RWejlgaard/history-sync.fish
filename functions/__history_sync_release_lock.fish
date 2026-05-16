function __history_sync_release_lock --description "Release the remote SFTP lock if we own it"
    set -q __history_sync_lock_owned; or return 0
    test "$__history_sync_lock_owned" = 1; or return 0
    printf '%s\n' "-rm $history_sync_path.lock" | __history_sync_sftp >/dev/null 2>&1
    set -g __history_sync_lock_owned 0
end
