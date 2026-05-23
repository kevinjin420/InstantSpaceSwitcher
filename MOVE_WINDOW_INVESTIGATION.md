# Move-Window-To-Desktop: Investigation Notes

## Symptom

Hotkeys for "Move window to space N" (`moveToSpace1`..`moveToSpace9`) fire,
the Swift handler is invoked, the C function `iss_move_frontmost_window_to_index`
runs to completion (debug `fprintf`s print expected window/space IDs), but the
window does not actually move and no error is raised.

Everything else in the app (space switching, hotkey binding, settings, OSD)
works.

## Current Implementation

`Sources/ISS/ISS.c:743-784`:

```c
bool iss_move_frontmost_window_to_index(unsigned int targetIndex) {
    ...
    if (&CGSAddWindowsToSpaces != NULL)
        CGSAddWindowsToSpaces(connection, windowsArr, targetSpaces);
    if (&CGSRemoveWindowsFromSpaces != NULL)
        CGSRemoveWindowsFromSpaces(connection, windowsArr, currentSpaces);
    ...
}
```

Where `connection = CGSMainConnectionID()` — i.e. **our own process's**
window-server connection.

Bridge layer (working):
- Hotkey enum: `Sources/InstantSpaceSwitcher/Hotkeys/HotkeyConfiguration.swift:261`
- Dispatch: `Sources/InstantSpaceSwitcher/Core/AppDelegate.swift:303-321`
- Swift→C call: `Sources/InstantSpaceSwitcher/Core/AppDelegate.swift:350-354`

## Root Cause

Starting in **macOS 12.7 / 13.6 / 14.5 / 15.0+**, Apple changed the private
SkyLight APIs that move windows between Spaces. The symbols still exist, but
when called with your own process's `CGSMainConnectionID()` to move a window
owned by a **different process**, they **silently no-op** — no error, no
movement.

This affects:
- `CGSAddWindowsToSpaces` / `CGSRemoveWindowsFromSpaces`
- `CGSMoveWindowsToManagedSpace` (and its SLS-prefixed twin `SLSMoveWindowsToManagedSpace`)

### Evidence

**1. Symbol presence on this machine (macOS 15.6.1)** — checked via `dlsym`
against `/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight`:

| Symbol                                                    | Present? |
|-----------------------------------------------------------|----------|
| `CGSAddWindowsToSpaces`                                   | yes      |
| `CGSRemoveWindowsFromSpaces`                              | yes      |
| `CGSMoveWindowsToManagedSpace`                            | yes      |
| `SLSMoveWindowsToManagedSpace`                            | yes      |
| `SLSAddWindowsToSpaces`                                   | yes      |
| `SLSRemoveWindowsFromSpaces`                              | yes      |
| `SLSPerformAsynchronousBridgedWindowManagementOperation`  | **no**   |
| `SLSSetWindowListWorkspace`                               | yes      |
| `SLSSpaceSetCompatID`                                     | yes      |

So the weak-import guard (`if (&CGSAddWindowsToSpaces != NULL)`) is **not**
filtering them out — the calls execute, they just do nothing.

**2. yabai's version-gated logic** (`~/yabai/src/workspace.m:17-26`):

```c
bool workspace_use_macos_space_workaround(void) {
    NSOperatingSystemVersion v = [[NSProcessInfo processInfo] operatingSystemVersion];
    if (v.majorVersion == 12 && v.minorVersion >= 7) return true;
    if (v.majorVersion == 13 && v.minorVersion >= 6) return true;
    if (v.majorVersion == 14 && v.minorVersion >= 5) return true;
    return v.majorVersion >= 15;
}
```

On any of these versions, yabai falls back to either
`SLSPerformAsynchronousBridgedWindowManagementOperation` (if present) or
its SIP-disabled scripting-addition path (`~/yabai/src/space_manager.c:686-705`).

