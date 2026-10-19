# Face ID for Boring Notch

This fork adds camera-based face unlock to [Boring Notch](https://github.com/TheBoredTeam/boring.notch). It is built on [**FaceMac**](https://github.com/c1osed1/FaceMac) by [**c1osed1**](https://github.com/c1osed1). Everything else in Boring Notch works as before: music, calendar, shelf, mirror and HUDs.

**What it does**
- **Lock screen:** press any key or touch the trackpad, look at the notch, and the Mac unlocks. The notch grows into a Face ID panel, shows the scan, then greets you by name.
- **`sudo` in Terminal:** answered by your face, then Touch ID, then your password.
- **macOS password prompts** ("… wants to make changes", System Settings unlocks, installers, Keychain prompts, and Touch ID sheets that offer "Use Password…"):
  - Filled in after a face match.
  - Only the real macOS dialogs are filled, and only when they ask for your own account.
  - If you're away when a prompt appears, it keeps looking for up to 5 minutes.
- **Controls:** a green Face ID button sits next to the camera and gear in the notch, and **Settings → Face ID** has the finer options.

Everything runs on the Mac. Camera frames are never saved, and nothing is sent anywhere.

## Install (from a release)

1. Download `BoringNotch-FaceID-<version>.zip` from [Releases](../../releases) and unzip it.
2. In Terminal, in the unzipped folder, run `./install.sh`.
   - It backs up an official Boring Notch first and carries your settings over.
   - It replaces `/Applications/boringNotch.app`.
3. Open the notch and click the **Face ID** button:
   - **Password:** save your Mac login password. It goes into your Keychain.
   - **Re-enroll:** enroll your face (five head poses).
   - Allow **Camera** and **Accessibility** when macOS asks.
4. *(Optional, for `sudo`)* Give Terminal **Full Disk Access**, then run `sudo ./sudo/install.sh`.
   - macOS 26 only lets apps with Full Disk Access edit `/etc/pam.d`.
   - The installer checks itself and restores your `sudo` setup automatically if anything fails.
   - To undo it: `sudo ./sudo/install.sh --uninstall`.

The release is signed with a personal certificate, not notarized. `install.sh` clears the download quarantine for you.

## Build from source

Requires Xcode 16 or later and a codesigning identity. A self-signed "Code Signing" certificate made in Keychain Access is enough.

```sh
git clone https://github.com/rhan1/boring.notch.git && cd boring.notch
git checkout faceid
faceid/scripts/fetch-model.sh                      # downloads the face model
# Set CODE_SIGN_IDENTITY in the Xcode project to your identity, then:
xcodebuild -project boringNotch.xcodeproj -scheme boringNotch -configuration Release \
  -derivedDataPath .build/dd -destination 'platform=macOS' build
faceid/scripts/install.sh
# sudo support, signed with the same identity as the app:
(cd faceid/pam && FACEMAC_SIGN_IDENTITY="<your identity>" ./build.sh && clang -O2 -o pamcheck pamcheck.c -lpam)
sudo faceid/pam/install.sh
```

The code is in `boringNotch/FaceID/`:
- `Core/`: FaceMac's recognition engine: Vision face detection, SFace embeddings, matching, liveness, the lock watcher, key typing and Keychain storage.
- `UI/`: the notch panel, the Face ID page, the settings section, and the enroll and test windows.

The `sudo` module is in `faceid/pam/`.

## How it differs from the official app

- **Not sandboxed**, so it can read your face data, type at the lock screen and answer the `sudo` socket.
- **Updates are off**, so an official update can't replace it. Official releases are merged into this fork instead.
- **Your saved password** sits in your login Keychain and is read through Apple's `security` tool. That means rebuilds don't prompt again. The tradeoff: any app running as you can read it without a prompt.

## Security notes

- This uses the regular FaceTime camera, not a depth sensor like the iPhone's Face ID.
  - The blink and motion check stops still photos.
  - A determined attacker with a good video could still fool it.
  - Don't use it where that matters.
- `sudo` and password prompts are approved whenever your face is in front of the camera, without a touch. That includes `sudo` run by a script.
- Remote (SSH) sessions are ignored.
- Face unlock can't replace: Apple Pay, the FileVault login after a restart, or apps that accept only a fingerprint.

## Credits

- **[FaceMac](https://github.com/c1osed1/FaceMac)** by [c1osed1](https://github.com/c1osed1) (GPL-3.0). The face-recognition engine, enrollment, liveness check, lock-screen unlock and Face ID glyph all come from FaceMac. This fork adds the notch integration, touch to scan, `sudo` and password-prompt support.
- **[Boring Notch](https://github.com/TheBoredTeam/boring.notch)** by TheBoredTeam (GPL-3.0).
- **SFace** face-recognition model, from the [OpenCV Zoo](https://github.com/opencv/opencv_zoo) (Apache-2.0).
- "Face ID" is a trademark of Apple Inc. This project is not affiliated with Apple.

## License

GPL-3.0, the same as Boring Notch and FaceMac. See [LICENSE](../LICENSE).
