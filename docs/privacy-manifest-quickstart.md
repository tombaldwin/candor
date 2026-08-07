# Check your Swift app's privacy manifest in one command

Apple rejects builds whose usage-description keys don't cover the sensors the code actually reaches.
The reach is **transitive** — a helper three calls down touches the camera and the key is required —
which is why it's easy to miss and why a grep won't find it.

`candor-swift` reads your source, works out which sensors the code can actually reach, and tells you
which keys Apple will require. No project changes, no build, no account.

## 1. Install (macOS, Apple silicon)

```sh
curl -fsSL -o candor-swift \
  https://github.com/tombaldwin/candor-swift/releases/download/v0.27.0/candor-swift-macos-arm64
chmod +x candor-swift
```

## 2. Ask what your app needs

```sh
./candor-swift .                  # scan (a few seconds — 424 files in ~6s)
./candor-swift privacy-manifest   # the keys your code's sensor reach requires
```

```
candor privacy-manifest — usage-description keys required by the code's sensor reach:
  Camera → NSCameraUsageDescription (reached by: StatusEditor.CameraPickerView.makeUIViewController)
  Photos → NSPhotoLibraryUsageDescription (reached by: PhotoAssetThumbnailView.body, …)
  Notify → (no Info.plist key — notifications gate at runtime via requestAuthorization)
```

## 3. Check it against what you ship

```sh
./candor-swift privacy-manifest --verify YourApp/Info.plist
```

- **exit 0** — every sensor the code reaches is declared.
- **exit 1** — something is **under-declared**. It names the missing key *and* the function that
  reaches it, so you can act on it immediately.

It also reads `INFOPLIST_KEY_*` build settings from your `.xcodeproj` and `.xcconfig` files, because
since Xcode 13 that's where usage descriptions live by default and the `Info.plist` in your source tree
often has none of them.

## 4. If it finds something, ask why

```sh
./candor-swift path JetpackPrologueViewController.init Motion
```

prints the call chain from your function down to the sensor, ending at the exact file and line:

```
  AbstractPostListViewController.automaticallySyncIfAppropriate
    → … → LoginPrologueViewController.init()
      → JetpackPrologueViewController.init   [Motion source @ …/JetpackPrologueViewController.swift:9:17]
```

Then decide: declare the key, or remove the reach.

## Multi-target projects — pick the right plist, or the answer is about the wrong binary

A privacy manifest is per **shipped binary**, and a real iOS repo has several: the app, a share
extension, a widget, a notification service. Each has its own `Info.plist`, and they are not
interchangeable — a share extension does not need the app's camera key.

So don't let a `find` pick one for you. A big repo will hand you the first plist in directory order,
which is very often an extension's, and you'll get a page of "missing key" findings that are really
"you asked about the wrong target". Name both halves explicitly:

```sh
./candor-swift . --target MyAppTarget                    # the code THIS product compiles
./candor-swift privacy-manifest --verify MyApp/Info.plist # the plist THAT product ships
```

`--target` resolves against a `Package.swift` **and** an `.xcodeproj`, so it works on either repo shape.
For an Xcode target it reads the project file directly (no build, no `xcodebuild`), follows the target's
dependency closure, and pulls in the **local** Swift packages the target uses — the `Packages/`-shaped
layout where the app target is a thin shell over its own packages, and scoping to the shell alone would
answer about almost nothing. Remote packages stay outside the scope and are disclosed as uncovered
rather than read as pure.

If it can't resolve the name soundly it **refuses** (exit 2) and lists the real target names, because a
scope quietly resolved short is a purity claim over every file it dropped.

To find the app's own plist, look for the one whose directory matches the app target — it's the plist
with `CFBundleDisplayName` and no `NSExtension` key:

```sh
grep -rl CFBundleDisplayName --include=Info.plist . | xargs grep -L NSExtension
```

(`xargs`, not `$(…)`: with no matches the substitution form leaves `grep` reading stdin and it hangs.)

If the two halves don't match, the verify is comparing one target's code against another's manifest,
and every finding it prints is noise.

**Without `--target` the scan is whole-repo**, so in a repo that ships several products from one Xcode
project — a Mac and an iOS app, or an app plus widgets — a sensor reached only by the *other* product is
attributed to the plist you named. That is what the flag is for; name it.

## What it will and won't tell you

It is deliberately explicit about its own limits, and prints them on every verify:

- **56 of Apple's 57 documented usage-description keys are modelled.** It says nothing in either
  direction about the last one (`NSFileProviderPresenceUsageDescription` — Apple documents no symbol
  for it, so there is nothing in code to see). A clean result here is not a clean App Store review.
- **File-path keys depend on the path.** If a file operation's path can't be determined statically, it
  says so and counts them, rather than guessing — those are where a Desktop/Downloads/removable-volume
  requirement could hide.
- **Imports it can't attribute are named, not ignored.** "Uncovered modules" means their sensor usage
  is invisible to the scan — absence from the report is never a claim of purity.

---

### Tested on

Run verbatim against shipping open-source apps. The first three are the ones the verb was developed
against; the rest were added afterwards, deliberately, because a tool tested only on the apps it was
debugged against tells you nothing about the next one.

| app | result |
|---|---|
| [IceCubesApp](https://github.com/Dimillian/IceCubesApp) | clean — Camera + Photos reach, all declared (via build settings) |
| [duckduckgo/iOS](https://github.com/duckduckgo/iOS) | clean — Camera, Mic, Speech, all declared |
| [WordPress-iOS](https://github.com/wordpress-mobile/WordPress-iOS) | clean — Camera, Mic, all declared |
| [Bitwarden/ios](https://github.com/bitwarden/ios) | clean — Camera (QR scanner), declared |
| [firefox-ios](https://github.com/mozilla-mobile/firefox-ios) | clean — Camera, Mic, Photos, Speech, all declared |
| [Kingfisher](https://github.com/onevcat/Kingfisher) | clean |

**Every app in that second group produced a WRONG finding first.** Each one was a defect in candor, not
in the app, and each is now fixed: the system contacts and photo pickers were charged usage keys Apple
does not require for them (they run out of process — the app never gains access); `GKLocalPlayer`
authentication was charged the friend-list key; `CLGeocoder` was charged Location though it only converts
coordinates you supply; a labelled `mediaType:` argument went unread, so a camera-only QR scanner was
charged Mic; test code sitting beside its sources was cited as evidence a shipping manifest was wrong;
and a key declared through a same-file build variable read as missing.

The pattern is worth stating because it will recur: **every one was an over-report**, and over-reports
are found only by running the tool on code you did not write and then checking whether the app is
actually wrong. If you get a finding you believe is incorrect, it may well be — please report it.

An earlier draft of this page reported an undeclared `NSMotionUsageDescription` in WordPress-iOS. **That
was candor's error, not the app's**, and it is worth saying how it was caught. candor mapped every
CoreMotion class to the key; Apple's own page for `NSMotionUsageDescription` names exactly four APIs
(`CMSensorRecorder`, `CMPedometer`, `CMMotionActivityManager`, `CMMovementDisorderManager`), and
`CMMotionManager` — raw accelerometer and gyroscope streams, which is what WordPress uses — requires no
key at all. The classifier now splits the two, and reading Apple's list also turned up an API candor had
mapped nowhere, which was a real gap in the other direction.
