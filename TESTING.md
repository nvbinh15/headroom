# Testing & Next Steps

The app is **already running** right now (process started during the build).
Work through these steps in order.

---

## 1. Verify the menu-bar item is showing

Look at the top-right of your screen, near the clock. You should see something
like:

```
C 54%·32%   X 4%·19%
```

- `C` = Claude  ·  `X` = Codex
- First number = 5-hour usage  ·  second = weekly usage
- Color shifts orange at ≥ 70 %, red at ≥ 90 %

If the menu bar is crowded, the macOS bar may be hiding it behind the notch —
hold ⌘ and drag it left of the clock so it's always visible.

**If you don't see anything,** the app may have been killed. Re-launch it:

```sh
open /Users/binhnguyen/Library/Developer/Xcode/DerivedData/Headroom-*/Build/Products/Debug/Headroom.app
```

---

## 2. Try the popover

Click the menu-bar text. A popover should slide down with:

- **Claude** card — 5h and Weekly progress bars, plan tier, source label
  (`API`, `API · cached`, or `estimate`)
- **Codex** card — 5h and Weekly progress bars
- A "↻" refresh button (top-right)
- "Updated <time> ago", `Settings…`, and `Quit` at the bottom

Hit **↻** to force a refresh. Numbers should match what `/usage` shows inside
Claude Code.

---

## 3. Sanity-check the numbers against `/usage`

In a Claude Code session, run `/usage`. Compare the percentages — they should
match what the menu-bar shows (within the 5-min cache window).

For Codex, you can run `codex` and check the indicator at the bottom of the TUI;
it should also match.

If both providers' numbers match the CLIs, the app is working correctly.

---

## 4. Add the desktop widget

This part is macOS-native, no Xcode involved.

1. **Right-click on an empty area of your desktop**.
2. Choose **"Edit Widgets"** (or open Notification Center → scroll to bottom →
   "Edit Widgets").
3. In the search box, type **"Headroom"**. The widget should appear.
4. Drag the small or medium size onto the desktop (or into Notification Center).
5. Click **Done**.

