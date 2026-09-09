# health4ai — design reference

**Owner:** Jess (JGLI) reviews, Sasha Kim gates. Created 2026-09-09 after the design gate
flagged twice that this repo carries a blocking review with no token document.

This describes what the app **actually does today**, verified against
`ios/Health4AI/HomeView.swift`. It is not aspirational. If a rule here disagrees with the
code, one of them is wrong — say which rather than quietly following the code.

## Colour

**Every colour is a SwiftUI system semantic. There are no raw hex values in the iOS app,
and none should be added.** That is what makes the app correct in light mode, dark mode
and increased-contrast for free.

| Role | Token | Used for |
|---|---|---|
| Page ground | `Color(.systemGroupedBackground)` | `ScrollView` background |
| Card ground | `Color(.secondarySystemGroupedBackground)` | every card |
| Primary text | `.primary` | headline + body |
| Secondary text | `.secondary` | captions, sublabels |
| Brand accent | `.pink` | the ONE prominent action per screen |
| Healthy | `.green` | connected, complete |
| Attention | `.orange` | partial data, stalled import |
| Failure | `.red` | sync error, destructive rows |
| In progress | `.blue` | actively syncing |

### Two rules that have already been broken once each

1. **Orange and red are for symbols and fills, not for body text.** Measured 2026-09-09:
   orange caption text on the card ground is **2.31:1** in light mode, below even the 3:1
   large-text floor. Put the semantic on the icon and a 12% tint background; keep the
   words on `.primary`.
2. **`.pink` on `.borderedProminent` with white text is 3.52:1 and fails AA.** It is
   tolerated on the single genuine primary action per screen and nowhere else. Do not
   spread it, and do not use it for a secondary action to "keep things on brand".

## Status colour is a single signal

`statusColor` in `HomeView.swift` is the one place that maps state to colour, and the
status card's icon, title, border and subtitle all read from it. Precedence, highest
first: syncing → error → **partial data** → connection health.

**Never add a second, independent colour path for the same state.** The bug this ordering
exists to prevent: the headline said green "Active" while the card below it named four
metrics that had returned nothing.

## Honest numbers

The app reports on data it does not own, so a number on screen is a claim.

- **Never render a value the server did not supply.** `postSamples` returns `Int?`; nil
  means the endpoint did not report, and nil must render as *absence of a line*, never
  as `0`. A definite zero is as much a fabrication as a definite success.
- **"Sent" and "stored" are different claims.** The ingest upserts, so a re-sweep posts
  hundreds of thousands of samples and stores none. Show the stored number first — it is
  the trustworthy one — and never collapse the pair into one figure.
- **A spinner is a claim too.** If nothing has moved, stop it. A spinner above the words
  "nothing has moved" is a contradiction, and the spinner wins.
- **Green means verified, not attempted.** An operation that completed without evidence
  gets attention colour, not success colour.

## Buttons

- **One prominent action per card, maximum.** Prominence follows what the button does;
  a secondary action rendered full-width and tinted reads as an unresolved error on a
  healthy screen.
- **Destructive rows are `.red`,** and anything that discards work asks first with a
  `confirmationDialog` stating the cost in plain terms ("It can take hours").
- **Label the action, not the mechanism.** "Retry These Metrics" must retry exactly the
  metrics named above it — if the label says "these", passing a wider set is a lie.
- **A recovery instruction names a control that exists, is visible, and is enabled.**
  Prose pointing at a disabled button in another card is not a recovery path; put the
  button in the message.
- **44pt minimum** on every tap target.

## Type

System font throughout. `.largeTitle` nav title, `.headline` card titles, `.subheadline`
primary values, `.caption`/`.caption2` support text. **Numbers get `.monospacedDigit()`**
so live counters do not jitter.

**Verify at `.accessibilityXXXL` on a 375pt width.** A concatenated `Text` containing a
formatted number broke *mid-number* there and rendered a different figure — split stacked
values into separate `Text` views rather than joining with a separator.

## Cards

Rounded rectangle, corner radius 16, `.padding()`, on the card ground. A card that can
render more than one state needs `.frame(maxWidth: .infinity, alignment: .leading)` —
without a width-expanding child, one state collapses to its intrinsic width and the card
visibly changes size between states.

## Before merging a frontend change here

Run the Sasha Kim gate. It renders the real states rather than reading the diff, which is
how every finding above was actually caught.
