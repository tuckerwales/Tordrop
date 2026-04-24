<p align="center">
  <img src="Resources/AppIcon.png" width="160" alt="TorDrop icon">
</p>

<h1 align="center">TorDrop</h1>

<p align="center">
  <i>Share files over the Tor network — from your macOS menu bar.</i>
</p>

<p align="center">
  Pick files, get a <code>.onion</code> URL, hand it off. No accounts, no third-party servers,
  no persistent onion keys. Built as a small native SwiftUI app with <code>tor</code> as its only
  external dependency.
</p>

---

## How it works

```
File → local HTTP server (127.0.0.1:random) → tor → v3 onion service → Recipient
```

1. You pick one or more files — drag them onto the menu bar icon, or click it and use the file picker.
2. TorDrop starts a minimal HTTP server on a random loopback port, listing the files under a random URL slug.
3. TorDrop spawns `tor`, connects to its control port, and creates an ephemeral v3 hidden service (`ADD_ONION NEW:ED25519-V3 Flags=DiscardPK`) that forwards onion port 80 to the local HTTP port.
4. You copy the `.onion` URL (or scan the in-app QR code with a phone) and send it to the recipient over any secure channel.
5. The recipient opens it in Tor Browser and downloads.
6. You click **Stop Sharing** and the onion service vanishes — the private key was never written to disk.

## Requirements

- macOS 13 (Ventura) or later
- Xcode command-line tools (for `swift build`)
- The `tor` daemon:
  ```sh
  brew install tor
  ```
  TorDrop looks in `/opt/homebrew/bin/tor`, `/usr/local/bin/tor`, `/opt/local/bin/tor`, and falls back to `which tor`.

## Build & run

```sh
make app        # produces TorDrop.app
make run        # builds and launches it
```

Or during development:

```sh
swift run -c release
```

The first launch might prompt for network permissions (the local listener and the outbound connection `tor` makes). Because the app isn't code-signed by default, you may need to right-click → Open the first time.

## Project layout

```
Sources/TorDrop/
├── main.swift                # Entry point (accessory activation policy)
├── AppDelegate.swift         # App lifecycle
├── MenuBarController.swift   # NSStatusItem + NSPopover plumbing + icon
├── PopoverView.swift         # SwiftUI popover
├── QRCode.swift              # CoreImage QR code generator + view
├── ShareState.swift          # Observable state shared with the UI
├── ShareManager.swift        # Orchestrates FileServer + TorController
├── FileServer.swift          # HTTP/1.1 server on Network.framework
└── TorController.swift       # Tor subprocess + control protocol client
Resources/AppIcon.png         # Source artwork — Makefile bakes AppIcon.icns
```

## Security notes

- **Ephemeral onion keys.** `Flags=DiscardPK` tells tor not to hand us the private key; the service identity dies with the process.
- **Random URL slug.** Files live under a `/<20 chars>/...` path so the raw onion address alone isn't a direct handle on them. Defense in depth, not a secret.
- **Loopback-only HTTP.** The embedded server binds to `127.0.0.1`, so it is never reachable outside of tor.
- **Scope.** TorDrop does not add anything beyond what Tor itself provides for recipient anonymity or integrity. For sensitive content, confirm the URL reached the intended recipient through a trusted channel.
