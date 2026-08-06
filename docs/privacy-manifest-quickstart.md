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

## Multi-target projects

A privacy manifest is per **shipped binary**. If your package builds more than one product, scope the
scan so you're asking about the code that product actually compiles — otherwise you're verifying one
app's plist against another target's sensors:

```sh
./candor-swift . --target MyAppTarget
./candor-swift privacy-manifest --verify MyApp/Info.plist
```

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

Run verbatim against three shipping open-source apps:

| app | result |
|---|---|
| [IceCubesApp](https://github.com/Dimillian/IceCubesApp) | clean — Camera + Photos reach, all declared (via build settings) |
| [duckduckgo/iOS](https://github.com/duckduckgo/iOS) | clean — 5 effects, all declared |
| [WordPress-iOS](https://github.com/wordpress-mobile/WordPress-iOS) | **found an undeclared `NSMotionUsageDescription`** |

The WordPress finding is real: `JetpackPrologueViewController` calls
`motion.startDeviceMotionUpdates()`, and `NSMotionUsageDescription` appears nowhere in the repository.
