# Nerdpass

A macOS menu bar app that plays a capture card's sound through the Mac (start/stop, 0 to 200% volume with a boost,
input and output pickers, four looks, Shift + volume keys). Swift package: `Sources/PassCore` (everything testable),
`Sources/App/main.swift` (AppKit + SwiftUI + audio glue), `Tests/PassCoreTests`. See README.md for features.

## Code signing (where the certificate lives)

Every build and release is signed with one self-signed certificate, so macOS keeps users' permissions (audio input,
Accessibility for the volume keys) across updates. Ad hoc signatures change every build, and macOS forgets them.

- **What:** a code signing certificate named **"Nerdative Signing"** (self-signed, RSA 3072, valid until 2036).
  SHA-1 fingerprint `30:F7:FB:90:AC:70:4B:76:F8:36:AB:2E:35:27:F7:3A:CF:DD:F2:82`. Signed apps' designated
  requirement is `identifier "com.nerdative.nerdpass" and certificate root = H"30f7fb90ac704b76f836ab2e3527f73acfddf282"`.
- **Where:** only in **1Password**, vault **Private**, item **"Nerdative Signing"**:
  - field `password`: the .p12 file's password;
  - a file attachment named `p12` in the section `certificate` (the .p12 with the certificate and private key).
  It is **not** kept in any macOS keychain. `Tools/sign.sh` reads it with the 1Password CLI, loads it into a
  temporary keychain with a random password, signs, and deletes that keychain.
- **On another computer:** install the 1Password CLI (`brew install 1password-cli`), turn on the CLI integration in
  the 1Password app (Settings > Developer), and sign in to the account that has the Private vault. Then
  `Tools/sign.sh --check` exits 0, `./build.sh` signs with the certificate, and `./release.sh` works. Nothing else to
  copy.
- **Never** create a new certificate unless this one is truly lost (`Tools/setup_signing.sh` refuses when the item
  exists): a new one makes every user re-grant permissions once. Never commit the .p12, its password or any key.
- `./release.sh` stops if the certificate can't be reached, so a release is never ad hoc signed. `./build.sh` falls
  back to ad hoc when 1Password isn't available (contributors), or uses `SIGN_IDENTITY` if set.

## Releasing

- Releases are local (no CI): `./release.sh [patch|minor|major|X.Y.Z]` bumps `Info.plist`, builds a universal app,
  signs it, commits "Release vX.Y.Z", tags, pushes, creates the GitHub release and updates the Homebrew cask in
  github.com/grumpitect/homebrew-nerdpass. Needs `gh` signed in and the certificate above.
- Before releasing, re-render the README screenshots so they show the new version: temporarily set
  `CFBundleShortVersionString` to the new version, `./build.sh`, then for each look
  `~/Applications/Nerdpass.app/Contents/MacOS/Nerdpass --snapshot docs/look-<look>.png --demo --look <look>`, then
  set the version back (release.sh bumps it in the release commit) and commit the images with the change.
- Commit subjects become the release notes ("Changes"), so write them as user-facing changes. Check the notes after
  releasing.
- After releasing: install with the one-line installer from the README, and run
  `Nerdpass --audio-check 4` (quit the menu bar copy first) to confirm audio flows.

## Conventions

- Owner's privacy: no real device names, IDs or personal paths in the repo (tests and screenshots use made-up
  devices; `--snapshot --demo` renders with made-up inputs).
- No em dashes or en dashes anywhere (code, comments, docs, commit messages).
- Build caches live in `~/Library/Caches/Nerdpass-build` (not `$TMPDIR`).
- App icons: `Resources/Icons/` holds the candidates; `python3 Tools/set_icon.py <name>` makes one the app icon.
