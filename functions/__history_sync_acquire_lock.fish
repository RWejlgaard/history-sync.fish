function __history_sync_acquire_lock --description "Acquire remote SFTP lock with retry + stale-break"
    set -l remote_path $history_sync_path
    set -l lockpath "$remote_path.lock"
    set -l max_retries $history_sync_max_retries
    set -l lock_ttl $history_sync_lock_ttl

    # Strip filesystem-hostile chars so weird hostnames don't break paths.
    set -l host_id (hostname -s 2>/dev/null; or uname -n)
    set host_id (string replace -ra '[^A-Za-z0-9_.-]' '_' -- $host_id)
    test -n "$host_id"; or set host_id unknown

    set -l now (date +%s)
    set -l rnd (random)
    set -l tmp_lockpath "$remote_path.lock.tmp.$host_id.$fish_pid.$rnd"

    set -l local_payload (mktemp /tmp/fhs_lock.XXXXXX); or return 1
    printf 'host=%s\npid=%s\nstart=%s\n' $host_id $fish_pid $now >$local_payload

    set -g __history_sync_lock_owned 0

    set -l parent_dir (dirname $remote_path)

    # Track the lock holder we've been waiting on. We measure TTL against
    # OUR clock (first time we saw this exact holder) rather than against
    # the holder's wall clock — which may be skewed across machines.
    set -l observed_start ""
    set -l observed_first_seen 0

    set -l attempt 0
    while test $attempt -lt $max_retries
        set attempt (math $attempt + 1)
        __history_sync_log "  lock attempt $attempt/$max_retries"

        # Upload tmp lockfile then atomically rename into place.
        # Rename fails (and aborts the batch) if the lockfile already exists,
        # which is our signal that someone else holds the lock. The -mkdir
        # ensures the parent dir exists on a fresh remote.
        set -l err (mktemp /tmp/fhs_lockerr.XXXXXX)
        set -l batch "-mkdir \"$parent_dir\"
put \"$local_payload\" \"$tmp_lockpath\"
rename \"$tmp_lockpath\" \"$lockpath\""
        if printf '%s\n' $batch | __history_sync_sftp >/dev/null 2>$err
            rm -f $local_payload $err
            set -g __history_sync_lock_owned 1
            return 0
        end
        if test "$__history_sync_verbose" = 1
            sed 's/^/  sftp: /' $err >&2
        end
        rm -f $err

        # Rename failed — clean up our orphaned tmp file before retrying
        printf '%s\n' "-rm \"$tmp_lockpath\"" | __history_sync_sftp >/dev/null 2>&1

        # Inspect the existing lock. We compare TTL against OUR own clock:
        # the first time we observe a given start= value, note the local
        # time; if the same start= is still there past TTL, break it.
        set -l holder_file (mktemp /tmp/fhs_holder.XXXXXX)
        if printf '%s\n' "get \"$lockpath\" \"$holder_file\"" | __history_sync_sftp >/dev/null 2>&1
            set -l holder_host (string match -rg '^host=(.+)$' <$holder_file)
            set -l holder_pid (string match -rg '^pid=(\d+)$' <$holder_file)
            set -l holder_start (string match -rg '^start=(\d+)' <$holder_file)
            set -l current (date +%s)

            if test -n "$holder_start"
                if test "$holder_start" != "$observed_start"
                    # Fresh holder (or first observation this attempt)
                    set observed_start $holder_start
                    set observed_first_seen $current
                    __history_sync_log "  lock held by $holder_host pid=$holder_pid (first sighting; TTL countdown begins)"
                else
                    set -l wait_age (math $current - $observed_first_seen)
                    __history_sync_log "  lock held by $holder_host pid=$holder_pid (waited "$wait_age"s of $lock_ttl)"
                    if test $wait_age -gt $lock_ttl
                        __history_sync_log "  breaking stale lock"
                        printf '%s\n' "-rm \"$lockpath\"" | __history_sync_sftp >/dev/null 2>&1
                        rm -f $holder_file
                        # Reset observation; new attempt starts fresh.
                        set observed_start ""
                        set observed_first_seen 0
                        continue
                    end
                end
            end
        end
        rm -f $holder_file

        if test $attempt -ge $max_retries
            break
        end

        # Exponential backoff with jitter (cap ~30s)
        set -l backoff (math "min(2 ^ $attempt, 30)")
        set -l rnd (random)
        set -l jitter (math "$backoff * 0.5 * $rnd / 32767")
        set -l wait (math "$backoff + $jitter")
        __history_sync_log "  retrying in "$wait"s"
        sleep $wait
    end

    rm -f $local_payload
    return 1
end
