# Image Viewer (iOS 27)

A small iOS app that lets you pick an image from your photo gallery and
displays it. Built for a future **CoreBluetooth (BLE)** feature — the
`NSBluetoothAlwaysUsageDescription` permission entry and a ready-made
`BluetoothManager` (App/BluetoothManager.swift) are already in place.

## Why this setup

- **No Mac available** → the app is compiled by GitHub Actions on a free
  macOS runner (public repos: unlimited free minutes).
- **No paid cloud service** → the IPA is signed with your **free Apple
  Account** and sideloaded directly to the iPhone. No store, no server.
- **Consequence:** Apple's free-account limit means the app must be
  re-sideloaded **every 7 days**, and you can only have **3 sideloaded
  apps** installed at once.

## Prerequisites (one time)

1. An Apple ID (any regular email is fine — no fee).
2. Your iPhone, unlocked.
3. On your PC: [Sideloadly](https://sideloadly.io/) (free)
   — or AltStore if you prefer.

## Building the app

1. Push this repository to GitHub (public, to keep CI free forever).
2. Wait for the **"Build unsigned IPA"** workflow to finish (≈10 min).
3. Download `test_app-unsigned.ipa` from the run's **Artifacts** tab.

## Installing on the iPhone (renew every 7 days)

Using **Sideloadly** (AltStore is similar):

1. Connect the iPhone via USB and launch Sideloadly.
2. Drag the IPA into Sideloadly.
3. Enter your Apple ID + password, check *Install*, let it finish.
4. First launch: **Settings → General → VPN & Device Management**,
   tap your Apple ID under *Developer App* → **Trust**.

The app survives a reboot until the 7 days expire, then you have to
trust the profile again.

## Updating the app later

Edit the Swift code in `App/`, push → the workflow rebuilds →
download the new IPA → repeat sideloading. (If you bump the version
number in `project.yml`/`Info.plist`, Sideloadly replaces the old app
instead of adding a second one.)

## Project layout

```
App/
  ImageGalleryApp.swift   app entry point
  ContentView.swift       gallery picker + image display
  BluetoothManager.swift  CoreBluetooth wiring for future BLE use
  Info.plist              app metadata + Bluetooth permission
project.yml               Xcode project spec (generated via xcodegen)
.github/workflows/build.yml  free CI: builds the unsigned IPA
```

## Adding BLE later

`BluetoothManager` is already a CoreBluetooth `CBCentralManager` wrapper
with permission configured. Add UI that uses it (scan, connect to a
peripheral, read/write characteristics) — no project changes needed.
