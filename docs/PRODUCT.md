# Product definition

## One-sentence promise

Kitroom gives developers one macOS interface for inspecting and managing Claude
Code and Codex capabilities on local and remote machines.

## Problem

Coding-agent capabilities are distributed across configuration files,
agent-specific directories, plugin registries, marketplaces, and runtime
injection layers. The same developer may have different or stale state on a
local machine and a remote server. Existing command-line workflows make it
difficult to answer basic questions:

- What is installed here?
- Where did it come from?
- Which agent can see it?
- Is it current?
- What exactly will uninstalling it change?
- Does my remote host match my local setup?

## Users

### Primary

An individual developer who runs Claude Code and Codex on a Mac and one or more
SSH-accessible development or production servers.

### Later

- Small engineering teams maintaining approved capability sets
- Tool authors publishing signed skills or plugins
- Administrators enforcing provenance and version policies

## MVP jobs

1. Add the Mac running Kitroom automatically.
2. Add a remote host using an existing OpenSSH alias.
3. Detect Claude Code and Codex on each host.
4. Build a fresh, evidence-backed inventory.
5. Distinguish skill, plugin, and MCP-server origins.
6. Browse supported catalogues and source repositories.
7. Preview and approve one install, update, disable, or uninstall.
8. Back up affected state, apply the plan, and verify the result.
9. Compare capability state between two hosts.
10. Export a redacted diagnostic report.

## Non-goals for MVP

- Running or orchestrating coding-agent sessions
- Monitoring token usage or model cost
- Editing source code on behalf of an agent
- Replacing Claude Code or Codex
- Storing SSH private keys
- Managing system-wide packages with root privileges
- Automatically synchronising hosts without user review
- Operating as a general-purpose dotfile manager

## Core screens

1. **Hosts:** connection health, platform, agents, and inventory freshness.
2. **Inventory:** filter by agent, capability type, origin, state, and host.
3. **Catalogue:** browse available capabilities with provenance and
   compatibility.
4. **Plan review:** exact targets, commands, risk, backup, rollback, and
   verification.
5. **Comparison:** explain differences between two hosts.
6. **Activity:** operation status and redacted verification evidence.
7. **Settings:** SSH behaviour, catalogue sources, update policy, and logging.

## Success criteria

- A user can accurately inventory the local machine and at least one
  SSH-accessible remote host.
- Unknown or partial state is never shown as complete.
- Every mutation is previewed and bound to an explicit approval.
- Every completed operation includes fresh post-change verification.
- A failed operation leaves a recoverable backup and actionable evidence.
- Adapter-specific details do not leak into unrelated UI or transport code.
