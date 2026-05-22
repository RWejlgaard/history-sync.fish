function history_sync --description "Run one fish history sync cycle"
    argparse v/verbose f/force q/quiet h/help -- $argv
    or return 2

    if set -q _flag_help
        echo "usage: history_sync [-v|--verbose] [-f|--force] [-q|--quiet]"
        echo "  Sync fish history with the configured remote backend."
        echo "  -v  verbose progress on stderr"
        echo "  -f  force: clear local + remote locks before syncing (sftp backend)"
        echo "  -q  quiet: suppress 'not configured' stderr noise (still records to log)"
        return 0
    end

    set -g __history_sync_verbose 0
    set -q _flag_verbose; and set -g __history_sync_verbose 1

    set -l quiet 0
    set -q _flag_quiet; and set quiet 1

    set -l backend $history_sync_backend
    test -n "$backend"; or set backend sftp

    if not __history_sync_backend_configured $backend
        if test $quiet -eq 0
            echo "history_sync: backend '$backend' not configured (run history_sync_setup)" >&2
        end
        __history_sync_record fail "backend '$backend' not configured"
        return 2
    end

    set -l history_file $history_sync_history_file
    test -n "$history_file"; or set history_file "$HOME/.local/share/fish/fish_history"

    __history_sync_log "starting sync: backend=$backend"

    set -l tmpdir $TMPDIR
    test -n "$tmpdir"; or set tmpdir /tmp
    set -l local_lock $tmpdir/fish_history_sync.(id -u).lock

    if set -q _flag_force
        __history_sync_log "force: clearing local + remote locks"
        rm -rf $local_lock
        if functions -q __history_sync_{$backend}_force_unlock
            __history_sync_{$backend}_force_unlock
        end
    end

    # Per-machine lock: avoid two concurrent syncs from this host even if
    # multiple fish sessions wake up at once. mkdir is atomic — only one
    # caller wins when two race.
    if not mkdir $local_lock 2>/dev/null
        set -l old_pid (cat $local_lock/pid 2>/dev/null)
        if test -n "$old_pid"; and kill -0 $old_pid 2>/dev/null
            __history_sync_log "another sync is in progress (pid $old_pid); skipping"
            return 0
        end
        __history_sync_log "found stale local lock (pid $old_pid); reclaiming"
        rm -rf $local_lock
        if not mkdir $local_lock 2>/dev/null
            __history_sync_log "another sync raced past stale lock; skipping"
            return 0
        end
    end
    echo $fish_pid >$local_lock/pid

    set -l rc 0
    __history_sync_run; or set rc $status

    rm -rf $local_lock
    __history_sync_log "sync finished with status $rc"
    if test $rc -eq 0
        __history_sync_record ok ""
    else
        __history_sync_record fail "sync exited with status $rc"
    end
    return $rc
end

function __history_sync_run --description "Internal: pull, merge, push (with CAS retry on conflict)"
    set -l history_file $history_sync_history_file
    test -n "$history_file"; or set history_file "$HOME/.local/share/fish/fish_history"
    set -l hist_dir (dirname $history_file)

    set -l remote_dl (__history_sync_tmp remote)
    set -l merged (__history_sync_tmp merged)

    set -l state (__history_sync_backend pull $remote_dl)
    or begin
        rm -f $remote_dl $merged
        return 1
    end

    # Snapshot local at this instant so concurrent shells writing to
    # fish_history don't have their lines truncated by our merge.
    set -l local_snapshot (__history_sync_tmp local)
    if test -e $history_file
        cp $history_file $local_snapshot
    else
        : >$local_snapshot
    end

    set -l local_entries (grep -c '^- cmd:' $local_snapshot 2>/dev/null)
    test -n "$local_entries"; or set local_entries 0
    set -l remote_entries (grep -c '^- cmd:' $remote_dl 2>/dev/null)
    test -n "$remote_entries"; or set remote_entries 0
    __history_sync_log "merging: local=$local_entries entries, remote=$remote_entries entries"

    if not __history_sync_merge $local_snapshot $remote_dl $merged
        __history_sync_log "merge failed"
        rm -f $remote_dl $merged $local_snapshot
        __history_sync_backend abort $state
        return 1
    end

    # Re-snapshot the live history_file to catch anything fish appended
    # while the first merge was running, then write to a sibling file so the
    # rename is a true rename(2) on the same filesystem.
    set -l live_snapshot (__history_sync_tmp live)
    if test -e $history_file
        cp $history_file $live_snapshot
    else
        : >$live_snapshot
    end

    set -l final (mktemp "$hist_dir/.fhs_final.XXXXXX")
    if not __history_sync_merge $merged $live_snapshot $final
        __history_sync_log "final merge failed"
        rm -f $remote_dl $merged $local_snapshot $live_snapshot $final
        __history_sync_backend abort $state
        return 1
    end

    set -l final_entries (grep -c '^- cmd:' $final 2>/dev/null)
    test -n "$final_entries"; or set final_entries 0
    __history_sync_log "merged: $final_entries entries"

    set -l rc 0
    if test -s $final
        mv $final $history_file
        __history_sync_log "wrote local $history_file"

        # Push with CAS retry. SFTP holds a lock so push_cas never reports
        # conflict; S3 and git can, in which case we re-pull and re-merge.
        set -l cas_max 3
        set -l cas_attempt 0
        while true
            set cas_attempt (math $cas_attempt + 1)
            __history_sync_backend push $history_file $state
            set -l push_rc $status

            if test $push_rc -eq 0
                break
            else if test $push_rc -eq 1
                # CAS conflict: remote moved underneath us
                if test $cas_attempt -ge $cas_max
                    __history_sync_log "push: too many CAS conflicts ($cas_max); giving up"
                    set rc 1
                    break
                end
                __history_sync_log "push: CAS conflict (attempt $cas_attempt), re-pulling"
                set -l remote_dl2 (__history_sync_tmp remote)
                set state (__history_sync_backend pull $remote_dl2)
                if test $status -ne 0
                    rm -f $remote_dl2
                    set rc 1
                    break
                end
                set -l remerge (mktemp "$hist_dir/.fhs_final.XXXXXX")
                if not __history_sync_merge $history_file $remote_dl2 $remerge
                    rm -f $remote_dl2 $remerge
                    __history_sync_backend abort $state
                    set rc 1
                    break
                end
                mv $remerge $history_file
                rm -f $remote_dl2
                # Loop and retry push with new state
            else
                __history_sync_log "push: hard error"
                set rc 1
                break
            end
        end
    else
        __history_sync_log "merged file is empty; skipping write"
        __history_sync_backend abort $state
    end

    rm -f $remote_dl $merged $local_snapshot $live_snapshot $final 2>/dev/null

    # Tell every live fish session to re-read history. Universal variable
    # write fans out and triggers __history_sync_on_reload in each session.
    # Only bump when entries actually changed so quiet ticks don't churn.
    if test $rc -eq 0
        set -l on_disk_entries (grep -c '^- cmd:' $history_file 2>/dev/null)
        test -n "$on_disk_entries"; or set on_disk_entries 0
        if test $on_disk_entries -ne $local_entries
            set -U __history_sync_reload (date +%s)-$fish_pid
            __history_sync_log "signalled reload (entries $local_entries -> $on_disk_entries)"
        end
    end

    return $rc
end
