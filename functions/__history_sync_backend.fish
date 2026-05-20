function __history_sync_backend --description "Dispatch a backend op to the configured backend"
    set -l backend $history_sync_backend
    test -n "$backend"; or set backend sftp

    set -l op $argv[1]
    set -l rest $argv[2..-1]

    set -l fn __history_sync_{$backend}_{$op}
    if not functions -q $fn
        echo "history_sync: unknown backend '$backend' or op '$op' ($fn)" >&2
        return 2
    end
    $fn $rest
end
