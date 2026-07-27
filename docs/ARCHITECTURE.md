# Architecture

## System shape

Kitroom is a native macOS application with a UI target and a platform-neutral
core library. It connects to the local machine or to a remote host through the
user's OpenSSH configuration.

```mermaid
flowchart TB
    View["SwiftUI views"] --> Model["Main-actor app model"]
    Model --> Inventory["Inventory service"]
    Model --> Planner["Operation planner"]
    Inventory --> Adapter["Agent adapter"]
    Planner --> Adapter
    Adapter --> Session["HostSession"]
    Session --> Local["Local process session"]
    Session --> SSH["OpenSSH session"]
    Planner --> Approval["Approval record"]
    Approval --> Executor["Operation executor"]
    Executor --> Verify["Fresh inventory verification"]
```

## Layers

### KitroomApp

Owns presentation, navigation, user interaction, accessibility, and main-actor
state. Views work with normalized core models and never construct shell
commands.

The tracked Xcode project produces `Kitroom.app` and embeds `KitroomCore` as a
framework. Swift Package Manager remains the fast path for core builds, tests,
and command-line development runs.

### KitroomCore.Domain

Contains immutable, `Sendable` values:

- `ManagedHost`
- `HostDiscoverySnapshot`
- `AgentKind`
- `CatalogSource`
- `PackageRecord`
- `ProvidedCapability`
- `InstallationRecord`
- `EvidenceRecord`
- `InventorySnapshot`
- `OperationPlan`

Unknown, partial, and unavailable states are first-class values.

### KitroomCore.Adapters

Each adapter understands one agent's:

- executable and capability discovery;
- configuration hierarchy;
- skills, plugins, and MCP surfaces;
- inventory formats;
- supported native operations;
- verification rules.

Candidate paths guide discovery but never prove installation by themselves.

### KitroomCore.Infrastructure

`HostSession` is the execution boundary shared by local and SSH connections.
Requests use an absolute executable plus an argument array, an explicit
environment allowlist, a timeout, and output limits. Local execution never
invokes an implicit shell. The SSH transport encodes those values into one
strictly quoted POSIX command because OpenSSH's remote-command protocol passes
through the remote login shell.

The implemented boundaries are:

- `SystemProcessExecutor`, backed by `Process`, with bounded concurrent output,
  timeout, cancellation, exit, and signal reporting;
- `LocalHostSession`, which forwards structured requests;
- `SSHHostSession`, backed by `/usr/bin/ssh`, BatchMode, a validated existing
  alias, and the user's existing host-key policy;
- `SSHConfigurationResolver`, which exposes only a bounded resolved summary;
- `HostDiscoveryService`, which produces explicit reachable, partial,
  authentication, identity-change, unreachable, and cancelled states;
- fake and fixture sessions used by the transport tests.

## Inventory

An inventory scan is a collection of independently evidenced probes. A scan can
be complete, partial, or unavailable.

```mermaid
sequenceDiagram
    participant UI
    participant Adapter
    participant Host
    UI->>Adapter: inspect(host)
    Adapter->>Host: detect executable and version
    Adapter->>Host: inspect configuration sources
    Adapter->>Host: inspect skills, plugins, and MCP state
    Host-->>Adapter: bounded results and failures
    Adapter-->>UI: normalized snapshot + issues + evidence
```

Raw command output should not become the public domain model. Adapters parse it
into normalized values and retain bounded evidence references for diagnostics.
Each displayed package, capability, and installation links back to one or more
versioned evidence records. Skill, plugin, and MCP identities remain distinct
even when the UI presents them in one hierarchy.

An optional absolute working directory enables repository-aware discovery.
Kitroom asks Git for the repository root, walks configuration and skill layers
from that root to the selected directory, and passes every path as data to a
structured host-session request.

## Mutations

Mutation is a state machine:

```text
draft → planned → awaiting approval → applying → verifying
      → completed | failed | rolled back | verification failed
```

An approval is valid only for the digest of the displayed plan. The digest
includes the host, agent, capability, inventory time, and exact changes. A live
state change requires a new plan and approval.

## Persistence

The initial persistence model should use a small local SQLite store or SwiftData
for:

- host metadata, excluding SSH private key material;
- normalized inventory snapshots;
- catalogue metadata;
- operation plans and status;
- redacted verification evidence.

Persistence technology is deferred until the inventory model has been exercised
against representative local and remote data.

## Extension points

New agents implement `AgentAdapter`. New transports implement `HostSession`.
New catalogue sources should normalize into a separate catalogue model rather
than masquerading as installed inventory.
