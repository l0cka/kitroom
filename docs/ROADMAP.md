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

## Phase 1: Read-only discovery

- [ ] Implement local process execution with bounded output and timeout
- [ ] Implement SSH execution using OpenSSH host aliases
- [ ] Discover local platform and home-directory context
- [ ] Discover a configured remote host's platform and home-directory context
- [ ] Capability-detect installed Claude and Codex versions
- [ ] Build fixture-based parsers before using live command output
- [ ] Render complete, partial, unavailable, and stale inventory states
- [ ] Add redacted diagnostics

Exit criterion: Kitroom accurately inventories a local machine and a configured
remote host without changing either one.

## Phase 2: Catalogue and comparison

- [ ] Define normalized catalogue records
- [ ] Add first curated source
- [ ] Show provenance, revision, compatibility, and update availability
- [ ] Compare inventories across hosts
- [ ] Explain differences without automatically synchronising them

Exit criterion: a user can identify what differs, why, and what source would be
used to reconcile it.

## Phase 3: Guarded local mutations

- [ ] Implement immutable operation plans
- [ ] Add plan expiry and live-state invalidation
- [ ] Add exact-target backup and atomic writes
- [ ] Implement one local skill install and uninstall path
- [ ] Verify effective agent state after each operation
- [ ] Add rollback and verification-failure UI

Exit criterion: one local capability can be safely installed and removed with
preview, approval, backup, verification, and rollback.

## Phase 4: Guarded remote mutations

- [ ] Bind approval to verified remote-host identity
- [ ] Implement remote backups and atomic writes
- [ ] Add connection-loss and partial-application recovery
- [ ] Apply one approved operation to an isolated remote test host
- [ ] Compare post-change state with the approved plan

Exit criterion: the same guarded workflow works on a remote host and reports
recovery state honestly.

## Phase 5: Product hardening

- [ ] Accessibility and keyboard-navigation audit
- [ ] Signed and notarized app distribution
- [ ] Persistent operation history and retention controls
- [ ] Catalogue integrity and signature policy
- [ ] Migration strategy for domain and persistence schemas
- [ ] Opt-in update notifications
- [ ] Additional agent adapter evaluation
