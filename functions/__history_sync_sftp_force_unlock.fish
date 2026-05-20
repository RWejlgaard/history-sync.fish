function __history_sync_sftp_force_unlock --description "SFTP backend: forcibly remove the remote lock file"
    printf '%s\n' "-rm \"$history_sync_path.lock\"" | __history_sync_sftp >/dev/null 2>&1
end
