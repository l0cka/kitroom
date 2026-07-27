# Kitroom design guide

- **Status:** Initial identity and product-language baseline
- **Created:** 2026-07-27
- **Applies to:** macOS application, repository, documentation, and release
  material

## Brand idea

Kitroom is the place where an agent's equipment is stored, inspected,
maintained, and issued. The visual system should feel:

- **Operational:** state and consequences are visible.
- **Calm:** the interface reduces anxiety around configuration changes.
- **Precise:** labels, targets, and evidence are unambiguous.
- **Native:** it behaves like a considered macOS utility.
- **Trustworthy:** uncertainty is disclosed rather than visually smoothed over.

Avoid generic AI imagery. Kitroom is not represented by a robot, brain,
sparkle, magic wand, or chat bubble. The product is about capability
management, provenance, and verified state.

## Logo

![Kitroom logo](../Assets/Brand/kitroom-logo.png)

### Meaning

The mark combines:

- an equipment cabinet with three modular compartments;
- a strong negative-space `K`;
- a connected amber node representing another host;
- a dark field representing a controlled operational environment.

The cabinet communicates organization. The `K` gives the mark a distinct
silhouette. The remote node shows that Kitroom can manage both local and remote
hosts.

### Canonical asset

| Asset | Use | Format | Size |
| --- | --- | --- | --- |
| `Assets/Brand/kitroom-logo.png` | Design reference and provisional app icon | PNG | 1024 × 1024 |
| `Assets/Brand/kitroom-logo-readme.png` | Optimized repository header | PNG | 384 × 384 |

The current asset is the approved raster identity concept. Before the signed
beta, redraw the mark as a precise vector master and export the complete macOS
app-icon set. The vector redraw must preserve the selected silhouette and
proportions rather than reinterpret the brand.

The tracked `AppIcon.appiconset` is a provisional set mechanically scaled from
the raster master. It makes development builds identifiable but does not
replace the planned vector redraw and small-size glyph.

The concept PNG includes restrained tonal depth in the dark field and cabinet.
The vector master should normalize the geometry and colors while retaining the
same overall depth and contrast.

### Clear space

Keep clear space on every side equal to at least 12% of the mark's rendered
width. Do not place badges, text, window chrome, or other icons inside this
area.

### Minimum size

- Repository and marketing use: 96 px or larger
- Product navigation and About screen: 32 px or larger
- Below 32 px: use a future simplified micro-glyph without drawer handles or
  the remote-node rings

Do not shrink the current detailed mark to a 16 px toolbar glyph.

### Placement

- Prefer the canonical midnight background contained in the asset.
- Keep the mark upright and centered.
- Pair it with the product name set in the system typeface; do not rasterize a
  separate decorative wordmark.
- In documentation, use the mark once near the title rather than repeating it
  throughout the page.

### Do not

- Rotate, skew, stretch, crop, or outline the mark.
- Recolor individual drawers.
- Remove the remote node.
- Add exaggerated glow, glass, metallic, or photorealistic effects.
- Place the mark on a visually competing pattern.
- Combine it with another vendor's agent logo.
- Use the mark as a generic status icon inside the product.

## Color system

The brand palette supports identity. Product state should still prefer macOS
semantic colors so it remains legible across appearances and accessibility
settings.

| Token | Hex | Role |
| --- | --- | --- |
| `Kitroom Ink` | `#0B1420` | Primary dark field, launch and repository identity |
| `Kitroom Slate` | `#17263A` | Dark secondary surface |
| `Kitroom Mint` | `#3DD6B3` | Brand action, selected accents, verified connection |
| `Kitroom Mint Deep` | `#147A69` | Accessible mint text on light surfaces |
| `Kitroom Amber` | `#F2A65A` | Remote link, attention, pending review |
| `Kitroom Cloud` | `#F4F7FA` | Light neutral background |
| `Kitroom Steel` | `#718096` | Secondary metadata |
| `Kitroom Danger` | `#C94444` | Destructive or failed state |

### Color rules

