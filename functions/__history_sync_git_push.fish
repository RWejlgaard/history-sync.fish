function __history_sync_git_push --description "Git backend: commit + push, returns 1 on non-fast-forward (CAS conflict)"
    set -l local_src $argv[1]
    # $argv[2] is the state token (HEAD sha at pull) — we don't need it; the
    # CAS check is "did the remote ref move since our last fetch", enforced
    # server-side by git push.

    if not command -q git
        echo "history_sync: 'git' CLI not found on PATH (required for git backend)" >&2
        return 2
    end

    set -l workdir $history_sync_git_workdir
    set -l branch $history_sync_git_branch
    set -l filename $history_sync_git_filename
    test -n "$branch"; or set branch main
    test -n "$filename"; or set filename fish_history

    cp $local_src $workdir/$filename; or return 2

    if not git -C $workdir add -- $filename >/dev/null 2>&1
        __history_sync_log "git add FAILED"
        return 2
    end

    # If nothing changed vs HEAD, skip the commit + push entirely. This is the
    # big win for the git backend — most prompt-hook syncs produce zero commits.
    if git -C $workdir diff --cached --quiet -- $filename >/dev/null 2>&1
        __history_sync_log "git: no diff vs HEAD; skipping commit + push"
        return 0
    end

    set -l host_id (hostname -s 2>/dev/null; or uname -n)
    set host_id (string replace -ra '[^A-Za-z0-9_.-]' '_' -- $host_id)
    test -n "$host_id"; or set host_id unknown

    set -l err (__history_sync_tmp giterr)
    # -c flags keep the commit attributable to this plugin without depending
    # on the user's global git identity (which may not exist on a fresh host).
    if not git -C $workdir \
            -c user.name=fish-history-sync \
            -c user.email=fish-history-sync@$host_id \
            -c commit.gpgsign=false \
            commit -q -m "sync from $host_id" >/dev/null 2>$err
        __history_sync_log "git commit FAILED"
        test "$__history_sync_verbose" = 1; and sed 's/^/  git: /' $err >&2
        rm -f $err
        return 2
    end

    __history_sync_log "git: pushing to origin $branch"
    if git -C $workdir push origin HEAD:$branch >/dev/null 2>$err
        __history_sync_log "  push OK"
        rm -f $err
        return 0
    end

    # Non-fast-forward / rejected = CAS conflict; outer loop will re-pull + re-merge.
    if grep -qE 'non-fast-forward|fetch first|rejected.*remote contains|stale info|cannot lock ref' $err
        __history_sync_log "  CAS conflict (push rejected)"
        test "$__history_sync_verbose" = 1; and sed 's/^/  git: /' $err >&2
        rm -f $err
        return 1
    end

    __history_sync_log "  push FAILED"
    test "$__history_sync_verbose" = 1; and sed 's/^/  git: /' $err >&2
    rm -f $err
    return 2
end