The widget reads the same data the menu-bar app writes, so it updates whenever
the app refreshes (default: every 60 s — WidgetKit may throttle visual updates
to once every ~5 min, that's normal).

**If "Headroom" doesn't appear in the picker,** the system needs a moment
to index the widget. Try:
- Quit the app, re-launch, wait 30 s, retry.
- Reboot once. macOS only scans new widget extensions on cold launches in some
  versions.

---

## 5. Stop / start the app manually

```sh
# Stop
killall Headroom

# Start
open /Users/binhnguyen/Library/Developer/Xcode/DerivedData/Headroom-*/Build/Products/Debug/Headroom.app
```

The app does **not** auto-start at login yet. To make it permanent, see
"Auto-launch at login" below.

---

## 6. Quick CLI sanity check (no Xcode needed)

If anything feels off, the CLI prints the exact same data the app uses:

```sh
cd /Users/binhnguyen/Desktop/token-status/HeadroomKit
swift run headroom
```

You should see:

```
Claude
  Max 5× · API
  5h     54.0%  resets in 1h53m
  weekly 32.0%  resets in 128h53m

Codex
  codex API
  5h      4.0%  resets in 1h09m
  weekly 19.0%  resets in 151h44m
```

Add `--json` for machine-readable output.

If the CLI works but the menu-bar app shows wrong numbers, the bug is in the
GUI layer, not the data layer.

---

## 7. Making changes (Xcode workflow primer)

You only need Xcode if you want to **edit the SwiftUI views** or change app
behavior. The data parsing lives in `HeadroomKit/` and can be tested
entirely from the CLI.

### Open the project

```sh
open /Users/binhnguyen/Desktop/token-status/Headroom.xcodeproj
```

### The bits to know

- The bar at the top of the Xcode window shows the **scheme** (what you'll
  build) and the **destination**. Set scheme to `HeadroomApp` and destination
  to **My Mac**.
- **⌘B** = build, **⌘R** = build + run, **⌘.** = stop running app.
- Source files live under the blue project icon in the left sidebar:
  - `HeadroomApp/` — menu-bar app (PopoverView, SettingsView, AppDelegate)
  - `HeadroomWidget/` — desktop widget (HeadroomWidgetView)
  - `HeadroomKit/` (under "Package Dependencies") — parsers, models,
    networking. **Don't edit this from Xcode** — edit the files directly with
    your editor; Xcode will pick up the changes.

### Typical change loop

1. Edit a Swift file (e.g. `PopoverView.swift` to tweak the layout).
2. ⌘R in Xcode. The currently running app gets killed and replaced.
3. Click the menu-bar item to test.

### When you change the project structure

If you add a new Swift file or change `project.yml`, regenerate the Xcode
project:

```sh
cd /Users/binhnguyen/Desktop/token-status
xcodegen generate
```

Then re-open the project (⌘W to close, then re-open from the path above —
Xcode caches the old structure and may show stale errors).

### Building from the command line (no Xcode UI)

```sh
cd /Users/binhnguyen/Desktop/token-status
xcodebuild -project Headroom.xcodeproj \
           -scheme HeadroomApp \
           -configuration Debug \
           -destination 'platform=macOS' build
```

The built bundle goes to a long DerivedData path; the easy way to launch it:

```sh
killall Headroom 2>/dev/null
open /Users/binhnguyen/Library/Developer/Xcode/DerivedData/Headroom-*/Build/Products/Debug/Headroom.app
```

---

## 8. Auto-launch at login (optional)

Right now you have to launch the app manually after each reboot. To run it at
login without Xcode:

1. Open **System Settings ▸ General ▸ Login Items & Extensions**.
2. Under **Open at Login**, click **+**.
3. Navigate to the DerivedData path:

   ```
   ~/Library/Developer/Xcode/DerivedData/Headroom-<hash>/Build/Products/Debug/Headroom.app
   ```

   (Use ⌘⇧G to paste the path directly.)
4. Click **Open**.

> **Caveat:** the DerivedData hash changes if you delete derived data. For a
> stable path, copy the `.app` bundle to `/Applications` once you're happy with
> a build:
>
> ```sh
> cp -R ~/Library/Developer/Xcode/DerivedData/Headroom-*/Build/Products/Debug/Headroom.app /Applications/
> ```
>
> Then add `/Applications/Headroom.app` to Login Items instead.

---

## 9. Troubleshooting

### Menu-bar shows `C —%·—%` (dashes) for Claude

The OAuth `/api/oauth/usage` endpoint returned an error and there's no cached
response yet. Possible causes:

- **No keychain credentials.** Open `claude` once and complete the login flow
  if you haven't recently.
- **429 rate limit.** Wait 30 min and try again. The cached file lives at
  `~/Library/Caches/Headroom/claude-oauth-usage.json`.
- **Token expired.** Run `claude` once — it'll refresh the token in the
  keychain on the next API call.

Run the CLI with `swift run headroom` to see the exact error.

### Codex side shows `no recent codex sessions`

You haven't used Codex in the last 7 days. The data only refreshes when Codex
itself writes a new `rate_limits` block during a session. Run any Codex command
(even `codex --help`) and the next refresh should pick it up — actually, you
may need a real session like `codex exec "echo hi"`.

### Codex numbers don't match `codex` (the TUI)

The widget should match the TUI exactly — both call
`https://chatgpt.com/backend-api/wham/usage` (the same endpoint Codex hits on
launch). Throttled to once every 5 min, cached to disk.

If they drift, check:

- **Auth missing/expired.** `~/.codex/auth.json` must exist with a valid
  `tokens.access_token`. Run `codex login` if it's been a while; the JWT
  in `auth.json` typically lives ~10 days.
- **Cache too aggressive.** Force a refresh with `swift run headroom` in
  `HeadroomKit/`, which respects the same 5-min throttle, or delete
  `~/Library/Caches/Headroom/codex-wham-usage.json` and reopen the popover.

If both Claude and Codex APIs are unreachable, the widget falls back to:
- Claude: a local-jsonl token estimator (rough — used only when API stays
  429'd longer than the cache TTL)
- Codex: the most recent on-disk session's `rate_limits` snapshot. This can
  drift since it's only updated when Codex itself sends an API call.

### Widget is blank / shows old numbers

WidgetKit aggressively caches timeline entries. Try:

```sh
killall WidgetKit Simulator chronod 2>/dev/null  # safe; system restarts them
killall Headroom
open ~/Library/Developer/Xcode/DerivedData/Headroom-*/Build/Products/Debug/Headroom.app
```

Or remove the widget and re-add it.

### App won't launch / crashes immediately

Check Console.app:

1. Open **Console.app**.
2. In the search box, type **TokenStatus**.
3. Click **Start streaming** and re-launch the app — the crash log will appear.

Common crash cause: keychain access denied. macOS may pop a one-time dialog
asking *"TokenStatus wants to access your keychain"* — click **Always Allow**.

### "I changed code in `HeadroomKit/` and Xcode shows the old version"

Xcode caches Swift package builds. Clean and rebuild:

- In Xcode: **Product ▸ Clean Build Folder** (⇧⌘K), then ⌘R.
- Or via CLI:
  ```sh
  rm -rf ~/Library/Developer/Xcode/DerivedData/Headroom-*
  ```

---

## 10. What's next (potential follow-ups)

These weren't built but would be easy adds — let me know which you want:

- **Auto-launch at login from the app itself** (using `SMAppService`, no
  System Settings).
- **Settings UI for plan-tier override** (currently the fallback estimator
  uses defaults; UI exists but the override field is read-only).
- **Per-model breakdown** for Claude (the OAuth response includes
  `seven_day_sonnet`, `seven_day_opus` — we ignore them).
- **Notifications** when usage crosses a threshold (e.g. ping at 80 %).
- **A code-signed `.app` for `/Applications/`** so the path is stable across
  rebuilds.
