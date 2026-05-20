function __history_sync_s3_args --description "Emit common aws CLI args (endpoint/region/profile) one per line"
    set -l args
    if set -q history_sync_s3_endpoint; and test -n "$history_sync_s3_endpoint"
        set -a args --endpoint-url
        set -a args $history_sync_s3_endpoint
    end
    if set -q history_sync_s3_region; and test -n "$history_sync_s3_region"
        set -a args --region
        set -a args $history_sync_s3_region
    end
    if set -q history_sync_s3_profile; and test -n "$history_sync_s3_profile"
        set -a args --profile
        set -a args $history_sync_s3_profile
    end
    for a in $args
        echo $a
    end
end
