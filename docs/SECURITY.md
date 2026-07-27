# Security model

Kitroom manages executable capabilities and remote hosts. Its threat model
therefore treats extension metadata, catalogue content, local files, remote
output, and command arguments as untrusted input.

## Trust boundaries

1. **User interface → operation plan:** the plan must fully describe the effect
   that receives approval.
2. **Kitroom → local process:** arguments must be structured and bounded.
3. **Kitroom → SSH:** use the system OpenSSH configuration and host-key policy.
4. **Catalogue → installation:** provenance and integrity must be checked before
   code reaches an agent's load path.
5. **Agent configuration → inventory:** configuration can be malformed,
   partially readable, or runtime-generated.

## Baseline requirements

- No private SSH key storage or copying.
- No disabling OpenSSH host-key verification.
- No `sudo` in the initial scope.
- No unreviewed background synchronisation.
- No secrets in activity logs or diagnostics.
- No unquoted shell construction from catalogue or user strings. OpenSSH remote
  requests use a fixed encoder that single-quotes every executable, argument,
  and allowed environment value.
- No recursive deletion based on an unresolved path.
- No claim of success before post-change inspection.
- Catalogue refresh and host comparison are read-only. They never trigger
  install, update, enable, disable, or removal commands.
- Catalogue metadata does not become trusted because two hosts report the same
  package name or version.

## Installation provenance and source policy

Before a catalogue-backed install or update, Kitroom records:

- canonical source URL;
- publisher identity when available;
- immutable revision or content digest;
- declared and detected files;
- supported agents and platforms;
- signature or verification status when the source exposes it.

A catalogue listing is not a trust decision.

The current product requires the user to allow the exact agent-reported
marketplace reference before it can introduce code. Install and update also
require a package manifest digest from fresh catalogue state. The allowance is
agent-and-reference specific, stored with owner-only permissions, and can be
revoked without changing installed packages.

This is an allowlist and integrity policy, not publisher authentication.
Kitroom reports declared or observed digest evidence and does not claim
signature verification when the source has not supplied a verifiable
signature. Host comparison is advisory and never reconciles state
automatically.

## Plan approval

Mutating plans require an explicit approval bound to `approvalDigest`. The plan
must be invalidated if:

- the host identity changes;
- inventory is refreshed and relevant state differs;
- the source revision changes;
- the target path or command changes;
- the plan expires;
- the SSH connection resolves to an unexpected host.

## Backup and rollback

Before overwriting or removing content:

1. Resolve and validate the exact target.
2. Capture metadata and a content digest.
3. Create a private, timestamped backup.
4. Apply atomically where possible.
5. Inspect the effective agent state.
6. Retain or discard the backup according to a documented policy.

Rollback failure is a distinct high-severity result, not a generic operation
failure.

Local operation paths store backups under Kitroom's private
application-support directory with owner-only directory permissions and
owner-readable configuration copies. Copied configuration is re-digested
before apply. Backups are retained until the user confirms deletion from
Activity. The local retention service accepts only a completed operation whose
rollback state is resolved, opens every backup-root component without
following symbolic links, and deletes only the descriptor-relative directory
named by the operation identifier. Remote backups are never deleted by that
local service.
Standalone-skill sources must contain a regular `SKILL.md`, may contain at
most 1,000 files and directories and 50 MiB, and may not contain symbolic
links or special files.

Plugin operations use the selected agent's native CLI and never edit plugin
caches. Catalogue-backed installs and updates re-check source metadata before
apply. A Claude Code update is marked high risk because the current native CLI
does not expose a version-pinned inverse.

Remote skill, plugin, and MCP plans bind a stable host identity and observed
agent version. Planning and apply use one concrete host session for discovery,
permission checks, state inspection, and mutation. Apply repeats host
discovery, executable/version checks, target permissions, free-space checks
for skill staging, and inventory before creating approval. The SSH alias is
never accepted as host identity.

Remote operations use fixed, versioned envelopes. Dynamic paths and identifiers
are positional arguments, not interpolated shell source. Skill archives are
limited to 1,000 regular files and 50 MiB, reject symbolic links and unsafe
paths, carry per-file SHA-256 evidence, and enter the load path only through an
exact atomic rename. Update and uninstall bind the existing remote tree digest
and re-check it immediately before moving the exact destination. Remote plugin
and MCP operations back up and re-digest the exact configuration before a
typed native CLI call. Interrupted operations use fresh inventory to
distinguish applied, rolled-back, and unprovable state.

The first direct MCP configuration path is deliberately narrow: Codex, user
scope, and credential-free HTTPS URLs without query parameters or fragments.
Plugin-provided MCP servers are excluded. Removal requires a readable
configuration backup so the original entry can be restored and verified.

## Diagnostics

Diagnostic exports must be redacted by default. They may include versions,
origin categories, exit codes, bounded error summaries, and content digests.
They must exclude local and remote paths, SSH aliases and resolved hosts,
tokens, environment secrets, SSH private keys, credential files, raw command
output, and unrestricted configuration contents.

## Deferred hardening

- Sandboxed static inspection of downloaded content
- Publisher signature verification when agent-native sources expose durable
  signature material
- Declared permission manifests
- Operation-log integrity
- Independent review of update and rollback behaviour
