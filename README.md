# Yuhaiin macOS

A native macOS menu-bar controller for [yuhaiin](https://github.com/asutorufa/yuhaiin). The UI runs as the logged-in user. A root Supervisor is registered with `SMAppService` as a LaunchDaemon, and yuhaiin runs as the Supervisor's child process.

The app UI currently supports English, Japanese, and Korean.

## Build

```sh
./build.sh
```

By default, the build reads the arm64 and x86_64 yuhaiin binaries from the adjacent `yuhaiin` checkout. Prebuilt binaries can be supplied explicitly:

```sh
YUHAIIN_ARM64=/path/to/yuhaiin_darwin_arm64 \
YUHAIIN_AMD64=/path/to/yuhaiin_darwin_amd64 \
./build.sh
```

If an architecture binary is missing and the adjacent checkout is available, the script attempts a `GOOS=darwin`, `CGO_ENABLED=0` cross-build. It uses the `untested_go_version` build tag by default for compatibility with the current Go dependencies; override it with `YUHAIIN_GO_BUILD_TAGS` when needed.

The app bundle is assembled as a Universal 2 application. `build.sh` embeds the yuhaiin binaries, copies the English, Japanese, and Korean `.lproj` resources, and packages the Yuhaiin Android delivery-truck icon as `AppIcon.icns`.

For Sparkle app updates, the release pipeline should provide an appcast URL and EdDSA public key:

```sh
YUHAIIN_APPCAST_URL=https://updates.example.com/yuhaiin/appcast.xml \
YUHAIIN_SPARKLE_PUBLIC_KEY=<ed25519-public-key> \
./build.sh
```

Release builds should also provide `YUHAIIN_TEAM_ID`. The Supervisor then restricts XPC clients to the expected Team ID and requires downloaded yuhaiin binaries to be signed by the same Developer ID team. Without it, the build uses the bundle identifier and basic code-signing validity checks, which is suitable only for local ad-hoc validation.

## Install and run

The bundled LaunchDaemon plist points to `/Applications/Yuhaiin.app` so that it does not register a temporary build path. Install the app before launching it:

```sh
ditto build/Yuhaiin.app /Applications/Yuhaiin.app
open /Applications/Yuhaiin.app
```

On first launch, open Settings and choose **Install and Authorize Background Component**. macOS handles the system authorization; the app does not collect or store a root password. The following options are independent:

- launch the app at login;
- start yuhaiin when the app launches;
- show live traffic speed in the menu bar.

The Supervisor is registered against `/Applications/Yuhaiin.app`. If the app is launched directly from `build/` or another folder, the app now explains that it must be copied to `/Applications` before yuhaiin can start.

Management API authentication is disabled by default. When enabled, the username and password are stored in the macOS Keychain. Applying the settings restarts yuhaiin. The password is not written to UserDefaults, logs, or yuhaiin command-line arguments.

App preferences are stored at `~/Library/Application Support/YuhaiinMacOS/settings.json`. On the first run, the app migrates the old UserDefaults settings if that file does not exist.

Settings also provides an optional custom yuhaiin binary path for local testing. Leave it empty to use the embedded binary. Custom binaries must be executable, match the current architecture, and pass the Supervisor's code-signing validation.

For an unsigned local build, use **Upload and Install Binary** in Settings instead. The Supervisor copies the selected Mach-O into its root-managed runtime directory, makes it executable, applies an ad-hoc signature for local testing, and validates the current architecture before installation. The app restores the previous runtime if validation fails.

When the app exits, it releases its Supervisor lease. If the app crashes or is force-terminated, XPC invalidation and the Supervisor heartbeat timeout stop yuhaiin. If the Supervisor itself exits, yuhaiin also uses a parent-PID watchdog and terminates instead of becoming a launchd orphan.

The Supervisor reuses the existing `/Library/Application Support/yuhaiin` data directory by default, so migration does not create a second configuration or database.

Settings includes **Uninstall Background Component**. It stops and unregisters the Supervisor, disables launch-at-login, and keeps yuhaiin data by default. A standalone legacy LaunchDaemon requires a separate, explicit migration or cleanup action.

## Current boundaries

- `build.sh` uses ad-hoc signing by default and is intended for build and static validation. A macOS release containing a LaunchDaemon requires a real Developer ID signature, a fixed Team ID requirement, notarization, and an appropriate installer or distribution flow.
- If the adjacent yuhaiin checkout is available, `build.sh` builds missing architectures automatically. A release Universal 2 package must contain both yuhaiin architecture binaries.
- Sparkle 2 app update plumbing is included. Without an appcast and public key, the UI reports that the update feed is not configured. yuhaiin update checks, HTTPS/checksum/signature validation, root-owned runtime replacement, and rollback are handled by the Supervisor. Management API Basic Auth is optional and uses Keychain-backed credentials.
- `SMAppService`, a real root process, and exit cleanup still require one launchd smoke test on the target macOS versions using a properly signed package. Local build checks cannot replace that validation.
- The management API defaults to `127.0.0.1:50051` and can be changed in Settings. The Supervisor accepts only localhost addresses, preventing accidental LAN exposure.

## Localization

The localized UI resources are:

- `Resources/en.lproj/Localizable.strings`
- `Resources/ja.lproj/Localizable.strings`
- `Resources/ko.lproj/Localizable.strings`

Use the normal macOS language preference to choose a supported language. English is the development and fallback language.
