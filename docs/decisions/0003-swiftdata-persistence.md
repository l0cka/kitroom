# ADR 0003: SwiftData persistence

- **Status:** Accepted
- **Date:** 2026-07-27

## Context

Kitroom needs durable local storage for host metadata, discovery results,
normalized inventory, evidence summaries, scan issues, catalogues, and later
operation history. The core domain uses immutable, `Codable`, `Sendable` value
types. The store must retain historical scans while giving the app a simple
latest-per-host-and-agent view.

The initial choice in the architecture was between SwiftData and SQLite. Direct
SQLite would give tighter query and transaction control, but it would also add
schema mapping, migration, and concurrency code before the product needs
relational joins or an append-only audit ledger.

## Decision

Use SwiftData for the initial production store.

Kitroom stores versioned, encoded domain envelopes rather than making SwiftData
models the public domain model. A record contains:

- a unique record key and kind;
- a payload schema version;
- creation and update times;
- an externally stored encoded payload.

Hosts use a replaceable current record. Host discovery and inventory scans are
append-only within bounded per-target retention. Read APIs derive the latest
host discovery and latest inventory for each host and agent without deleting
the retained history.

The current payload schema is version 1. A record with a newer unsupported
schema fails explicitly rather than being treated as empty. Future model
changes must add compatibility decoding or a SwiftData migration stage before
the schema version is advanced.

The production store lives in the user's Application Support directory. Test
stores use isolated temporary directories and never read or write the
developer's real inventory.

## Consequences

- Kitroom remains dependency-free beyond Apple frameworks.
- Domain values remain independent of SwiftData and SwiftUI.
- Evidence and issues persist with their parent snapshot.
- Repeated scans retain history while normal app startup loads only current
  state.
- If store initialization fails, Kitroom falls back to in-memory state and
  displays a warning that history is not being saved.
- Diagnostic exports are built from a separate redacted projection. They omit
  SSH aliases, resolved hosts, paths, evidence source references, raw command
  output, issue details, and configuration values.

## Revisit conditions

Reconsider direct SQLite if operation history requires tamper-evident
append-only guarantees, complex cross-host queries become a performance
problem, SwiftData migrations cannot preserve required audit semantics, or
headless tooling must share the store.
