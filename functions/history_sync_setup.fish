function history_sync_setup --description "Interactively configure fish-history-sync"
    echo "fish-history-sync setup"
    echo "(blank input keeps the current value)"
    echo

    set -l current_backend $history_sync_backend
    test -n "$current_backend"; or set current_backend sftp
    echo "Backends:"
    echo "  sftp - SFTP host you can SSH into with a key (default)"
    echo "  s3   - S3-compatible object store (AWS, R2, B2, MinIO; needs 'aws' CLI)"
    echo "  git  - private git repo (needs 'git' CLI; uses push CAS for concurrency)"
    read -P "Backend [$current_backend]: " -l backend
    test -n "$backend"; or set backend $current_backend
    if not contains -- $backend sftp s3 git
        echo "unknown backend '$backend' — must be one of: sftp, s3, git" >&2
        return 1
    end
    set -U history_sync_backend $backend

    switch $backend
        case sftp
            __history_sync_setup_sftp; or return $status
        case s3
            __history_sync_setup_s3; or return $status
        case git
            __history_sync_setup_git; or return $status
    end

    read -P "Sync interval seconds [$history_sync_interval]: " -l interval
    if test -n "$interval"
        if string match -qr '^\d+$' -- $interval
            set -U history_sync_interval $interval
        else
            echo "ignoring non-numeric interval" >&2
        end
    end

    if not set -q history_sync_exclude_patterns; or test (count $history_sync_exclude_patterns) -eq 0
        echo
        echo "Exclude patterns prevent matching commands from syncing (great for secrets)."
        read -P "Install recommended secret-filter defaults? [y/N]: " -l want_excl
        if string match -qi 'y*' -- $want_excl
            set -U history_sync_exclude_patterns \
                '(api[_-]?key|secret|password|token)=' \
                'Bearer\s+[A-Za-z0-9._-]{20,}' \
                'ghp_[A-Za-z0-9]{36}' \
                'gho_[A-Za-z0-9]{36}' \
                'ghs_[A-Za-z0-9]{36}' \
                'sk-[A-Za-z0-9]{20,}' \
                'AKIA[0-9A-Z]{16}'
            echo "  installed "(count $history_sync_exclude_patterns)" patterns. Inspect with 'set -S history_sync_exclude_patterns'."
        end
    end

    echo
    echo "Setup done. Run 'history_sync' to sync now, or wait for the next prompt-hook cycle."
end

function __history_sync_setup_sftp --description "Interactive SFTP setup + connectivity probe"
    set -l host_default ""
    set -q history_sync_host; and set host_default $history_sync_host
    set -l host_prompt "SFTP host [user@example.com]"
    test -n "$host_default"; and set host_prompt "$host_prompt ($host_default)"
    read -P "$host_prompt: " -l host
    test -n "$host"; or set host $host_default
    if test -z "$host"
        echo "host is required" >&2
        return 1
    end
    set -U history_sync_host $host

    set -l path_default ".local/share/fish/fish_history"
    set -q history_sync_path; and test -n "$history_sync_path"; and set path_default $history_sync_path
    read -P "Remote path [$path_default]: " -l path
    test -n "$path"; or set path $path_default
    # sftp batch commands don't expand ~; strip it so the path resolves
    # relative to the user's home dir (which is sftp's default cwd).
    set path (string replace -r '^~/' '' -- $path)
    set -U history_sync_path $path

    read -P "SSH port [default 22, blank to keep]: " -l port
    if test -n "$port"
        set -U history_sync_port $port
    end

    read -P "SSH identity file [blank to keep / use ssh-agent]: " -l identity
    if test -n "$identity"
        set -U history_sync_identity $identity
    end

    read -P "Extra SSH options, e.g. 'ProxyJump=bastion' [blank to keep]: " -l ssh_opts
    if test -n "$ssh_opts"
        set -U history_sync_ssh_options (string split ' ' -- $ssh_opts)
    end

    read -P "Lock TTL seconds [$history_sync_lock_ttl]: " -l ttl
    if test -n "$ttl"; and string match -qr '^\d+$' -- $ttl
        set -U history_sync_lock_ttl $ttl
    end

    read -P "Max lock-acquire retries [$history_sync_max_retries]: " -l retries
    if test -n "$retries"; and string match -qr '^\d+$' -- $retries
        set -U history_sync_max_retries $retries
    end

    echo
    echo "Testing SFTP connection..."
    set -l errfile (mktemp /tmp/fhs_test.XXXXXX)
    if not printf '%s\n' pwd | __history_sync_sftp >/dev/null 2>$errfile
        echo "  SFTP connection FAILED. sftp said:"
        sed 's/^/    /' $errfile
        rm -f $errfile
        echo
        echo "  Common causes:"
        echo "    - host not in ~/.ssh/known_hosts (BatchMode blocks the prompt)"
        echo "        fix: ssh $host echo ok    # accept the host key once"
        echo "    - SSH key not loaded (BatchMode blocks password prompts)"
        echo "        fix: ssh-add -l           # check; ssh-add to load"
        echo "    - sftp subsystem disabled on the remote"
        echo "        fix: enable 'Subsystem sftp' on the server's sshd_config"
        echo "    - extra ~/.ssh/config options needed (ProxyJump, etc.)"
        echo "        fix: set -U history_sync_ssh_options ProxyJump=bastion"
        return 1
    end
    echo "  SFTP connection OK."
    rm -f $errfile

    set -l parent_dir (dirname $path)
    set -l probe_remote "$path.setup_probe.$fish_pid"
    set -l probe_local (mktemp /tmp/fhs_probe.XXXXXX)
    echo "fish-history-sync setup probe" >$probe_local
    set -l werr (mktemp /tmp/fhs_werr.XXXXXX)
    set -l write_batch "-mkdir \"$parent_dir\"
