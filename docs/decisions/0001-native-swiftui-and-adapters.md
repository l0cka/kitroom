# ADR 0001: Native SwiftUI application with agent adapters

- **Status:** Accepted
- **Date:** 2026-07-27

## Context

Kitroom must manage user-level files, processes, Keychain data, and OpenSSH
connections on macOS. Claude Code and Codex expose different configuration and
extension surfaces, and those surfaces are likely to evolve independently.

## Decision

Build Kitroom as a native SwiftUI macOS application with:

- a presentation-only `KitroomApp` target;
- a testable `KitroomCore` library;
- one adapter per coding agent;
- one host-session interface for local and SSH execution;
- immutable inventory snapshots and operation plans.

Use Apple frameworks and the system OpenSSH client before introducing external
dependencies.

## Consequences

### Positive

- Native Keychain, accessibility, lifecycle, and macOS integration
- Small distribution surface
- Agent and transport behaviour can evolve independently
- Core safety behaviour can be tested without launching the UI
- The local and Argus workflows can share normalized domain models

### Negative

- The UI is initially macOS-only
- Swift implementations must parse evolving command-line and configuration
  formats
- Cross-platform clients would require a new presentation layer or shared
  service later

## Revisit when

- A second desktop platform becomes a committed requirement
- OpenSSH subprocess control cannot meet connection or observability needs
- The adapter contract fails against live Claude or Codex inventory

