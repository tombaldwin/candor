# Case study: the Info.plist keys your code actually needs

**App:** Pollen — a real, shipping Swift app with a macOS build and an iOS build sharing a core module.
**Tool:** `candor privacy-manifest`, run over the source. No configuration, no annotations, no source
changes. **Swift only today** — this is a candor-swift extension (`privacy/1`), not a floor feature.

An iOS app that touches a sensor without the matching `Info.plist` usage-description key doesn't warn you.
It gets rejected, or it crashes on the device of whoever hits that code path first. The key must be there
because the *binary* can reach the API — not because a screen you remember writing calls it.

That distinction is the whole case study, and it's why the interesting result here is a **methodology**
result rather than a bug count.

```
candor scan .                                          # scan the target's sources
candor privacy-manifest                                # generate: the keys the code requires
candor privacy-manifest --verify path/to/Info.plist    # verify: exit 1 on an under-declaration
```

---

## 1. Run it per shipped binary, not per repository

The first run scanned the whole repo as one unit and verified against the macOS app's plist:

```
✗ code reaches Mic (via iOSBlowMonitor.actuallyStart, iOSBlowMonitor.init()#17,
  iOSBlowMonitor.observeAppLifecycle) but Info.plist declares no NSMicrophoneUsageDescription
                                                                                       exit 1
```

That finding is **wrong**, and it's wrong in a way worth showing. `iOSBlowMonitor` lives in
`Sources/PolleniOS` — a target the macOS app does not compile. Scanning every target as one unit charges
each plist with every *other* target's sensors. Run it the correct way, once per shipped binary:

| scan scope | verified against | result |
|---|---|---|
| whole repo | `Resources/Info.plist` (macOS) | **exit 1** — ✗ Mic · *artifact* |
| macOS target only (`Pollen` ← `PollenApp` ← `PollenCore`) | `Resources/Info.plist` | **exit 0** — ✓ clean, 3 effects |
| iOS target only (`PolleniOS` ← `PollenCore`) | `Apps/PolleniOS/Info.plist` | **exit 1** — ✗ Contacts |

The macOS app is clean. The iOS app is not — and *that* finding survives the correct methodology:

```
✗ code reaches Contacts (via ContactsService.isAuthorized, ContactsService.resolve)
  but Info.plist declares no NSContactsUsageDescription                                exit 1
```

If you take one thing from this page: **scope the scan to what actually ships.** A monorepo scanned whole
will hand you findings for binaries that were never built.

## 2. What grepping the target cannot tell you

Grep `Sources/PolleniOS` for `Contacts`, `CNContactStore`, or `ContactsService`. You get nothing. Every
caller is in `Sources/PollenApp` — the macOS app.

The Contacts API reaches the iOS binary anyway: `ContactsService` lives in `Sources/PollenCore`, and
`PolleniOS` depends on `PollenCore`, so `Contacts.swift` compiles into the iOS module. The reach is
*through a shared dependency*, which is exactly the shape that searching a target's own sources cannot
see and a reviewer reading that target's diffs will never notice.

This is also the honest limit of the finding, and candor's own output is what draws the line — see §3.

## 3. Linked, or called? The reached-by list already says

The two runs report Contacts differently:

```
iOS    Contacts → NSContactsUsageDescription (reached by: ContactsService.isAuthorized,
                                                          ContactsService.resolve)
macOS  Contacts → NSContactsUsageDescription (reached by: ContactsService.isAuthorized,
                                              ContactsService.resolve, SettingsView.body, …)
```

On macOS the list contains a **call site** — `SettingsView.body`. On iOS it contains only the API's own
two wrappers and nothing else: the module is linked, and no iOS code path calls it.

So the exposure differs in kind. On iOS this is a **binary-level** risk — the API is in the shipped
binary, which is the level Apple's tooling inspects — not a runtime crash waiting for a user. The fix is
correspondingly a choice rather than an emergency: declare the key, or keep `Contacts.swift` out of the
module the iOS target compiles.

No second command was needed to establish that. The distinction was in the first answer.

## 4. Three outcomes, not two

```
under-declaration   ✗ code reaches Contacts … but Info.plist declares no NS…     exit 1
over-declaration    ⚠ NSMicrophoneUsageDescription declared but no Mic reach found
                    ✓ every accessed capability is declared (1 effect)            exit 0
unreadable plist    refusing to report a verify result over an unreadable manifest exit 2
```

The asymmetry is deliberate. An **under**-declaration is a rejection, so it fails. An **over**-declaration
is a permission prompt your users see and don't understand — worth telling you about, not worth failing a
build over. Both are reported in the same run when both are present.

The third outcome matters more than it looks: a corrupt plist **refuses** rather than reporting a clean
verify over a file it could not read. An empty answer that looks like a pass is the one failure mode a tool
like this must not have.

One detail that shows the mapping came from how Apple actually works: `Notify` is reported as a reached
capability with **no key required** — notifications gate at runtime through `requestAuthorization`, not
through `Info.plist`. A table built by pattern-matching key names would have invented one.

## 5. What it does not know, and says so

Every verify above ended with candor's own hedge:

```
⚠ verdict is conditional on 15 uncovered modules — sensor usage there is invisible to this
  verify (chain dep reports or scan the workspace root to close the gap)
```

That line is the point of the tool, not a disclaimer on it. A clean verify that stayed silent about the
15 modules it could not see would be a *worse* answer than a noisy one.

Two further limits, stated plainly because a green exit code should not be read as more than it is:

- **The cluster is six sensors** — `Location`, `Camera`, `Mic`, `Contacts`, `Photos`, `Notify`. Pollen's
  plists also declare `NSMotionUsageDescription` and the two HealthKit keys, and candor says **nothing**
  about those in either direction: it neither requires them nor flags them as unused, because it does not
  model those sensors. `exit 0` means *"the six I model are declared"*, never *"your plist is right"*.
- **This is Swift-only.** The privacy manifest is a candor-swift extension. The four-engine floor says
  nothing about it, and no other engine implements it.

---

## Reproduce

```
# one tree per shipped binary — a Package.swift naming just that target's dependency chain
candor scan .
candor privacy-manifest                                # what the code requires
candor privacy-manifest --verify ../Resources/Info.plist   # what the app declares
echo $?                                                # 0 clean · 1 under-declared · 2 unreadable
```

Wire the last two lines into CI per target and an under-declaration fails the build before the submission
does — which is the same command, run earlier.
