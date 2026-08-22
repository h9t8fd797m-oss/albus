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
