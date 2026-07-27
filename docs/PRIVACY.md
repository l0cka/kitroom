# Privacy and diagnostic data

Kitroom is designed to manage coding-agent extensions without turning host
inventory into a second source of telemetry.

## Data handling

- Kitroom does not include analytics, advertising, crash-reporting, or
  telemetry services.
- Host definitions, inventory snapshots, catalogue snapshots, operation plans,
  and operation history are stored in Kitroom's local Application Support
  directory.
- Remote inspection and approved operations use the system OpenSSH client and
  the user's existing SSH configuration, agent, keys, and host trust. Kitroom
  does not copy private keys into its own storage.
- Kitroom does not perform silent background synchronization. Catalogue and
  update checks are initiated by the user.

## Diagnostic exports

Diagnostic exports are deliberately bounded. They may contain:

- Kitroom, operating-system, and agent versions;
- normalized status, scope, origin, and evidence categories;
- package, capability, and issue counts;
- operation states and redacted failure summaries; and
- content digests that help distinguish observed states.

They omit:

- SSH aliases, resolved host names, addresses, and user names;
- local and remote paths;
- command output and unrestricted configuration contents;
- tokens, credentials, private keys, and credential files; and
- environment values that may contain secrets.

Review an export before sharing it. Redaction reduces accidental disclosure,
but a package name or version can still reveal information about a private
development environment.

## Backups and deletion

Kitroom retains local backups created by guarded operations until the user
deletes an eligible backup from Activity. Deletion targets only the recorded
operation directory, requires confirmation, and is blocked while rollback
state is unresolved. The activity record remains after backup deletion.

Kitroom does not automatically delete remote backups. Their retention is
managed directly on the SSH host after recovery is no longer needed.

Removing Kitroom does not remove extensions, agent configuration, remote
backups, or existing OpenSSH configuration.

## Network access

Kitroom's network-facing activity is limited to:

- OpenSSH connections initiated for a selected remote host; and
- network activity performed by an agent's native CLI during a user-approved
  catalogue or plugin operation.

Kitroom does not send inventory or operation history to the project
maintainers.

## Security reports

Please report a suspected vulnerability privately using the repository's
security reporting channel rather than including secrets or host details in a
public issue.
