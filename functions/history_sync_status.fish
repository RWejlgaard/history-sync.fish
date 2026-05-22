function history_sync_status --description "Show fish-history-sync configuration and state"
    set -l backend $history_sync_backend
    test -n "$backend"; or set backend sftp

    echo "fish-history-sync status"
    echo "  backend:      $backend"
    echo "  history file: $history_sync_history_file"
    echo "  interval:     $history_sync_interval s"

    switch $backend
        case sftp
            echo "  host:         "(set -q history_sync_host; and echo $history_sync_host; or echo "(unset)")
            echo "  path:         "(set -q history_sync_path; and echo $history_sync_path; or echo "(unset)")
            echo "  port:         "(set -q history_sync_port; and echo $history_sync_port; or echo "(default)")
            echo "  identity:     "(set -q history_sync_identity; and echo $history_sync_identity; or echo "(ssh-agent / default)")
            echo "  lock TTL:     $history_sync_lock_ttl s"
            echo "  max retries:  $history_sync_max_retries"
        case s3
            echo "  bucket:       "(set -q history_sync_s3_bucket; and echo $history_sync_s3_bucket; or echo "(unset)")
            echo "  key:          "(set -q history_sync_s3_key; and echo $history_sync_s3_key; or echo "(unset)")
            echo "  endpoint:     "(set -q history_sync_s3_endpoint; and echo $history_sync_s3_endpoint; or echo "(default AWS)")
            echo "  region:       "(set -q history_sync_s3_region; and echo $history_sync_s3_region; or echo "(default)")
            echo "  profile:      "(set -q history_sync_s3_profile; and echo $history_sync_s3_profile; or echo "(default)")
        case git
            echo "  url:          "(set -q history_sync_git_url; and echo $history_sync_git_url; or echo "(unset)")
            echo "  branch:       $history_sync_git_branch"
            echo "  workdir:      $history_sync_git_workdir"
            echo "  filename:     $history_sync_git_filename"
    end

    if set -q history_sync_exclude_patterns; and test (count $history_sync_exclude_patterns) -gt 0
        echo "  exclude pats: "(count $history_sync_exclude_patterns)" pattern(s)"
        for p in $history_sync_exclude_patterns
            echo "                  $p"
        end
    end

    set -l now (date +%s)
    if set -q __history_sync_last
        set -l ago (math $now - $__history_sync_last)
        set -l next (math $__history_sync_last + $history_sync_interval - $now)
        echo "  last attempt: $__history_sync_last ($ago s ago)"
        if test $next -gt 0
            echo "  next attempt: in $next s"
        else
            echo "  next attempt: ready (any prompt may trigger)"
        end
    else
        echo "  last attempt: never"
    end
    if set -q __history_sync_last_success; and test -n "$__history_sync_last_success"
        set -l ago (math $now - $__history_sync_last_success)
        echo "  last success: $__history_sync_last_success ($ago s ago)"
    else
        echo "  last success: never"
    end
    if set -q __history_sync_last_error; and test -n "$__history_sync_last_error"
        echo "  last error:   $__history_sync_last_error"
    end

    if test -e $history_sync_history_file
        set -l sz (wc -c <$history_sync_history_file | string trim)
        set -l ents (grep -c '^- cmd:' $history_sync_history_file 2>/dev/null)
        test -n "$ents"; or set ents 0
        echo "  local size:   $sz bytes, $ents entries"
    end

    # Backend-specific probe
    switch $backend
        case sftp
            if set -q history_sync_host; and set -q history_sync_path
                echo
                echo "Probing remote lock..."
                set -l probe (__history_sync_tmp probe)
                if printf '%s\n' "get \"$history_sync_path.lock\" \"$probe\"" | __history_sync_sftp >/dev/null 2>&1
                    set -l holder_start (string match -rg '^start=(\d+)' <$probe)
                    if test -n "$holder_start"
                        set -l age (math $now - $holder_start)
                        set -l remaining (math $history_sync_lock_ttl - $age)
                        echo "  remote lock IS held:"
                        sed 's/^/    /' $probe
                        if test $remaining -gt 0
                            echo "    (held for {$age}s of {$history_sync_lock_ttl}s TTL, would break in {$remaining}s by our clock)"
                        else
                            echo "    (held for {$age}s — past TTL by our clock; eligible to break)"
                        end
                    else
                        echo "  remote lock IS held (no parseable start time):"
                        sed 's/^/    /' $probe
                    end
                else
                    echo "  remote lock not held"
                end
                rm -f $probe
            end
        case git
            if set -q history_sync_git_workdir; and test -d $history_sync_git_workdir/.git
                set -l head_sha (git -C $history_sync_git_workdir rev-parse --short HEAD 2>/dev/null)
                test -n "$head_sha"; or set head_sha "(no commits yet)"
                echo "  git head:     $head_sha"
            end
    end

    # Recent log tail
    set -l cache_dir $XDG_CACHE_HOME
    test -n "$cache_dir"; or set cache_dir "$HOME/.cache"
    set -l log_file "$cache_dir/fish-history-sync/sync.log"
    if test -e $log_file
        echo
        echo "Recent sync log (tail):"
        tail -n 5 $log_file | sed 's/^/  /'
    end

    # Exit non-zero if the most recent attempt was a failure — useful for prompts/monitors.
    if set -q __history_sync_last_error; and test -n "$__history_sync_last_error"
        return 1
    end
    return 0
end
