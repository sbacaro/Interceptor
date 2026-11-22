# Interceptor

A native macOS audio stream tap and discrete mono channel router written entirely in **Swift 6** and **SwiftUI** following the **Apple Human Interface Guidelines**.

## Problem Solved

DAWs such as Pro Tools rely on a single Playback Engine and strict hardware clock ownership, making it difficult to monitor through a separate physical audio interface without creating system-wide aggregate devices or virtual routing drivers that introduce clock instability.

**Interceptor** passively taps any Core Audio output stream (`AudioHardwareCreateProcessTap` + `CATapDescription`) directly inside `coreaudiod` — **unmuted (`CATapUnmuted`), non-exclusive, and without touching the source interface's clock or Playback Engine** — and routes discrete mono channels to any monitoring audio interface using a private Core Audio Aggregate Device with native maximum-quality `AudioSubTap` drift compensation.

## Key Features

- **100% Interface-Agnostic**: Works with any Core Audio output interface (USB, Thunderbolt, PCIe, Network/Dante/AVB, Virtual Bridges, Built-in) across single-stream and multi-stream devices up to 64+ channels.
- **Virtual Devices Organization**: Organize independent passive routing bridges (e.g., *Main Monitor*, *Headphones*) and run multiple bridges simultaneously with automatic persistence.
- **Discrete Mono Channel Patching**: Route any source output channel (`Ch 1…N`) to any monitor output channel (`Out 1…M`) at bit-transparent unity gain with live lock-free edits and per-channel studio dBFS VU meters.
- **Zero-Allocation Real-Time Audio Engine**: `@convention(c)` `AudioDeviceIOProc` trampoline backed by a wait-free SPSC triple buffer (`Synchronization.Atomic`) and lock-free atomic metering.
- **Optional Process Scope**: Tap all processes on the source device stream (always excluding Interceptor itself to prevent feedback) or scope to a specific commercial application with automatic bundle-ID restoration.
- **Native macOS Integration**: Native Xcode project, String Catalogs (`.xcstrings`), Display P3 Asset Catalog (`AppIcon`, `AccentColor`), Privacy Manifest (`PrivacyInfo.xcprivacy`), Menu Bar companion, automatic hot-plug reconnection, and sample-rate change recovery.

## Requirements

- **macOS 26.0** or later (Apple Silicon & Intel Universal)
- **Xcode 27.2** / Swift 6.4 (to build from source)
- **System Audio Recording** permission (*System Settings → Privacy & Security → System Audio Recording Only*)

## Building & Testing

Open `Interceptor.xcodeproj` in Xcode, select the **Interceptor** scheme, and press `⌘R` to run or `⌘U` to run the Swift Testing suite.

From the command line:

```bash
# Run unit tests
xcodebuild -project Interceptor.xcodeproj -scheme Interceptor -configuration Debug -destination 'platform=macOS' test

# Build Release app
xcodebuild -project Interceptor.xcodeproj -scheme Interceptor -configuration Release -destination 'platform=macOS' build
```
