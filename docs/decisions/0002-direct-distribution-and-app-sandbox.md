# ADR 0002: Direct distribution before App Store distribution

- **Status:** Accepted
- **Date:** 2026-07-27

## Context

Kitroom needs to inspect user-level coding-agent configuration and launch the
system OpenSSH client. Relevant data can live in several locations under a
user's home directory, in project directories, and on remote hosts selected
through OpenSSH configuration.

The Mac App Store requires App Sandbox. A sandboxed build would need
user-selected directories and persistent security-scoped bookmarks for much of
Kitroom's local inventory. It would also need a proven way to launch OpenSSH
without weakening host-key or credential handling.

## Decision

Package the initial application for direct distribution with:

- bundle identifier `com.l0cka.kitroom`;
- a macOS 14 deployment target;
- Swift 6;
- Debug and Release configurations;
- Hardened Runtime enabled in the Xcode project;
- App Sandbox disabled while the access model is evaluated;
- Developer ID signing and notarization before public binary releases.

The repository keeps Swift Package Manager support for fast core builds and
tests. `Kitroom.xcodeproj` produces the macOS application bundle and embeds
`KitroomCore`.

## Feasibility evidence

The repository includes a minimal, separately signed probe under
`Tests/SandboxProbe` and a reproducible builder at
`scripts/build-sandbox-probe.sh`. The probe uses App Sandbox with
user-selected read/write access and outbound network access enabled.

The probe was built and run twice on 2026-07-27:

1. In the sandbox, `FileManager.homeDirectoryForCurrentUser` resolved to the
   app container. The real `~/.codex`, `~/.agents`, `~/.claude`, and `~/.ssh`
   locations were therefore not directly discoverable.
2. A read-only security-scoped bookmark for an accessible directory was saved,
   read, and restored successfully in a separate app launch.
3. `/usr/bin/ssh -G localhost` launched from the sandbox and exited
   successfully. This proves child-process execution, not remote
   authentication or access to every SSH configuration.
4. The probe exposes an `NSOpenPanel` flow for granting an external directory.
   Automating acceptance of that panel is deliberately outside the probe
   because the user gesture is the security boundary.

The bookmark mechanism works, but sandboxing would require users to grant
several hidden agent locations and relevant project roots before Kitroom could
produce a complete inventory. Granting the entire home directory would be
broader than Kitroom's intended access policy. That setup cost and incomplete
initial discovery are unacceptable for the version 1 management workflow.

Reproduce the automated portion with:

```bash
./scripts/build-sandbox-probe.sh
./.build/sandbox-probe/KitroomSandboxProbe.app/Contents/MacOS/KitroomSandboxProbe --diagnostic
./.build/sandbox-probe/KitroomSandboxProbe.app/Contents/MacOS/KitroomSandboxProbe --restore-only
```

## Safety constraints

Direct distribution does not permit unrestricted behavior:

- Kitroom must use explicit, bounded process requests.
- It must not scan unrelated home-directory content.
- It must reuse OpenSSH aliases, keys, agents, and host-key decisions.
- It must not request `sudo` for the initial user-level scope.
- Logs and diagnostics must redact credentials and sensitive environment data.
- User-visible approval and post-change verification remain mandatory for
  mutations.

## Consequences

### Positive

- Kitroom can evaluate the required local and SSH workflows without designing
  around unproven sandbox exceptions.
- The app can share the same `KitroomCore` code as the Swift package.
- Signing, notarization, and Gatekeeper validation remain part of release
  acceptance.

### Negative

- The first releases will not use the Mac App Store.
- Users must install a notarized app distributed outside the store.
- The project must define and enforce its own narrow filesystem-access policy.

## Revisit when

- Security-scoped bookmarks cover the required agent and project locations
  without excessive setup.
- OpenSSH execution works from a sandboxed build with the required trust
  guarantees.
- Mac App Store distribution becomes a committed requirement.