put \"$probe_local\" \"$probe_remote\"
-rm \"$probe_remote\""
    if printf '%s\n' $write_batch | __history_sync_sftp >/dev/null 2>$werr
        echo "  Write test to '$parent_dir/' OK."
    else
        echo "  Write test to '$parent_dir/' FAILED. sftp said:"
        sed 's/^/    /' $werr
        echo
        echo "  Check that the remote user can create files at this path:"
        echo "    ssh $host mkdir -p $parent_dir"
        rm -f $probe_local $werr
        return 1
    end
    rm -f $probe_local $werr
    return 0
end

function __history_sync_setup_s3 --description "Interactive S3 setup + connectivity probe"
    if not command -q aws
        echo "  'aws' CLI not found on PATH — install it before continuing." >&2
        echo "  See: https://aws.amazon.com/cli/" >&2
        return 1
    end

    set -l bucket_default ""
    set -q history_sync_s3_bucket; and set bucket_default $history_sync_s3_bucket
    read -P "S3 bucket [$bucket_default]: " -l bucket
    test -n "$bucket"; or set bucket $bucket_default
    if test -z "$bucket"
        echo "bucket is required" >&2
        return 1
    end
    set -U history_sync_s3_bucket $bucket

    set -l key_default fish_history
    set -q history_sync_s3_key; and test -n "$history_sync_s3_key"; and set key_default $history_sync_s3_key
    read -P "Object key [$key_default]: " -l key
    test -n "$key"; or set key $key_default
    set -U history_sync_s3_key $key

    read -P "Endpoint URL (blank for AWS; e.g. https://<acct>.r2.cloudflarestorage.com): " -l endpoint
    if test -n "$endpoint"
        set -U history_sync_s3_endpoint $endpoint
    end

    read -P "Region (blank to use aws default): " -l region
    if test -n "$region"
        set -U history_sync_s3_region $region
    end

    read -P "aws profile (blank to use default credentials chain): " -l profile
    if test -n "$profile"
        set -U history_sync_s3_profile $profile
    end

    echo
    echo "Testing S3 reachability..."
    set -l err (mktemp /tmp/fhs_s3test.XXXXXX)
    set -l aws_args (__history_sync_s3_args)
    if aws $aws_args s3api head-bucket --bucket $bucket 2>$err
        echo "  Bucket head OK."
    else
        echo "  head-bucket FAILED. aws said:"
        sed 's/^/    /' $err
        echo
        echo "  Common causes:"
        echo "    - credentials not loaded (env vars / ~/.aws/credentials / --profile)"
        echo "    - wrong region / endpoint URL"
        echo "    - bucket does not exist or you lack ListBucket permission"
        rm -f $err
        return 1
    end
    rm -f $err
    return 0
end

function __history_sync_setup_git --description "Interactive git setup + connectivity probe"
    if not command -q git
        echo "  'git' CLI not found on PATH — install it before continuing." >&2
        return 1
    end

    set -l url_default ""
    set -q history_sync_git_url; and set url_default $history_sync_git_url
    read -P "Git URL (e.g. git@host:user/private-history.git) [$url_default]: " -l url
    test -n "$url"; or set url $url_default
    if test -z "$url"
        echo "git URL is required" >&2
        return 1
    end
    set -U history_sync_git_url $url

    read -P "Branch [$history_sync_git_branch]: " -l branch
    if test -n "$branch"
        set -U history_sync_git_branch $branch
    end

    read -P "Filename inside the repo [$history_sync_git_filename]: " -l filename
    if test -n "$filename"
        set -U history_sync_git_filename $filename
    end

    read -P "Local workdir [$history_sync_git_workdir]: " -l workdir
    if test -n "$workdir"
        set -U history_sync_git_workdir $workdir
    end

    set -l shallow_default no
    test "$history_sync_git_shallow" = true; and set shallow_default yes
    read -P "Shallow clone (saves disk on high-frequency syncs) [$shallow_default]: " -l shallow_in
    test -z "$shallow_in"; and set shallow_in $shallow_default
    if string match -qi 'y*' -- $shallow_in
        set -U history_sync_git_shallow true
    else
        set -e history_sync_git_shallow
    end

    echo
    echo "Testing git reachability..."
    set -l err (mktemp /tmp/fhs_gittest.XXXXXX)
    if git ls-remote --exit-code -h $url $history_sync_git_branch >/dev/null 2>$err
        echo "  ls-remote OK (branch '$history_sync_git_branch' exists)."
    else if git ls-remote $url >/dev/null 2>$err
        echo "  ls-remote OK (branch '$history_sync_git_branch' missing — will be created on first push)."
    else
        echo "  ls-remote FAILED. git said:"
        sed 's/^/    /' $err
        echo
        echo "  Common causes:"
        echo "    - SSH key not loaded (for git@... URLs)"
        echo "    - HTTPS credential helper not configured"
        echo "    - repo doesn't exist yet — create an empty private repo, then re-run"
        rm -f $err
        return 1
    end
    rm -f $err
    return 0
end
