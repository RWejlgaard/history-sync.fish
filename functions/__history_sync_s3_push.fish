function __history_sync_s3_push --description "S3 backend: conditional PUT against the pulled ETag (CAS)"
    set -l local_src $argv[1]
    set -l state $argv[2]

    if not command -q aws
        echo "history_sync: 'aws' CLI not found on PATH (required for s3 backend)" >&2
        return 2
    end

    set -l bucket $history_sync_s3_bucket
    set -l key $history_sync_s3_key
    set -l aws_args (__history_sync_s3_args)

    set -l cond
    if test "$state" = none
        set cond --if-none-match '*'
    else if string match -q 'etag:*' -- $state
        set -l etag (string sub --start 6 -- $state)
        set cond --if-match $etag
    else
        __history_sync_log "s3: unrecognized state token '$state'"
        return 2
    end

    __history_sync_log "s3: put s3://$bucket/$key (state=$state)"
    set -l err (__history_sync_tmp s3err)
    if aws $aws_args s3api put-object \
            --bucket $bucket --key $key \
            --body $local_src \
            $cond >/dev/null 2>$err
        __history_sync_log "  upload OK"
        rm -f $err
        return 0
    end

    # Distinguish CAS conflict from a real failure.
    if grep -qE 'PreconditionFailed|At least one of the pre-conditions you specified did not hold' $err
        __history_sync_log "  CAS conflict"
        test "$__history_sync_verbose" = 1; and sed 's/^/  s3: /' $err >&2
        rm -f $err
        return 1
    end

    __history_sync_log "  upload FAILED"
    test "$__history_sync_verbose" = 1; and sed 's/^/  s3: /' $err >&2
    rm -f $err
    return 2
end