**3. AltTab marks the Add/Remove APIs as effectively dead** —
`~/alt-tab-macos/src/macos/api-wrappers/SkyLight.framework.swift:127-135`:

```swift
/// adds the provided windows to the provided spaces
/// * macOS 10.10-12.2
@_silgen_name("CGSAddWindowsToSpaces")
```

The "10.10-12.2" comment is their working version range. They declare the
function but no longer call it from any code path.

**4. Cross-references**:
- yabai #2380 — "Moving Windows Across Spaces No Longer Works in MacOS 15.0"
- yabai #795 — "Move window to space without disabling SIP"
- Amethyst #1174 — "Move to window to space leaves a copy" (the duplicate-on-source bug from `CGSRemoveWindowsFromSpaces` failing to honor the call)

## Options Forward

### Option A — Upgrade to macOS 26 (Tahoe) and rewrite to use the Bridged operation

`SLSPerformAsynchronousBridgedWindowManagementOperation` shipped with macOS 26.
Yabai's first-choice branch (`~/yabai/src/space_manager.c:686-695`) uses it
without any scripting addition and without SIP changes:

```c
if (SLSPerformAsynchronousBridgedWindowManagementOperation) {
    CFArrayRef window_list_ref = cfarray_of_cfnumbers(&window->id, sizeof(uint32_t), 1, kCFNumberSInt32Type);
    Class cls = objc_getClass("SLSBridgedMoveWindowsToManagedSpaceOperation");
    SEL sel = sel_registerName("initWithWindows:spaceID:");
    id operation = ((id (*)(id, SEL, id, uint64_t))objc_msgSend)(
        [cls alloc], sel, (__bridge id)window_list_ref, sid);
    SLSPerformAsynchronousBridgedWindowManagementOperation(operation);
    [operation release];
    CFRelease(window_list_ref);
}
```

Pros:
- Clean private-API path, no event synthesis hacks
- Matches Apple's current direction (the "Bridged" operations are how
  Stage Manager, Mission Control, etc. internally move windows)
- No SIP changes required

