# Roadmap

This roadmap prioritizes risk reduction and product learning. Visual
completeness comes later.

See [Implementation plan](IMPLEMENTATION_PLAN.md) for the detailed work
breakdown, dependencies, tests, and exit gates behind these phases.

## Phase 0: Scaffold

- [x] Choose the Kitroom name
- [x] Create a native SwiftUI package
- [x] Define host, agent, extension, inventory, and operation models
- [x] Define Claude and Codex adapter boundaries
- [x] Define approval digest and baseline safety requirements
- [x] Add tests and verification script

## Phase 1: Application foundation

- [x] Add a tracked Xcode macOS application project and shared scheme
- [x] Add provisional app icon, logo, and accent-color assets
- [x] Build the Hosts, Inventory, Catalogue, Activity, and Settings shell
- [x] Remove fabricated inventory and remote-host state
- [x] Record the initial distribution and sandbox decision
- [x] Build the application bundle in the required verification script
- [x] Add structured privacy-aware logging
- [x] Add dependency injection for sessions, clocks, persistence, and approvals
- [x] Complete the App Sandbox feasibility tests

Exit criterion: the application bundle, core library, and tests build together;
the remaining runtime boundaries are injectable; and the distribution decision
is supported by recorded sandbox evidence.

## Phase 2: Read-only discovery

- [x] Implement local process execution with bounded output and timeout
- [x] Implement SSH execution using OpenSSH host aliases
- [x] Discover local platform and home-directory context
- [x] Discover a configured remote host's platform and home-directory context
- [x] Capability-detect installed Claude and Codex versions
- [x] Build fixture-based parsers before using live command output
- [x] Inventory installed plugins, skills, MCP servers, and plugin components
- [x] Preserve scope, origin, effective state, freshness, and evidence links
- [x] Inspect optional repository layers from a selected working directory
- [x] Render complete, partial, unavailable, and stale inventory states
- [x] Persist hosts and bounded scan history with SwiftData
- [x] Add search, structured filters, and source/evidence inspection
- [x] Add redacted diagnostics

Exit criterion: Kitroom accurately inventories a local machine and a configured
remote host without changing either one.

## Phase 3: Catalogue and comparison

- [x] Define normalized catalogue records
- [x] Read native catalogue sources exposed by each agent
- [x] Show provenance, revision, compatibility, and update availability
- [x] Compare inventories across hosts
- [x] Explain differences without automatically synchronising them

Exit criterion: a user can identify what differs, why, and what source would be
used to reconcile it.

## Phase 4: Guarded local mutations

- [x] Implement immutable operation plans
- [x] Add plan expiry and live-state invalidation
- [x] Add exact-target backup and atomic writes
- [x] Implement one local skill install and uninstall path
- [x] Add atomic standalone-skill update
- [x] Add guarded Claude Code and Codex native plugin paths
- [x] Add guarded direct Codex MCP add and remove
- [x] Verify effective agent state after each operation
- [x] Add rollback and verification-failure UI

Exit criterion: one local capability can be safely installed and removed with
preview, approval, backup, verification, and rollback.

## Phase 5: Guarded remote mutations

- [x] Bind approval to verified remote-host identity and agent version
- [x] Implement remote backups and atomic skill installation
- [x] Add connection-loss and partial-application recovery
- [x] Apply standalone-skill and native-plugin operations to isolated remote
  profiles
- [x] Compare post-change state with the approved plan

Exit criterion: the same guarded workflow works on a remote host and reports
recovery state honestly.

Delivered scope is remote standalone-skill installation and Claude Code plugin
enable or disable. Remote skill update/uninstall, broader plugin actions, and
direct MCP management remain in Phase 6.

## Phase 6: Product hardening

- [ ] Accessibility and keyboard-navigation audit
- [ ] Signed and notarized app distribution
- [ ] Persistent operation history and retention controls
- [ ] Catalogue integrity and signature policy
- [ ] Migration strategy for domain and persistence schemas
- [ ] Opt-in update notifications
- [ ] Additional agent adapter evaluation
