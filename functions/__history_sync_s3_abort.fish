function __history_sync_s3_abort --description "S3 backend: no-op (no held lock — CAS is the mutex)"
    return 0
end
