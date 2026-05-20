function __history_sync_sftp_push --description "SFTP backend: upload merged file + release remote lock"
    set -l local_src $argv[1]
    # $argv[2] is the state token, unused for SFTP (lock is held across pull+push).

    __history_sync_log "uploading merged history"
    set -l up_err (mktemp /tmp/fhs_uperr.XXXXXX)
    set -l remote_tmp "$history_sync_path.upload.tmp.$fish_pid"
    set -l upload_batch "put \"$local_src\" \"$remote_tmp\"
-rm \"$history_sync_path\"
rename \"$remote_tmp\" \"$history_sync_path\""
    set -l rc 0
    if printf '%s\n' $upload_batch | __history_sync_sftp >/dev/null 2>$up_err
        __history_sync_log "  upload OK"
    else
        __history_sync_log "  upload FAILED"
        test "$__history_sync_verbose" = 1; and sed 's/^/  sftp: /' $up_err >&2
        set rc 2
    end
    rm -f $up_err

    __history_sync_log "releasing remote lock"
    __history_sync_release_lock

    return $rc
end
