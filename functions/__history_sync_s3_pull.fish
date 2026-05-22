function __history_sync_s3_pull --description "S3 backend: download object + capture ETag as state token"
    set -l local_dest $argv[1]

    if not command -q aws
        echo "history_sync: 'aws' CLI not found on PATH (required for s3 backend)" >&2
        return 1
    end

    set -l bucket $history_sync_s3_bucket
    set -l key $history_sync_s3_key
    set -l aws_args (__history_sync_s3_args)

    __history_sync_log "s3: get s3://$bucket/$key"
    set -l err (__history_sync_tmp s3err)
    # --query ETag --output text prints the (quoted) ETag string verbatim so
    # we can hand it straight back to --if-match later. The output file is a
    # positional arg to get-object.
    set -l etag (aws $aws_args s3api get-object \
        --bucket $bucket --key $key \
        --query ETag --output text \
        $local_dest 2>$err)
    set -l rc $status

    if test $rc -ne 0
        # NoSuchKey / 404 just means first-write — treat as empty remote.
        if grep -qE 'NoSuchKey|Not Found|404' $err
            __history_sync_log "  remote not found; starting from empty"
            : >$local_dest
            rm -f $err
            echo none
            return 0
        end
        __history_sync_log "  s3 get FAILED"
        test "$__history_sync_verbose" = 1; and sed 's/^/  s3: /' $err >&2
        rm -f $err
        return 1
    end
    rm -f $err

    __history_sync_log "  downloaded "(wc -c <$local_dest)" bytes, etag=$etag"
    echo "etag:$etag"
    return 0
end
