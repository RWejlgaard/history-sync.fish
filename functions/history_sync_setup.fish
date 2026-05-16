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
    if printf '%s\n' "pwd" | __history_sync_sftp >/dev/null 2>$errfile
        echo "  SFTP connection OK."
        rm -f $errfile
    else
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

    echo
    echo "Run 'history_sync' to sync now, or wait for the next prompt-hook cycle."
end
