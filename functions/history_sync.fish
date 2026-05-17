function history_sync --description "Run one fish history sync cycle"
    argparse 'v/verbose' 'f/force' 'h/help' -- $argv
    or return 2

    if set -q _flag_help
        echo "usage: history_sync [-v|--verbose] [-f|--force]"
        echo "  Sync fish history with the configured SFTP host."
        echo "  -v  verbose progress on stderr"
        echo "  -f  force: clear local + remote locks before syncing"
        return 0
    end

    set -g __history_sync_verbose 0
    set -q _flag_verbose; and set -g __history_sync_verbose 1

    if not set -q history_sync_host; or test -z "$history_sync_host"
        echo "history_sync: history_sync_host not set (run history_sync_setup)" >&2
        __history_sync_record fail "history_sync_host not set"
        return 2
    end
    if not set -q history_sync_path; or test -z "$history_sync_path"
        echo "history_sync: history_sync_path not set (run history_sync_setup)" >&2
        __history_sync_record fail "history_sync_path not set"
        return 2
    end

    set -l history_file $history_sync_history_file
    test -n "$history_file"; or set history_file "$HOME/.local/share/fish/fish_history"

    __history_sync_log "starting sync: host=$history_sync_host path=$history_sync_path"

    set -l local_lock /tmp/fish_history_sync.(id -u).pid

    if set -q _flag_force
        __history_sync_log "force: clearing local + remote locks"
        rm -f $local_lock
        printf '%s\n' "-rm \"$history_sync_path.lock\"" | __history_sync_sftp >/dev/null 2>&1
    else
        # Per-machine lock: avoid two concurrent syncs from this host even if
        # multiple fish sessions wake up at once.
        if test -e $local_lock
            set -l old_pid (cat $local_lock 2>/dev/null)
            if test -n "$old_pid"; and kill -0 $old_pid 2>/dev/null
                __history_sync_log "another sync is in progress (pid $old_pid); skipping"
                return 0
            end
            __history_sync_log "found stale local lock (pid $old_pid), taking it"
        end
    end
    echo $fish_pid >$local_lock

    set -l rc 0
    __history_sync_run; or set rc $status

    rm -f $local_lock
    __history_sync_log "sync finished with status $rc"
    if test $rc -eq 0
        __history_sync_record ok ""
    else
        __history_sync_record fail "sync exited with status $rc"
    end
    return $rc
end

function __history_sync_run --description "Internal: do the lock/download/merge/upload dance"
    set -l history_file $history_sync_history_file
    test -n "$history_file"; or set history_file "$HOME/.local/share/fish/fish_history"

    __history_sync_log "acquiring remote lock"
    if not __history_sync_acquire_lock
        __history_sync_log "failed to acquire remote lock"
        return 1
    end
    __history_sync_log "remote lock acquired"

    set -l remote_dl (mktemp /tmp/fhs_remote.XXXXXX)
    set -l merged (mktemp /tmp/fhs_merged.XXXXXX)
    set -l rc 0

    # Pull remote. If it doesn't exist yet (first sync from any host) the
    # get fails but we proceed with just the local file as the merge input.
    __history_sync_log "downloading $history_sync_path"
    set -l dl_err (mktemp /tmp/fhs_dlerr.XXXXXX)
    if printf '%s\n' "get \"$history_sync_path\" \"$remote_dl\"" | __history_sync_sftp >/dev/null 2>$dl_err
        __history_sync_log "  downloaded $(wc -c <$remote_dl) bytes"
    else
        __history_sync_log "  remote file not found or unreadable; starting from empty"
        test "$__history_sync_verbose" = 1; and sed 's/^/  sftp: /' $dl_err >&2
        : >$remote_dl
    end
    rm -f $dl_err

    # Snapshot local at this instant so concurrent shells writing to
    # fish_history don't have their lines truncated by our merge.
    set -l local_snapshot (mktemp /tmp/fhs_local.XXXXXX)
    if test -e $history_file
        cp $history_file $local_snapshot
    else
        : >$local_snapshot
    end

    set -l local_entries 0
    grep -c '^- cmd:' $local_snapshot 2>/dev/null | read local_entries
    set -l remote_entries 0
    grep -c '^- cmd:' $remote_dl 2>/dev/null | read remote_entries
    __history_sync_log "merging: local=$local_entries entries, remote=$remote_entries entries"

    if not __history_sync_merge $local_snapshot $remote_dl $merged
        __history_sync_log "merge failed"
        rm -f $remote_dl $merged $local_snapshot
        __history_sync_release_lock
        return 1
    end

    # Re-snapshot the live history_file to catch anything fish appended
    # while the first merge was running. Final merge reads two static
    # files, then we atomic-rename — minimal window for command loss.
    set -l live_snapshot (mktemp /tmp/fhs_live.XXXXXX)
    if test -e $history_file
        cp $history_file $live_snapshot
    else
        : >$live_snapshot
    end

    # Write the final merge next to history_file so the rename is a true
    # rename(2) on the same filesystem (not a copy across /tmp boundary).
    set -l hist_dir (dirname $history_file)
    set -l final (mktemp "$hist_dir/.fhs_final.XXXXXX")
    if not __history_sync_merge $merged $live_snapshot $final
        __history_sync_log "final merge failed"
        rm -f $remote_dl $merged $local_snapshot $live_snapshot $final
        __history_sync_release_lock
        return 1
    end

    set -l final_entries 0
    grep -c '^- cmd:' $final 2>/dev/null | read final_entries
    __history_sync_log "merged: $final_entries entries"

    if test -s $final
        # Atomic same-filesystem rename — no reader ever sees a partial file.
        mv $final $history_file
        __history_sync_log "wrote local $history_file"

        # Upload to a temp path, then rename over the real one
        __history_sync_log "uploading merged history"
        set -l up_err (mktemp /tmp/fhs_uperr.XXXXXX)
        set -l remote_tmp "$history_sync_path.upload.tmp.$fish_pid"
        set -l upload_batch "put \"$history_file\" \"$remote_tmp\"
-rm \"$history_sync_path\"
rename \"$remote_tmp\" \"$history_sync_path\""
        if printf '%s\n' $upload_batch | __history_sync_sftp >/dev/null 2>$up_err
            __history_sync_log "  upload OK"
        else
            __history_sync_log "  upload FAILED"
            test "$__history_sync_verbose" = 1; and sed 's/^/  sftp: /' $up_err >&2
            set rc 1
        end
        rm -f $up_err
    else
        __history_sync_log "merged file is empty; skipping write"
    end

    rm -f $remote_dl $merged $local_snapshot $live_snapshot $final

    __history_sync_log "releasing remote lock"
    __history_sync_release_lock

    return $rc
end
