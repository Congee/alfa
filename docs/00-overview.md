# 00 — Overview

## What Alfa is

A native Swift iOS app that controls a Sony Alpha camera over **Bluetooth Low Energy only** (no Wi-Fi), combining the
capabilities of two existing closed-source apps:

- **Geotag Alpha** — pushes GPS location + time to the camera so photos/videos are geotagged.
- **Alpha Remote Controller** ("Remote Alpha") — a BLE remote: shutter, half-press/AF, zoom, record, custom buttons.

Alfa's headline differentiator is being **battery-efficient**: it must not cause the constant connect/disconnect
cycling that drains the camera battery in standby.

## Primary goals (in priority order)

1. **Fix the standby battery drain.** Be a "good BLE citizen" (see `05-battery-strategy.md`). This is the reason the
   project exists.
2. **Reliable background geotagging** with GPS + time sync (Phase 1).
3. **Remote camera control** — shutter, AF, zoom, record, bulb/interval (later phases).
4. **Excellent code quality** — strict Swift 6 concurrency, high test coverage on pure logic, minimal dependencies.

## Target hardware

- Reference device: **Sony A7R V (ILCE-7RM5), firmware 4.0.** All protocol claims must ultimately be validated against
  this body.
- Architect the protocol layer to be **model-agnostic** (advertisement parsing, capability probing) so other current-gen
  Alpha bodies work, but only claim support for what has been tested.

## Non-goals (for now)

- **Wi-Fi / PTP-IP control** (Sony Camera Remote SDK territory, and where "Access Authentication" actually applies).
- **Reverse-engineering the camera firmware.** Not needed — the BLE protocol is already documented and Access
  Authentication does not touch BLE. Firmware RE is an *optional* research side-track only (see `03-ble-protocol.md`).
- **Live view / image transfer** — not available over BLE.
- **Android / cross-platform.** iOS-native, by choice, for the strictest possible CoreBluetooth behavior.
- **Multi-brand (Canon/Nikon/Fuji).** Possible future via a driver abstraction, but out of scope now.

## Confirmed platform decisions

See `01-requirements.md`. In short: Phase 1 = geotag core; distribution = free-account personal sideload; target =
iPhone only for now; battery policy = "Balanced" (stay connected while the camera is on, fully back off in standby).

## The one thing to never forget

Sony **"Access Authen." is a Wi-Fi/SSH feature and has nothing to do with Bluetooth.** BLE is secured only by standard
pairing/bonding. Do not spend effort trying to defeat camera encryption for a BLE app — there is none on the BLE path.
