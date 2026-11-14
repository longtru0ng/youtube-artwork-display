# ESP32-S3 + YouTube Music artwork — Windows setup (experimental)

You **do not need to own a Mac**. Your Windows PC edits/uploads code; GitHub Actions builds the iOS app on a hosted macOS runner; a Windows sideloading tool signs and installs it to your personal iPhone. This is a prototype; the end-to-end BLE app has not been verified on a physical iPhone.

## What's included

- `esp32_s3_music_artwork/esp32_s3_music_artwork.ino` — ESP32-S3 Arduino sketch; NimBLE-Arduino 2.3.x.
- `iOS/ContentView.swift` — SwiftUI BLE bridge, metadata, artwork search + JPEG transfer.
- `iOS/S3MusicArtworkApp.swift` — missing iOS app entry point from the previous ZIP.
- `project.yml` — XcodeGen specification, including Bluetooth privacy description.
- `.github/workflows/build-ios.yml` — hosted macOS build that produces an unsigned `.ipa` artifact.

## A. ESP32-S3 (Windows + Arduino IDE)

1. Install NimBLE-Arduino 2.3.x. Select `ESP32S3 Dev Module` and the proper COM port.
2. Upload the `.ino`; open Serial Monitor at 115200.
3. Confirm your existing iPhone bond and AMS log (`AMS subscribed successfully!` and song/artist). If the updated sketch doesn't reconnect, revert to your previously working AMS sketch and debug before installing the iPhone app.

## B. Build the iPhone app WITHOUT a Mac

1. Create a **new GitHub repository** using your own account, e.g. `s3-music-artwork`. Do not publish passwords or account credentials.
2. Upload this **project's contents**, preserving the `iOS`, `.github/workflows`, and Arduino directories; use GitHub Desktop, Git from VS Code, or `git` on Windows. The file `.github/workflows/build-ios.yml` must appear in the repository.
3. Visit the repository's **Actions** tab. Select **Build unsigned iPhone app** and click **Run workflow** (or use the automatic run after pushing to `main`).
4. When the workflow finishes successfully, click its run, download artifact `S3MusicArtwork-unsigned-IPA`, and extract the downloaded ZIP. You should find `S3MusicArtwork-unsigned.ipa` inside.
5. On your Windows PC install Sideloadly from `https://sideloadly.io/` and the Apple components it requests. Connect iPhone to PC by USB and tap **Trust** on the iPhone.
6. In Sideloadly, select your iPhone, load `S3MusicArtwork-unsigned.ipa`, use your own Apple ID for signing, and install. Follow Apple's on-device prompts for developer app trust/Developer Mode if prompted.
7. Open **S3 Music Artwork** on your iPhone and allow Bluetooth access. Keep it **in the foreground** for the first test, with internet available on the phone.
8. It should find the custom ESP32 BLE bridge. Play YouTube Music, inspect song and artist in the app, then check for matching album art. Arduino Serial Monitor should show an `ART SUCCESS` message on successful JPEG transfer.

This is **not a verified one-click installation**. The hosted build might fail; GitHub Actions logs will show compiler diagnostics. On free Apple ID signing, Sideloadly states app signatures expire after **7 days** unless refreshed. Free plan and runner limits can apply. Sideloading requires entrusting the installer with signing access; review its privacy/security model before using it.

## C. Limitations

- The iPhone's internet is used to query the **iTunes Search API**. The ESP32 stays Bluetooth-only. YouTube Music/Apple catalog covers may differ; some songs cannot be matched.
- Apple's AMS exposes track name, artist, album, duration, but not JPEG album art directly.
- A custom iOS app cannot be built into an iPhone-installable app from Swift code using Windows alone; GitHub's runner supplies macOS/Xcode.
- **CarPlay and lock-screen background operation are unproven.** iOS may suspend the app when it leaves the foreground; continuous background artwork updates are not guaranteed.
- The Arduino sketch only stores received JPEG bytes in RAM, so you will **not** see artwork on a physical ESP32 display until a TFT and JPEG decoder are added.
- This prototype needs an additional BLE connection to the custom service; the exact interaction between the AMS accessory connection and the app must be tested on your hardware.
- Keep USB wiring and screens securely mounted, clear of controls and airbag paths. Perform tests while parked.

## Sources

- GitHub-hosted macOS runners: https://docs.github.com/en/actions/reference/runners/github-hosted-runners
- XcodeGen: https://github.com/yonaskolb/XcodeGen
- Sideloadly: https://sideloadly.io/
- Apple iTunes Search API: https://performance-partners.apple.com/search-api
