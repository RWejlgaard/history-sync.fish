function __history_sync_git_pull --description "Git backend: fetch + reset to remote tip, copy file out, capture HEAD sha"
    set -l local_dest $argv[1]

    if not command -q git
        echo "history_sync: 'git' CLI not found on PATH (required for git backend)" >&2
        return 1
    end

    set -l workdir $history_sync_git_workdir
    set -l branch $history_sync_git_branch
    set -l filename $history_sync_git_filename
    test -n "$branch"; or set branch main
    test -n "$filename"; or set filename fish_history

    __history_sync_git_init; or return 1

    __history_sync_log "git: fetching origin/$branch"
    set -l err (mktemp /tmp/fhs_giterr.XXXXXX)
    # Keep git's stdout out of our caller's command substitution — the state
    # token is what we echo at the end, and "HEAD is now at..." would mix in.
    if git -C $workdir fetch origin $branch >/dev/null 2>$err
        if not git -C $workdir reset --hard FETCH_HEAD -- >/dev/null 2>$err
            __history_sync_log "  reset --hard FAILED"
            test "$__history_sync_verbose" = 1; and sed 's/^/  git: /' $err >&2
            rm -f $err
            return 1
        end
    else
        # Remote may be empty / branch may not exist yet. Treat as first write.
        __history_sync_log "  fetch failed; treating remote as empty"
        test "$__history_sync_verbose" = 1; and sed 's/^/  git: /' $err >&2
    end
    rm -f $err

    if test -e $workdir/$filename
        cp $workdir/$filename $local_dest
    else
        : >$local_dest
    end

    set -l sha none
    if git -C $workdir rev-parse --verify -q HEAD >/dev/null 2>&1
        set sha (git -C $workdir rev-parse HEAD)
    end

    __history_sync_log "  pulled "(wc -c <$local_dest)" bytes at $sha"
    echo "sha:$sha"
    return 0
end
