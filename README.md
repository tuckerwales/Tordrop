<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="TorDrop icon">
</p>

<h1 align="center">TorDrop</h1>

<p align="center">
  <i>Share files over the Tor network — from a small native macOS app.</i>
</p>

<p align="center">
  Pick files, get a <code>.onion</code> URL, hand it off. No accounts, no third-party servers,
  no persistent onion keys. Built as a small native SwiftUI app with <code>tor</code> as its only
  external dependency.
</p>

<p align="center">
  <img src="Resources/Screenshots/idle.png" width="390" alt="TorDrop idle window">
  <img src="Resources/Screenshots/sharing.png" width="390" alt="TorDrop active share window">
</p>

---

## How it works

```
File → local HTTP server (127.0.0.1:random) → tor → v3 onion service → Recipient
```

1. You pick one or more files or folders: drag them into the TorDrop window or onto its Dock icon, or use the file picker (`Cmd-O`). Folders are compressed into `.zip` archives first.
2. TorDrop starts a minimal HTTP server on a random loopback port, listing the files under a random URL slug.
3. TorDrop spawns `tor`, connects to its control port, and creates an ephemeral v3 hidden service (`ADD_ONION NEW:ED25519-V3 Flags=DiscardPK`) that forwards onion port 80 to the local HTTP port. It shows Tor's bootstrap progress and waits until the service descriptor is published, so the address works as soon as it appears.
4. You copy the `.onion` URL (or scan the in-app QR code with a phone) and send it to the recipient over any secure channel.
5. The recipient opens it in Tor Browser and downloads. Interrupted downloads can resume (HTTP range requests), and TorDrop shows which files are being sent and how many times each has been downloaded.
6. You click **Stop Sharing** (`Cmd-.`) and the onion service vanishes. The private key was never written to disk.

While a share is live you can add more files (the address stays the same) or remove individual files.

While a share is starting or live, TorDrop also shows a temporary menu bar status icon (dashed while connecting, solid when live). Clicking it brings the main window forward, dropping files on it adds them to the share, and right-clicking it offers **Copy Address** and **Stop Sharing**. Closing the window keeps a live share running; quitting asks for confirmation first. When TorDrop is idle, the menu bar icon is hidden.

## Requirements

- macOS 13 (Ventura) or later
- Xcode command-line tools (for `swift build`)
- The `tor` daemon:
  ```sh
  brew install tor
  ```
  TorDrop looks in `/opt/homebrew/bin/tor`, `/usr/local/bin/tor`, `/opt/local/bin/tor`, `/usr/bin/tor`, then inside Tor Browser (`/Applications/Tor Browser.app` or `~/Applications/Tor Browser.app`), and finally falls back to `which tor`. TorDrop runs its own private tor instance with an empty configuration, so an existing `torrc` is never used.

## Build & run

```sh
make app        # produces TorDrop.app
make run        # builds and launches it
```

Or during development:

```sh
swift run -c release
make test       # unit tests for the HTTP and tor control protocol parsers
```

The first launch might prompt for network permissions (the local listener and the outbound connection `tor` makes). Local development builds are ad-hoc signed, so you may need to right-click → Open the first time.

TorDrop is a regular macOS app: it appears in the Dock, has a standard app menu, and supports `Cmd-Q` to quit.

## Release signing

`make app` always signs and verifies the app bundle. By default it uses an ad-hoc signature, which does not identify the developer but does produce a sealed app bundle. Downloaded ad-hoc releases should trigger a Gatekeeper warning such as "unidentified developer" rather than "damaged".

Users can open ad-hoc releases with right-click → Open. If macOS still reports that a downloaded ad-hoc build is damaged, remove the download quarantine attribute:

```sh
xattr -dr com.apple.quarantine /Applications/TorDrop.app
```

Developer ID signing and notarization are optional. They remove the Gatekeeper warning for public releases, but require a paid Apple Developer account.

The GitHub release workflow will use Developer ID signing and notarization when these repository secrets are configured:

- `APPLE_CERTIFICATE_P12_BASE64`: base64-encoded Developer ID Application `.p12`
- `APPLE_CERTIFICATE_PASSWORD`: password for the `.p12`
- `APPLE_DEVELOPER_ID_APPLICATION`: signing identity, for example `Developer ID Application: Example, Inc. (TEAMID1234)`
- `KEYCHAIN_PASSWORD`: temporary CI keychain password
- `APPLE_NOTARY_KEY`: App Store Connect API private key contents
- `APPLE_NOTARY_KEY_ID`: App Store Connect API key ID
- `APPLE_NOTARY_ISSUER_ID`: App Store Connect issuer ID

## Project layout

```
Sources/TorDrop/
├── main.swift                # Entry point (regular app activation policy)
├── AppDelegate.swift         # App lifecycle
├── MainWindowController.swift # Main app window
├── MenuBarController.swift   # Active-share NSStatusItem + icon
├── MenuBarDropView.swift     # File-drop overlay for the active-share menu bar icon
├── MainView.swift            # SwiftUI app surface
├── QRCode.swift              # CoreImage QR code generator + view
├── ShareState.swift          # Observable state shared with the UI
├── ShareManager.swift        # Orchestrates FilePreparer + FileServer + TorController
├── FilePreparer.swift        # Resolves dropped items, zips folders
├── FileServer.swift          # HTTP/1.1 server on Network.framework (Range support)
├── HTTPSupport.swift         # Request parsing, byte ranges, escaping helpers
├── TorController.swift       # Tor subprocess + control protocol client
└── TorControlProtocol.swift  # Tor control reply parser
Tests/TorDropTests/           # XCTest unit tests (`swift test`)
Resources/AppIcon.png         # 1024x1024 source artwork for README + app icon
Scripts/normalize_icon_pngs.swift # Strips PNG metadata before iconutil builds AppIcon.icns
```

## Security notes

- **Ephemeral onion keys.** `Flags=DiscardPK` tells tor not to hand us the private key; the service identity dies with the process.
- **Random URL slug.** Files live under a `/<20 chars>/...` path so the raw onion address alone isn't a direct handle on them. Defense in depth, not a secret.
- **Loopback-only HTTP.** The embedded server binds to `127.0.0.1`, so it is never reachable outside of tor.
- **Tor lifetime.** TorDrop takes ownership of its tor process (`TAKEOWNERSHIP` + `__OwningControllerProcess`), so tor exits with TorDrop even if the app crashes. Tor's data directory is private to the share and deleted on stop.
- **Hardened responses.** Pages and downloads are served with `Cache-Control: no-store`, `Referrer-Policy: no-referrer`, a restrictive `Content-Security-Policy`, and `X-Content-Type-Options: nosniff`.
- **Sleep.** While a share is starting or live, TorDrop keeps the Mac from idle-sleeping so the address stays reachable.
- **Scope.** TorDrop does not add anything beyond what Tor itself provides for recipient anonymity or integrity. For sensitive content, confirm the URL reached the intended recipient through a trusted channel.

## License

TorDrop is released under the [MIT License](LICENSE).
