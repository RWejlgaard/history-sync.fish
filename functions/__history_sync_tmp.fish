function __history_sync_tmp --description "mktemp respecting TMPDIR (macOS puts it under /var/folders)"
    set -l dir $TMPDIR
    test -n "$dir"; or set dir /tmp
    set -l tag $argv[1]
    test -n "$tag"; or set tag scratch
    mktemp $dir/fhs_$tag.XXXXXX
end
