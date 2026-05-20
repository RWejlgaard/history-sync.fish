function __history_sync_git_abort --description "Git backend: no-op (no held lock — git push's ref update is the CAS)"
    return 0
end
