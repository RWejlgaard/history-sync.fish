function __history_sync_record --description "Record sync outcome to universal vars + a small log file"
    set -l status_word $argv[1]
    set -l message $argv[2..-1]
    set -l now (date +%s)

    set -U __history_sync_last_attempt $now
    if test "$status_word" = ok
        set -U __history_sync_last_success $now
        set -U __history_sync_last_error ""
    else
        set -U __history_sync_last_error "$message"
    end

    set -l cache_dir $XDG_CACHE_HOME
    test -n "$cache_dir"; or set cache_dir "$HOME/.cache"
    set -l log_dir "$cache_dir/fish-history-sync"
    mkdir -p $log_dir 2>/dev/null; or return 0
    set -l log_file "$log_dir/sync.log"

    set -l host_id (hostname -s 2>/dev/null; or uname -n)
    printf '%s\t%s\t%s\t%s\n' $now $host_id $status_word "$message" >>$log_file

    # Cheap rotation: keep last ~500 lines so the file never grows unbounded.
    if test (wc -l <$log_file 2>/dev/null) -gt 1000
        set -l rotated (mktemp "$log_dir/.sync.log.XXXXXX")
        tail -n 500 $log_file >$rotated; and mv $rotated $log_file
    end
end
