# ADR 0004: Versioned persistence envelopes

- **Status:** Accepted
- **Date:** 2026-07-28

## Context

Kitroom persists immutable domain values as JSON payloads inside a small
SwiftData record model. Operation records can outlive the app version that
created them, so adding an execution action or expected-state field must not
make earlier activity unreadable. Conversely, a newer record must never be
silently interpreted by an older app as empty or safe.

SwiftData's storage schema and the encoded domain payloads evolve at different
rates. Treating them as one version would force a database migration for every
additive domain change and obscure which compatibility boundary failed.

## Decision

Keep two explicit compatibility boundaries:

1. The SwiftData model owns record identity, kind, timestamps, payload bytes,
   and `schemaVersion`.
2. Each encoded domain type owns its `Codable` compatibility rules.

Payload schema version 1 remains current while changes are additive and the
decoder can supply a conservative default. For example, older remote skill
plans without an action decode as install plans, while older remote plugin
plans decode as installed-before and installed-after with their legacy version
bound to both states. New plans always encode the expanded fields, and approval
digests include them.

A record whose `schemaVersion` is newer than the running app fails with
`unsupportedSchemaVersion`. The persistence layer must not skip it, replace it
with an empty snapshot, or report a successful load.

## Migration procedure

Before increasing the payload schema version:

1. Define the old and new envelope shapes and the exact failure behavior.
2. Add fixture tests that decode every retained old record kind.
3. Add an explicit pure transformation from the old value to the new value.
4. Back up the store before any in-place rewrite.
5. Migrate through a temporary store or transaction and validate record counts,
   keys, kinds, timestamps, and decoded payloads before replacement.
6. Keep the original backup until the migrated app has opened, loaded every
   record kind, and written a new record successfully.
7. Abort without replacing the original store on an unknown kind, future
   version, decode failure, count mismatch, or validation failure.

If the SwiftData model itself changes, add a `VersionedSchema` and staged
`SchemaMigrationPlan` independently of the payload transformation.

## Compatibility rules

- Removed enum cases require an explicit legacy mapping; they may not fall
  through to a healthy or completed state.
- New safety-relevant fields default to the most restrictive interpretation
  that preserves the original operation.
- Unknown or partial inventory remains unknown or partial after migration.
- Operation identifiers, approval material, event timelines, backup paths,
  and terminal states are preserved exactly.
- Secrets and unrestricted command output must not be introduced during
  migration.
- Failed migration is visible to the app as unavailable persistence, never as
  an empty successful history.

## Consequences

- Additive domain changes can remain readable without unnecessary database
  migrations.
- Compatibility decisions are reviewable beside the affected domain type.
- Future schema upgrades require fixtures and fail-closed validation before
  release.
- The beta does not yet include a general migration runner because no payload
  schema increase is required. ADR 0004 defines the gate for adding one.
