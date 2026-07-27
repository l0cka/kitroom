# Accessibility audit

- **Scope:** Kitroom 0.1 beta interface
- **Last reviewed:** 2026-07-27
- **Status:** Code and running-app review complete; release-candidate review
  remains required after signing

## Reviewed surfaces

The running macOS application was inspected through the accessibility tree in
the current system appearance. Hosts, Inventory, Catalogue, Activity, Settings,
and the operation-review sheet expose their titles, controls, current values,
and help text without relying on color alone.

| Surface | Empty or unavailable state | Loading and cancellation | Partial, stale, or recovery state | Keyboard path |
| --- | --- | --- | --- | --- |
| Hosts | No-host guidance and Not checked state | Per-host progress and retry | Authentication, identity change, offline, denied, and partial discovery | Sidebar, add-host sheet, check/cancel |
| Inventory | No host, not scanned, and no verified items | Check/cancel and Command-R | Freshness banner, evidence status, and partial issues | Sidebar, search, filters, disclosure rows |
| Catalogue | Not scanned and no matching packages | Refresh/cancel and Command-R | Source freshness, integrity, compatibility, and incomparable state | Mode picker, host/agent pickers, search, disclosures |
| Activity | No operations yet | Applying and verifying | Verification failure, rollback state, retained or deleted backup | Cards, confirmation alerts, review sheet |
| Settings | Readable policy values | Not applicable | Backup, privacy, and distribution limitations | Sidebar and project link |

## Interaction and semantics

- Sidebar rows are selectable and retain visible selection.
- Icon-only toolbar controls have accessible descriptions and help.
- Inventory and catalogue disclosure rows expose a name and state summary.
- Search fields, filters, host pickers, and optional project paths have labels.
- Unknown, partial, and stale states use text and symbols, not color alone.
- The operation-review sheet identifies the host, transport, agent, scope,
  risk, exact effect, rollback, verification, and plan digest.
- Remote mutations require a separate target acknowledgement before the
  default action applies the approved plan.
- Destructive backup deletion uses a labelled button and a confirmation alert.
- Cancel is bound to Escape where a modal operation can be dismissed.
- Refresh is bound to Command-R on Inventory and Catalogue.
- Confirmation actions use the standard default-action shortcut only after
  any remote acknowledgement requirement has been met.

## Visual review

The running app was reviewed at its default window size with system dark mode.
Text remained legible, focus and selection used system treatments, status
chips preserved text labels, and the primary content did not depend on precise
pointer targeting. SwiftUI semantic colors and Dynamic Type-compatible text
styles are used throughout.

## Release-candidate checks

Repeat these checks on the signed, notarized build:

1. Navigate every interactive control with Full Keyboard Access enabled.
2. Read each core screen and both confirmation alerts with VoiceOver.
3. Verify focus returns to the initiating control after dismissing a sheet.
4. Verify Increase Contrast, Reduce Transparency, and Reduce Motion.
5. Check light and dark appearances at the smallest supported window size.
6. Confirm no truncated title, status, digest, or destructive-action label.

An unchecked item is a release blocker, not evidence that the interface is
accessible.
