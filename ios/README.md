# Albus — iOS

```
AlbusCore/     Swift package: models, scheduler, estimator, design tokens
App/Albus/     The app target (SwiftUI)
project.yml    Xcode project definition — the source of truth
```

## Building

The `.xcodeproj` is **generated, not committed** — that file is machine-written,
merges badly, and hides real changes in noise.

```bash
brew install xcodegen        # once
cd ios && xcodegen generate  # after editing project.yml
open Albus.xcodeproj
```

The core logic builds and tests without Xcode at all, which is where most of
the work happens:

```bash
cd ios/AlbusCore && swift test
```

## ⚠️ Signing is deliberately unset

The app builds and runs in the simulator as is. To run on a **physical device**
or ship to TestFlight, set the Apple Team ID:

1. Find it under Membership in the Apple Developer account (10 characters).
2. In `project.yml`, under `settings.base`, add:
   ```yaml
   DEVELOPMENT_TEAM: XXXXXXXXXX
   CODE_SIGNING_ALLOWED: YES
   ```
3. `xcodegen generate`

Nothing else depends on this. It was left out so the project could be set up
without waiting on the account.

## What's built

| | |
|---|---|
| **Scheduler** | Places work in time and re-places it when reality diverges. 25 tests. |
| **Estimator** | Learns how long *this* student actually takes. 10 tests. |
| **Tokens** | Colours, type, spacing sampled from the design exports. |
| **App shell** | Full-screen gradient + floating tab bar, four tabs. |

Screens are not built yet — the tabs show placeholders.

## Two things that are load-bearing

**The gradient lives inside `Screen`, not behind the `NavigationStack`.** A
navigation stack paints its own opaque surface, so a gradient placed behind one
is simply covered — the first version of this shipped a plain white background
for exactly that reason. `Screen` also applies the bottom inset the floating
tab bar needs, so no screen has to remember either concern.

**Views never name a colour.** Everything comes from `Tokens`. Subject colour
is a property of the course, not the card that shows it: HIST is red on every
screen, and a view maps the enum rather than picking.
