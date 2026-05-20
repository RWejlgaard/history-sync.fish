function __history_sync_git_init --description "Ensure the git workdir exists and points at the configured remote"
    set -l workdir $history_sync_git_workdir
    set -l url $history_sync_git_url
    set -l branch $history_sync_git_branch
    test -n "$branch"; or set branch main

    if test -d $workdir/.git
        # Already initialised. Make sure the remote URL still matches; users
        # who change history_sync_git_url should get a clean retarget.
        set -l current (git -C $workdir remote get-url origin 2>/dev/null)
        if test "$current" != "$url"
            git -C $workdir remote set-url origin $url 2>/dev/null
        end
        return 0
    end

    set -l parent (dirname $workdir)
    mkdir -p $parent; or return 1

    set -l shallow
    if test "$history_sync_git_shallow" = true
        set shallow --depth=100
    end

    # Try clone; falls back to manual init if the remote is empty or the
    # branch doesn't exist yet (first sync ever).
    if git clone $shallow --branch $branch -- $url $workdir >/dev/null 2>&1
        return 0
    end

    mkdir -p $workdir; or return 1
    git -C $workdir init -q -b $branch >/dev/null 2>&1; or return 1
    git -C $workdir remote add origin $url >/dev/null 2>&1; or return 1
    # Best-effort fetch; failing here just means we'll create the branch on push.
    git -C $workdir fetch origin $branch >/dev/null 2>&1
    return 0
end
