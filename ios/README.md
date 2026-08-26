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

## ⚠️ Session persistence needs a Team ID

`App/Albus/Albus.entitlements` declares the Keychain access group the auth
session needs. It only takes effect on a **signed** build.

**On the simulator (unsigned)** the session falls back to `UserDefaults`
(`ResilientAuthStorage`). It survives relaunches — verified, 4 launches produce
1 account — but not app deletion, so a reinstall signs in as a new anonymous
user.

**On a signed device build** Keychain is used, and its items survive app
deletion, so a reinstall cannot reset the free-tier quota.

Enabling ad-hoc signing to get the entitlement on the simulator was tried and
reverted: it produced an `application-identifier` the simulator container did
not match, and SwiftData then failed with *Sandbox access to file-write-create
denied*. A working app is worth more than an entitlement that cannot be
verified here.

Quota enforcement does not depend on any of this — the global spend fuse
(migration 0013) bounds abuse regardless of how many accounts exist.

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
| **Notifications** | Twelve kinds, planned purely in `AlbusCore`. 58 tests. |

Every tab is a real screen: Home is the assignment list, Rubrics owns saved
rubrics, Albus is the chat, Tools is the catalogue. Focus Mode, the plan editor,
grading, the month calendar and notification settings all exist.

## Two things that are load-bearing

**The gradient lives inside `Screen`, not behind the `NavigationStack`.** A
navigation stack paints its own opaque surface, so a gradient placed behind one
is simply covered — the first version of this shipped a plain white background
for exactly that reason. `Screen` also applies the bottom inset the floating
tab bar needs, so no screen has to remember either concern.

**Views never name a colour.** Everything comes from `Tokens`. Subject colour
is a property of the course, not the card that shows it: HIST is red on every
screen, and a view maps the enum rather than picking.


---

## CAPTCHA — built, and off until you add a key

Onboarding exists now, and with it the CAPTCHA plumbing. **The client side is
done**: `Services/CaptchaService.swift` presents a Cloudflare Turnstile
challenge in a `WKWebView` and passes the token to `signInAnonymously`.

**It is deliberately inert until configured.** The switch is the presence of a
site key: with `TURNSTILE_SITE_KEY` empty, no challenge is shown and sign-up
behaves exactly as before. This matters because the two sides must be turned on
*together* — a secret configured in Supabase without a key in the app rejects
every new sign-up, and a key in the app without the secret verifies nothing.

**Why Turnstile rather than hCaptcha** (`config.toml` still names hcaptcha, and
should be updated when you switch it on): Turnstile runs in a plain WebView, so
it costs zero third-party SDKs in an app that has almost none, and it is free at
higher volume.

### Turning it on — all three, in one go

1. **Cloudflare** → Turnstile → create a widget. Set its hostname to the value
   of `TURNSTILE_ORIGIN` in your `Config.xcconfig` (default `albus.app`). The
   hostname must match: Turnstile checks the page origin, which is why the
   WebView loads its HTML with an explicit base URL rather than `about:blank`.
2. **App** → paste the **site** key into `TURNSTILE_SITE_KEY` in
   `App/Config.xcconfig`, and rebuild.
3. **Supabase** → Authentication → Settings → Bot and Abuse Protection → enable,
   provider Turnstile, paste the **secret** key.

### Then verify, on a fresh install

Delete the app first — an existing install has a session and will never hit
sign-up, so testing on it proves nothing. A fresh install must reach the app.
`AlbusUITests` covers exactly this path and is the fastest check:

```
xcodebuild test -scheme Albus -only-testing:AlbusUITests
```

**Until it is on**, account farming stays bounded by the global spend fuse
(`app_config.global_ai_calls_per_hour`, currently 2000/hour) plus the per-IP
sign-up limit of 10/hour. The residual risk is cost, not data — see
`docs/security-model.md` § 6.


---

## Notifications — what only works on a signed build

Albus speaks first: a morning brief, a nudge when a block starts, a deadline
ladder, and the one no other planner can send — **your plan stopped fitting**,
straight off `ScheduleResult.unplaceable`.

All of the policy lives in `AlbusCore/Notifications/` and imports no
`UserNotifications`, so quiet hours, the daily cap, the 64-slot budget and DST
are all answered by `swift test` with no simulator. The app half is a
namespace-scoped diff against what iOS actually holds.

**Two things worth knowing before changing any of it.**

*`albus.session.*` is not ours.* The focus timer owns that namespace, and a
rebuild that called `removeAllPendingNotificationRequests` would delete a
running timer's only alert — `reschedule` can fire mid-session. The rebuild only
ever touches `albus.plan.*`, checked in both the client and the coordinator.

*The 64-slot ceiling is real for paying users only.* iOS keeps the 64
soonest-firing pending notifications and silently discards the rest. Free tier
caps at three assignments and never approaches it; Plus is uncapped. The planner
allocates to 48 explicitly and logs anything it drops.

### Blocked on a Team ID

`ALBUS_SIGNED_BUILD` in `App/Config.xcconfig` gates Time Sensitive delivery on
overdue and plan-broken warnings, the same way `TURNSTILE_SITE_KEY` gates the
CAPTCHA. Set it to `YES` in the same change that sets `DEVELOPMENT_TEAM`.

Being honest about what that flag buys: setting `.timeSensitive` **without** the
entitlement is *ignored* by iOS rather than rejected, so leaving it `NO` costs
nothing today. It is there so the capability is legible and so switching it on is
one line rather than an investigation.

**Live Activities** (a Dynamic Island countdown for a focus session) and
**Communication Notifications** (Albus rendered as a correspondent rather than an
app) both need a Team ID *plus* a new extension target. They are the natural v2.

### What no test can cover here

Actual delivery, lock-screen truncation and the attachment at true scale need a
device. **DST cannot be meaningfully verified by hand at all** — `simctl` cannot
move the clock usefully — so `NotificationPlannerTests` is the real coverage for
it, not a manual pass.

To see what is actually queued in the simulator:

```bash
D=~/Library/Developer/CoreSimulator/Devices/<udid>/data/Library/UserNotifications
strings "$(ls -t $(find "$D" -name PendingNotifications.plist) | head -1)" | grep -o "albus\.plan\.[a-zA-Z0-9._-]*" | sort -u
```

That is how the last two copy bugs were found, after every unit test was green.