- Use `Kitroom Mint` as an accent, not a large body-text color on white.
- Use `Kitroom Amber` for attention and remote linkage, not as a success color.
- Use `Kitroom Danger` only for destructive actions and verified failures.
- Never encode status with color alone; pair it with a symbol and text.
- Test final foreground/background combinations in both Light and Dark
  appearances. Normal text must reach a 4.5:1 contrast ratio.

### SwiftUI direction

Prefer semantic platform colors for surfaces:

```swift
Color(nsColor: .windowBackgroundColor)
Color(nsColor: .controlBackgroundColor)
Color.primary
Color.secondary
Color.accentColor
```

Add brand colors through the asset catalogue when the Xcode app target is
created. Do not scatter raw hex values through views.

## Typography

Use the macOS system typefaces.

| Content | Typeface | Direction |
| --- | --- | --- |
| Navigation and UI | SF Pro via SwiftUI `.system` | Default macOS sizing and Dynamic Type |
| Commands, versions, paths, digests | SF Mono via `.monospaced` or `.monospacedDigit` | Never use for explanatory paragraphs |
| Repository and documentation | System sans-serif | Let GitHub render Markdown naturally |

### Hierarchy

- Screen title: `.largeTitle.bold()`
- Section title: `.title2.weight(.semibold)`
- Card title: `.title3.weight(.semibold)`
- Body: `.body`
- Metadata: `.callout` or `.caption`
- Command/path: `.callout.monospaced()`

Avoid all-caps headings, condensed type, and decorative coding fonts.

## Layout

### Grid

- Base spacing unit: 4 pt
- Normal spacing rhythm: 8, 12, 16, 24, and 32 pt
- Card padding: 16 or 20 pt
- Major screen padding: 24 or 28 pt
- Compact control height: follow native macOS controls

Use spacing, alignment, and typography to establish hierarchy before adding
dividers or background fills.

### Window structure

The primary window uses a native `NavigationSplitView`:

```text
Sidebar                 Content
├── Hosts               Host or inventory title
├── Inventory           Filters and freshness
├── Catalogue           Primary content
├── Activity            Evidence or detail inspector
└── Settings
```

- Sidebar ideal width: 240 to 260 pt
- Main content minimum width: 640 pt
- Keep primary actions in the toolbar or the content header.
- Use sheets for focused plan approval.
- Use an inspector for evidence, provenance, and immutable detail.

## Iconography

Use SF Symbols in the product UI. Keep one semantic meaning per symbol.

| Meaning | Symbol direction |
| --- | --- |
| Local host | `laptopcomputer` |
| Remote host | `server.rack` |
| Skill | `text.book.closed` |
| Plugin | `shippingbox` |
| MCP server | `network` |
| Verified | `checkmark.circle.fill` |
| Partial | `exclamationmark.triangle.fill` |
| Unknown | `questionmark.circle` |
| Not scanned | `circle.dashed` |
| Refresh/scan | `arrow.clockwise` |
| Evidence | `doc.text.magnifyingglass` |
| Rollback | `arrow.uturn.backward.circle` |

Do not use the Kitroom logo as a replacement for these operational symbols.

## State language

Kitroom must distinguish absence, failure, and lack of evidence.

| State | Meaning | Visual direction |
| --- | --- | --- |
| Not scanned | No inventory attempt has occurred | Neutral dashed symbol |
| Scanning | A bounded inspection is active | Progress indicator plus text |
| Verified | Fresh evidence confirms expected state | Check symbol and semantic success color |
| Partial | Some probes succeeded and some did not | Amber warning and issue count |
| Unknown | Evidence cannot establish the state | Neutral question symbol |
| Unavailable | The agent or host is confirmed unavailable | Failure symbol with reason |
| Stale | A prior snapshot exists but is outside freshness policy | Clock symbol and capture time |

Never replace **Unknown** with **Healthy**, **Absent**, or a zero count.

## Local and remote distinction

Remote operations carry more context and failure modes. Make the distinction
persistent rather than relying on a one-time confirmation.

- Always show the host name and transport on inventory and plan screens.
- Show the SSH alias separately from verified host identity.
- Use the amber remote-link accent sparingly on remote-host chrome.
- Prefix destructive confirmation titles with the host name.
- Keep local and remote activity entries visually distinguishable.
- Never use green merely because an SSH command returned exit code zero.

