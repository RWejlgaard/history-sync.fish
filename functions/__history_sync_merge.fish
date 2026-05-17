function __history_sync_merge --description "Merge two fish_history files into a third, dedup + sort by when"
    set -l file_a $argv[1]
    set -l file_b $argv[2]
    set -l output $argv[3]

    if test -z "$file_a" -o -z "$file_b" -o -z "$output"
        echo "usage: __history_sync_merge <a> <b> <out>" >&2
        return 2
    end

    # Treat missing inputs as empty
    test -e $file_a; or set file_a /dev/null
    test -e $file_b; or set file_b /dev/null

    # Use \x1e (record sep) between the sort key and the entry, and \x1f
    # (unit sep) in place of newlines within an entry. Neither byte may
    # appear in a fish_history entry, so tabs/anything else in the cmd
    # text survives the round-trip.
    awk '
    BEGIN {
        NL  = "\x1f"
        FLD = "\x1e"
        entry = ""
        cmd_text = ""
        when_val = 0
    }
    function flush(   k) {
        if (entry == "") return
        k = when_val "|" cmd_text
        if (!(k in seen)) {
            seen[k] = entry
            order[k] = when_val
        } else if (length(entry) > length(seen[k])) {
            # Prefer the variant with more data (paths block, etc.)
            seen[k] = entry
        }
    }
    /^- cmd: / {
        flush()
        entry = $0
        cmd_text = substr($0, 8)
        when_val = 0
        next
    }
    /^  when: / {
        entry = entry "\n" $0
        when_val = $2 + 0
        next
    }
    {
        # paths blocks and any other continuation lines belong to the current entry
        if (entry != "") entry = entry "\n" $0
    }
    END {
        flush()
        for (k in seen) {
            e = seen[k]
            gsub(/\n/, NL, e)
            printf "%d%s%s\n", order[k], FLD, e | "sort -n -k1,1"
        }
        close("sort -n -k1,1")
    }
    ' $file_a $file_b | awk '
    BEGIN { NL = "\x1f"; FLD = "\x1e" }
    {
        i = index($0, FLD)
        if (i == 0) next
        e = substr($0, i + 1)
        gsub(NL, "\n", e)
        print e
    }
    ' >$output
end
