function history_sync_setup --description "Interactively configure fish-history-sync"
    echo "fish-history-sync setup"
    echo "(blank input keeps the current value)"
    echo

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

    read -P "Sync interval seconds [$history_sync_interval]: " -l interval
    if test -n "$interval"
        if string match -qr '^\d+$' -- $interval
            set -U history_sync_interval $interval
        else
            echo "ignoring non-numeric interval" >&2
        end
    end

    read -P "SSH port [default 22, blank to keep]: " -l port
    if test -n "$port"
        set -U history_sync_port $port
    end

    read -P "SSH identity file [blank to keep / use ssh-agent]: " -l identity
    if test -n "$identity"
        set -U history_sync_identity $identity
    end

    echo
    echo "Saved. Testing connection..."
    set -l errfile (mktemp /tmp/fhs_test.XXXXXX)
    if not printf '%s\n' "pwd" | __history_sync_sftp >/dev/null 2>$errfile
        echo "  SFTP connection FAILED. sftp said:"
        sed 's/^/    /' $errfile
        rm -f $errfile
        echo
        echo "  Common causes:"
        echo "    - host not in ~/.ssh/known_hosts (BatchMode blocks the prompt)"
        echo "        fix: ssh $host echo ok    # accept the host key once"
        echo "    - SSH key not loaded (BatchMode blocks password prompts)"
        echo "        fix: ssh-add -l           # check; ssh-add to load"
        echo "    - sftp subsystem disabled on the remote (ssh works, sftp doesn't)"
        echo "        fix: enable 'Subsystem sftp' on the server's sshd_config"
        echo "    - extra ~/.ssh/config options needed (ProxyJump, etc.)"
        echo "        fix: set -U history_sync_ssh_options ProxyJump=bastion"
        return 1
    end
    echo "  SFTP connection OK."
    rm -f $errfile

    # Round-trip a small file to the configured path's parent directory
    # so we catch wrong-path / no-perm at setup time, not silently on the
    # next background sync.
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

    echo
    echo "Run 'history_sync' to sync now, or wait for the next prompt-hook cycle."
end