Cons:
- Requires users to be on macOS 26 — feature would silently no-op on 15/14/13
  (the app's existing minimum, see `Package.swift:5`: `.macOS(.v13)`)
- Still a private API — could break in 27+
- Need to verify on a real macOS 26 system before committing

What needs to change:
- Replace the `CGSAddWindowsToSpaces`/`CGSRemoveWindowsFromSpaces` calls in
  `Sources/ISS/ISS.c:775-778` with an Obj-C runtime call to
  `SLSBridgedMoveWindowsToManagedSpaceOperation`.
- Weak-import the symbol; if missing, beep + show a "requires macOS 26"
  message (or gracefully disable the hotkey rows in settings UI).
- Decide whether to keep the move-to-space feature visible at all on
  pre-26 systems.

### Option B — Synthetic mouse drag (works everywhere, no SIP, no version gate)

The OS unconditionally honors the user-level recipe of "hold mouse on
title bar + switch space" — the window follows the cursor. Steps:

1. Query the frontmost window's title-bar rect via `AXUIElement`.
2. Post a `CGEvent` left-mouse-down at that rect's center.
3. Invoke the existing instant `iss_switch_to_index(target)`.
4. Post a `CGEvent` left-mouse-up.

Pros:
- Works on macOS 13 through 26+
- No SIP, no private APIs (only Accessibility, which is already required)
- Reuses the existing instant-switch core

Cons:
- More moving parts; need to handle:
  - windows without title bars (fullscreen, some borderless apps)
  - apps that intercept mouse drag in the title bar
  - making sure the synthetic events are tagged so our own event tap
    in `Sources/ISS/ISS.c:130` doesn't get confused
- Brief visual "drag" artifact during the switch

### Option C — Combine A and B

- Use the Bridged operation on macOS 26+ (cleaner)
- Fall back to synthetic drag on 13–15 (broader compatibility)
- Pick at runtime based on `dlsym` for `SLSPerformAsynchronousBridgedWindowManagementOperation`

This is probably the right long-term shape but the most code to write.

## Open Questions (need user decision)

1. Are you willing to drop macOS 13/14/15 support for this feature, or does
   the move-to-space feature need to work everywhere the app runs?
2. If upgrading to macOS 26: do you have a 26 install we can test on
   directly, or do we need to write the code and validate later?
3. For the synthetic-drag fallback: is the brief drag artifact acceptable?

## Decision

**Go with Option B unconditionally.** Synthetic mouse drag is the only
recipe that works on all three macOS tiers (13/14, 15, 26+), uses only
public APIs, and doesn't depend on Apple's churn of private SkyLight
symbols. One implementation, no version sniffing, no untested fallbacks.

The "elegant" macOS 26 Bridged path buys nothing the synthetic drag
doesn't already deliver, and adds a code path we can't test on the
current dev machine (15.6.1). Skip it.

## Open Risk Before Implementing

Unknown: does the WindowServer's "window-follows-cursor-during-space-switch"
behavior trigger on the **synthetic dock-swipe** ISS uses to switch
spaces, or is it gated on the **keyboard space-switch path** (Ctrl+→ /
Ctrl+#)?

- **If it triggers on dock-swipe**: window teleports along with the
  instant switch. Zero visible artifact. Ship it.
- **If it's gated on keyboard**: we'd have to switch the in-move case
  to post a synthetic Ctrl+# keystroke, which uses Apple's regular
  space-slide animation. That undermines ISS's whole reason for
  existing for this one feature — we'd accept the slide only when
  moving a window, not on plain space switches.

The fast way to find out is to write the prototype and try it. No
amount of staring at docs will answer it.

## Prototype Plan

In `Sources/ISS/ISS.c`, replace the CGS Add/Remove call block in
`iss_move_frontmost_window_to_index` (currently lines 775-783) with:

1. Use `AXUIElementCreateSystemWide()` →
   `kAXFocusedApplicationAttribute` → `kAXFocusedWindowAttribute` to
   get the focused window's `AXUIElementRef`.
2. Read `kAXPositionAttribute` and `kAXSizeAttribute` to compute a
   point on the title bar (window-top center, ~14px down from top).
3. Save current cursor position via `CGEventCreate(NULL)` +
   `CGEventGetLocation`.
4. Post a `kCGEventLeftMouseDown` at the title-bar point with
   modifier flags explicitly cleared (the hotkey's modifiers must
   not leak into the synthetic click).
5. Call `iss_switch_to_index(targetIndex)` — the existing instant
   switch.
6. Post a `kCGEventLeftMouseUp` at the same point.
7. Warp the cursor back to the saved position with
   `CGWarpMouseCursorPosition`.

Keep the existing weak-import declarations and AX-window-id lookup;
remove the dead CGSAddWindowsToSpaces / CGSRemoveWindowsFromSpaces
calls.

If after testing it turns out we need a tiny delay between mouse-down
and the swipe (so WindowServer registers the grab), add a
`usleep(5000)` (5ms) between steps 4 and 5 and tune from there.

## Validation Checklist (after implementing)

- [ ] Hotkey moves a TextEdit window from space 1 → space 2 reliably
- [ ] Works for Finder, Safari, Terminal (title-bar apps)
- [ ] Cursor returns to its original position after the move
- [ ] Held hotkey modifiers don't break it (mouse-down flags cleared)
- [ ] No "stuck mouse button" state if the move fails mid-sequence
- [ ] No regression in plain left/right space switching (existing tap
      still passes through our synthetic events from our own pid via
      `Sources/ISS/ISS.c:148-151`)

## Files Touched So Far

- `Sources/ISS/ISS.c` — has uncommitted debug `fprintf`s in
  `iss_move_frontmost_window_to_index` (lines 750-757). Confirmed the
  function IS being reached; the CGS calls themselves are the no-op.
