function __history_sync_backend_configured --description "Is the named backend fully configured?"
    set -l backend $argv[1]
    switch $backend
        case sftp
            set -q history_sync_host; and test -n "$history_sync_host"; or return 1
            set -q history_sync_path; and test -n "$history_sync_path"; or return 1
            return 0
        case s3
            set -q history_sync_s3_bucket; and test -n "$history_sync_s3_bucket"; or return 1
            set -q history_sync_s3_key; and test -n "$history_sync_s3_key"; or return 1
            return 0
        case git
            set -q history_sync_git_url; and test -n "$history_sync_git_url"; or return 1
            return 0
        case '*'
            return 1
    end
end
