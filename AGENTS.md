# AGENTS.md: Kitroom repository guide

## Project overview

Kitroom is a native macOS control centre for managing coding-agent extensions
across local and SSH-accessible hosts. The initial integrations are Claude Code
and Codex. The application manages skills, plugins, MCP servers, and the
configuration that loads them.

Kitroom is a management tool, so correctness includes the state of the target
host after an operation. A successful command exit is not sufficient evidence.

## Current status

This repository implements bounded, read-only host discovery, normalized Claude
Code and Codex inventory, and durable local scan history for the local Mac and
user-selected OpenSSH aliases. It does not yet browse available catalogues,
compare hosts, or execute mutations. Keep documentation and UI honest about
what is implemented. Use **Not checked**, **Unknown**, **Stale**, **Partial**,
or **Not implemented** when live state has not been established.

## Technology

- Swift 6
- SwiftUI
- Swift Package Manager
- macOS 14+
- XCTest
- OpenSSH for remote-host transport
- Keychain for secrets if Kitroom ever needs to store any

Do not add a third-party dependency unless the standard library and Apple
frameworks are insufficient and the trade-off is documented.

## Commands

```bash
swift build             # Compile all targets
swift test              # Run unit tests
swift run Kitroom       # Launch the development app
./scripts/verify.sh     # Build package, test core, and build the .app
```

## Project structure

```text
Sources/KitroomApp/
  KitroomApp.swift       # Application entry point
  AppModel.swift         # Main-actor UI state
  AppSection.swift       # Primary navigation destinations
  DashboardView.swift    # Current presentation shell
  InventoryProductView.swift # Inventory filters, evidence, and export
  Resources/             # App icon, logo, and color assets

Sources/KitroomCore/
  Domain/                # Agent, host, package, capability, inventory, operation types
  Adapters/              # Agent-specific inspection and mutation contracts
  Infrastructure/        # Local/SSH boundaries and SwiftData persistence

Tests/KitroomCoreTests/  # Core behaviour and safety invariants
docs/                    # Product, architecture, security, roadmap, ADRs
Kitroom.xcodeproj/       # Native application bundle target and shared scheme
```

## Architecture rules

1. `KitroomApp` may depend on `KitroomCore`; `KitroomCore` must not depend on
   SwiftUI.
2. Agent-specific paths, commands, and parsers belong in the relevant adapter.
3. Local and remote execution share the `HostSession` contract.
4. Views never invoke shell commands directly.
5. Inventory snapshots are immutable values with capture time and provenance.
6. Mutations are immutable `OperationPlan` values before they are executable.
7. Do not collapse skills, plugins, and MCP servers into one undifferentiated
   implementation type merely because the UI can display them together.
8. Prefer capability detection over version-number assumptions.

## Safety requirements

### Read-only inspection

- Resolve the exact host and agent before executing anything.
- Use bounded commands with explicit arguments.
- Treat parse failures, missing permissions, timeouts, and partial responses as
  unknown state.
- Never infer that a host is clean or an agent is absent from an empty or failed
  result.

### Mutations

Every install, update, disable, uninstall, or configuration write must follow:

```text
inspect → plan → display exact effect → approve → apply → verify → record
```

- Approval binds to a plan identifier and digest. If inputs or live target
  state change, invalidate approval and re-plan.
- Display the host, agent, capability, source, files, commands, and rollback
  strategy.
- Back up overwritten configuration or content before applying a change.
- Use atomic writes where practical.
- Never use broad process termination, recursive deletion, or unresolved globs.
- Do not request or use `sudo` in the initial user-level product scope.
- Keep local and remote operations visually distinct.

### SSH

- Reuse the user's OpenSSH host aliases and trust decisions.
- Do not copy private keys into Kitroom storage.
- Do not disable host-key verification.
- Quote remote command arguments structurally; do not concatenate untrusted
  values into a shell command.
- Capture the remote platform, home directory, agent version, and relevant
  permissions as part of host discovery.

### Credentials and logs

- Store secrets only in Keychain.
- Redact tokens, credentials, private key material, and sensitive environment
  values from plans, logs, diagnostics, and test fixtures.
- The operation log records intent, target, result, and verification evidence;
  it must not become a secret store.

## Agent adapter expectations

Each Claude or Codex adapter is responsible for:

- detecting whether its agent is available on a host;
- reporting supported management capabilities;
- discovering all relevant configuration and extension sources;
- separating hand-managed, marketplace, plugin-provided, shared, and
  runtime-injected state;
- producing normalized inventory with raw evidence references;
- planning agent-native mutations;
- verifying the post-change state.

Do not hard-code one machine's paths as universal facts. Candidate paths are
acceptable only when host discovery verifies them.

## Swift conventions

- Use value types for domain state and plans.
- Mark cross-concurrency values `Sendable`.
- Keep UI state on `@MainActor`.
- Prefer explicit names over abbreviations.
- Model unknown and partial state explicitly.
- Use dependency injection for sessions, clocks, and filesystem/process
  boundaries so core behaviour remains testable.
- Keep files focused; one principal public type per file where practical.

## Testing

Tests must cover:

- normalization of agent-specific inventory;
- unknown and partial failure states;
- operation-plan approval requirements;
- plan invalidation when target state changes;
- shell-argument and SSH-host validation;
- no-op and idempotent operations;
- post-change verification failures;
- redaction of sensitive values.

Never run mutation tests against a developer's real home directory or a live
remote host. Use temporary fixtures and fake sessions. Live integration tests
must be explicitly selected and remain read-only until a separate guarded test
environment exists.

## Documentation standard

Documentation must be:

- **Honest:** distinguish implemented behaviour from planned behaviour.
- **Actionable:** include exact commands and verification.
- **Durable:** avoid claims about fast-moving CLI surfaces unless capability
  detection or a cited compatibility test supports them.
- **Specific:** name trust boundaries, failure states, and ownership.
- **Public-facing:** use generic host roles and sanitized examples. Keep
  personal machine names, private infrastructure, usernames, and absolute
  paths out of tracked documentation and fixtures.

Update the relevant product, architecture, security, roadmap, or ADR document
when a change alters the system contract.

## Definition of done

Before handoff:

1. Run `./scripts/verify.sh`.
2. Confirm no secrets, generated build output, or user-specific absolute paths
   were added.
3. Confirm new UI state is accessible and labels unknown state honestly.
4. Confirm new mutations have preview, approval, rollback, and verification
   paths.
5. Update documentation for any changed behaviour or decision.