## Core components

### Host row

Contains host name, local/remote symbol, connection description, last scan, and
honest state. Do not show capability counts until a scan establishes them.

### Agent card

Contains agent name and version, inventory freshness, package/capability counts,
and issues. Counts must be derived from one snapshot.

### Inventory table

Use a package/capability hierarchy rather than a flat icon grid. Essential
columns are name, kind, agent, scope, origin, state, version, and freshness.

### Status badge

Use short noun or adjective labels such as **Verified**, **Partial**,
**Unknown**, and **Stale**. Include a symbol. Avoid vague labels such as
**Good**, **Ready**, or **Problem**.

### Plan review

The review sheet must show:

1. host and verified identity;
2. agent, package, and scope;
3. exact files and native commands;
4. before and expected-after state;
5. source and digest;
6. risk and warnings;
7. backup and rollback;
8. verification probes.

The approval button names the action: **Install skill**, **Disable plugin**, or
**Uninstall from build-server**. Do not use a generic **Continue** button.

### Evidence inspector

Evidence is supporting material, not visual noise in the main table. Show probe
name, captured time, source, parser version, status, and a bounded redacted
diagnostic.

## Action hierarchy

| Action | Style |
| --- | --- |
| Scan, browse, compare | Standard or bordered |
| Install, update, enable | Prominent only after a valid plan exists |
| Disable | Standard with explicit scope |
| Uninstall or rollback | Destructive role and confirmation |
| Unsupported | Disabled with a reason available |

Only one visually primary action should appear in a decision area.

## Motion

- Use native transitions and progress indicators.
- Keep ordinary transitions between 120 and 200 ms.
- Never animate counts from zero when zero was not established by evidence.
- Do not use celebratory animation for infrastructure mutations.
- Respect Reduce Motion and Reduce Transparency.
- Keep long operations visibly cancellable when cancellation is safe.

## Content design

### Voice

Write in calm, direct language:

- "The remote host could not be verified."
- "Three probes succeeded; one requires permission."
- "This plugin also installs two skills and one MCP server."
- "The command completed, but verification did not."

Avoid:

- "Everything looks great!"
- "No plugins found" after a failed scan.
- "Success" without the verified result.
- Agent-specific jargon when a precise plain-language label exists.

### Formatting

- Show friendly names first and exact identifiers second.
- Render commands, versions, paths, hashes, and SSH aliases in monospaced text.
- Show relative freshness with an accessible absolute date in the detail view.
- Keep error summaries short; place technical evidence in the inspector.
- Never display credentials or unrestricted environment content.

## Accessibility

- Meet WCAG AA contrast at minimum.
- Pair color with text and an SF Symbol.
- Preserve visible keyboard focus.
- Support full keyboard navigation for sidebar, tables, filters, and sheets.
- Give every icon-only button an accessibility label and help text.
- Prefer native controls so VoiceOver semantics remain intact.
- Keep ordinary pointer targets at least 28 × 28 pt and use 44 × 44 pt where
  touch-like precision may be expected.
- Do not place meaning only in hover content.
- Test Light, Dark, Increased Contrast, Reduce Motion, and Reduce Transparency.

## README and repository badges

Use only badges that communicate durable project facts:

- CI status
- Swift version
- macOS deployment target
- licence

Do not add download, star, activity, or coverage badges until those metrics are
meaningful and maintained.

## Asset production checklist

Before the signed beta:

1. Redraw the selected mark as an SVG or PDF vector master.
2. Create a simplified small-size glyph.
3. Export the macOS app-icon sizes from a 1024 × 1024 master.
4. Validate the icon on Light and Dark desktops.
5. Validate at 16, 32, 64, 128, 256, 512, and 1024 px.
6. Add the colors to an Xcode asset catalogue.
7. Confirm no third-party trademarks or agent logos are embedded.
8. Update this guide if proportions, colors, or usage rules change.

## Governance

Changes to the primary mark, palette, typography, state vocabulary, or action
hierarchy require:

- an update to this guide;
- validation in Light and Dark appearances;
- accessibility review;
- a note in the relevant architecture or product decision when behaviour is
  affected.
