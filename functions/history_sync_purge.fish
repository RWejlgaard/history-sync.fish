function history_sync_purge --description "Strip entries matching <regex> from remote + local fish history"
    argparse a/add-to-excludes v/verbose h/help -- $argv
    or return 2

    if set -q _flag_help
        echo "usage: history_sync_purge [-v|--verbose] [-a|--add-to-excludes] <regex>"
        echo "  Remove entries whose cmd text matches <regex> from the remote shared"
        echo "  history and from this machine's local fish_history. Uses the configured"
        echo "  backend's CAS, so concurrent peer writes won't be clobbered."
        echo "  -a  also append <regex> to history_sync_exclude_patterns so peer machines"
        echo "      strip the matching entries on their next sync"
        return 0
    end

    set -l pattern $argv[1]
    if test -z "$pattern"
        echo "history_sync_purge: missing <regex> argument (try -h)" >&2
        return 2
    end

    set -g __history_sync_verbose 0
    set -q _flag_verbose; and set -g __history_sync_verbose 1

    set -l backend $history_sync_backend
    test -n "$backend"; or set backend sftp
    if not __history_sync_backend_configured $backend
        echo "history_sync_purge: backend '$backend' not configured (run history_sync_setup)" >&2
        return 2
    end

    set -l history_file $history_sync_history_file
    test -n "$history_file"; or set history_file "$HOME/.local/share/fish/fish_history"
    set -l hist_dir (dirname $history_file)

    set -l remote_dl (__history_sync_tmp remote)
    set -l state (__history_sync_backend pull $remote_dl)
    or begin
        echo "history_sync_purge: pull failed" >&2
        rm -f $remote_dl
        return 1
    end

    set -l local_snap (__history_sync_tmp local)
    if test -e $history_file
        cp $history_file $local_snap
    else
        : >$local_snap
    end

    # Shadow the user's exclude patterns with their existing ones plus the
    # one-shot pattern, so merge will drop matching entries from both sides.
    set -l had_excludes 0
    set -l saved_excludes
    if set -q history_sync_exclude_patterns
        set had_excludes 1
        set saved_excludes $history_sync_exclude_patterns
    end
    set -g history_sync_exclude_patterns $saved_excludes $pattern

    set -l merged (mktemp "$hist_dir/.fhs_purge.XXXXXX")
    set -l merge_rc 0
    __history_sync_merge $local_snap $remote_dl $merged; or set merge_rc $status

    # Restore exclude patterns (or persist the new one if requested)
    if set -q _flag_add_to_excludes
        set -U history_sync_exclude_patterns $saved_excludes $pattern
    else if test $had_excludes -eq 1
        set -g history_sync_exclude_patterns $saved_excludes
    else
        set -e history_sync_exclude_patterns
    end

    if test $merge_rc -ne 0
        echo "history_sync_purge: merge failed" >&2
        rm -f $remote_dl $local_snap $merged
        __history_sync_backend abort $state
        return 1
    end

    set -l before (grep -c '^- cmd:' $remote_dl 2>/dev/null)
    test -n "$before"; or set before 0
    set -l after (grep -c '^- cmd:' $merged 2>/dev/null)
    test -n "$after"; or set after 0
    set -l local_before (grep -c '^- cmd:' $local_snap 2>/dev/null)
    test -n "$local_before"; or set local_before 0
    set -l removed (math "max(0, $before - $after)")

    mv $merged $history_file
    echo "purge: kept $after entries (was $before remote / $local_before local); removed at least $removed matching '$pattern'"

    __history_sync_backend push $history_file $state
    set -l push_rc $status
    rm -f $remote_dl $local_snap

    if test $push_rc -ne 0
        echo "history_sync_purge: push failed (rc=$push_rc) — local cleaned, remote may still hold matching entries" >&2
        return 1
    end
    return 0
end
