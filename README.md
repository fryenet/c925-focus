# c925-focus

A small, native macOS command-line tool to control autofocus on the **Logitech C925e** webcam.

- `on` — enable continuous autofocus.
- `off` — disable continuous autofocus (lock focus).
- `status` — read the camera's current **hardware autofocus setting** using a USB Video Class (UVC) `GET_CUR` request.

The commands have been tested on a Logitech C925e running macOS Tahoe: after switching autofocus on or off, `status` returned the matching state. Results may vary with other Macs, macOS versions, and webcam models.

## Requirements

- A Mac running macOS with a connected Logitech **C925e** webcam
- Apple's **Xcode Command Line Tools** (the full Xcode app is not required)
- Terminal

This tool is **macOS-only**. It uses Apple's **AVFoundation** to change the autofocus mode and **IOKit** to read the webcam's UVC autofocus setting. No Python, Homebrew, or third-party libraries are required.

The current source identifies the C925e specifically, by camera name for `on`/`off` and USB vendor/product IDs for `status` (`046d:085b`). Other webcam models are **not** supported without changes and testing.

## 1. Download from GitHub

Open **Terminal on your Mac**.

Install Apple's Command Line Tools if you haven't already:

```sh
xcode-select --install
```

Clone the project and enter its directory:

```sh
git clone https://github.com/fryenet/c925-focus.git
cd c925-focus
```

> If Git reports **repository not found**, the GitHub repository may not have been created or published yet.

## 2. Compile in Terminal

Run this **inside the cloned `c925-focus` folder**:

```sh
xcrun clang -fobjc-arc -Wall -Wextra \
  -framework Foundation \
  -framework AVFoundation \
  -framework IOKit \
  -framework CoreFoundation \
  c925-focus.m -o c925-focus
```

This builds a native executable named `c925-focus` in the current folder.

## 3. Run it

Connect your Logitech C925e and try:

```sh
./c925-focus status
./c925-focus off
./c925-focus status
./c925-focus on
./c925-focus status
```

Expected output when the camera accepts the commands and hardware status readback succeeds:

```text
on

off
off
on
on
```

The first `status` value depends on the camera's current setting, so it may initially be either `on` or `off`.

**What the commands mean:**

| Command | Action |
| --- | --- |
| `./c925-focus on` | Requests continuous autofocus through AVFoundation |
| `./c925-focus off` | Requests locked focus through AVFoundation |
| `./c925-focus status` | Queries the C925e's UVC Focus Auto control (`GET_CUR`), reporting `on` or `off` |

If hardware status cannot be read, `status` prints a diagnostic such as `status: unknown (...)` and exits with code **3**. It does not guess based on the previous command.

## 4. Install the executable

Install the compiled executable in your user account:

```sh
mkdir -p "$HOME/.local/bin"
cp ./c925-focus "$HOME/.local/bin/c925-focus"
chmod +x "$HOME/.local/bin/c925-focus"
```

You can now use its full path from any directory:

```sh
"$HOME/.local/bin/c925-focus" off
"$HOME/.local/bin/c925-focus" status
```

**Optional:** To run it simply as `c925-focus`, add `~/.local/bin` to your Terminal's `PATH`:

```sh
echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zprofile"
source "$HOME/.zprofile"
```

Then you can run:

```sh
c925-focus off
c925-focus status
```

If you previously installed an older `c925-focus` somewhere else, check which binary is being used:

```sh
type -a c925-focus
```

## 5. Disable autofocus automatically at login

Once **`"$HOME/.local/bin/c925-focus" off` works manually**, you can configure macOS to run it each time you log in.

This uses a per-user **LaunchAgent**. It runs **at login**, not before login during system boot.

Create the LaunchAgent in Terminal:

```sh
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

cat > "$HOME/Library/LaunchAgents/com.fryenet.c925-focus.plist" <<EOF_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.fryenet.c925-focus</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HOME/.local/bin/c925-focus</string>
        <string>off</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>$HOME/Library/Logs/c925-focus.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/c925-focus-error.log</string>
</dict>
</plist>
EOF_PLIST

# Validate the property list before loading it.
plutil -lint "$HOME/Library/LaunchAgents/com.fryenet.c925-focus.plist"
chmod 644 "$HOME/Library/LaunchAgents/com.fryenet.c925-focus.plist"

# Unload a previously installed copy (if present), then load this one.
launchctl bootout "gui/$(id -u)/com.fryenet.c925-focus" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.fryenet.c925-focus.plist"

# Confirm launchd knows about the agent.
launchctl print "gui/$(id -u)/com.fryenet.c925-focus"
```

The `EOF_PLIST` delimiter is intentionally unquoted so that your actual home directory is written into the property list. `launchd` does not expand `$HOME` in `ProgramArguments` by itself. The `bootout` step prevents a previously loaded copy of the same agent from interfering with a fresh `bootstrap`.

**Test the LaunchAgent immediately:**

```sh
launchctl kickstart -k "gui/$(id -u)/com.fryenet.c925-focus"
"$HOME/.local/bin/c925-focus" status
```

**View logs:**

```sh
cat "$HOME/Library/Logs/c925-focus.log"
cat "$HOME/Library/Logs/c925-focus-error.log"
```

**Disable automatic autofocus-off at login:**

```sh
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.fryenet.c925-focus.plist"
rm "$HOME/Library/LaunchAgents/com.fryenet.c925-focus.plist"
```

**Limitations:** The LaunchAgent runs once when your user session loads. It does not continuously enforce the setting, wait for a webcam plugged in later, or guarantee that another app will not turn autofocus back on. If the webcam is not ready at login or macOS denies access, check the logs. Test by logging out and back in after setup.

## Troubleshooting

**`Bootstrap failed: 5: Input/output error`** — This is a generic launchd load failure. First check the executable and run it manually:

```sh
ls -l "$HOME/.local/bin/c925-focus"
"$HOME/.local/bin/c925-focus" off
```

Then validate the LaunchAgent, check its permissions, unload any existing instance, and load it again:

```sh
PLIST="$HOME/Library/LaunchAgents/com.fryenet.c925-focus.plist"
plutil -lint "$PLIST"
chmod 644 "$PLIST"
launchctl bootout "gui/$(id -u)/com.fryenet.c925-focus" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl print "gui/$(id -u)/com.fryenet.c925-focus"
```

If loading still fails, inspect macOS diagnostics:

```sh
ls -leO "$HOME/Library/LaunchAgents/com.fryenet.c925-focus.plist"
log show --last 5m --style compact --predicate 'process == "launchd" AND eventMessage CONTAINS "com.fryenet.c925-focus"'
```

Do not run the LaunchAgent as root; it is intended to run in your logged-in user session.


**`status: unknown (USB device busy or access denied: ...)`** — macOS may prevent direct USB access while the camera is in use. `status` cannot provide a verified answer in that case; it does not assume `off`.

**`status: unknown (UVC GET_CUR failed: ...)`** — The hardware readback failed. Try reconnecting the webcam and checking whether another app is using it.

**`Logitech C925e not found.`** — Check the USB connection and that macOS recognizes the webcam. The `on`/`off` commands look for a camera name containing `C925e`.

**`Requested focus mode is not supported.`** — AVFoundation did not expose the requested focus mode for that camera.

**Camera permission issues** — Check **System Settings → Privacy & Security → Camera**, and grant access when macOS requests it. Background LaunchAgent access may behave differently from running the tool interactively in Terminal.

**`c925-focus` runs an older version** — Use `type -a c925-focus` to locate installed copies, and use `./c925-focus` in the build directory when testing a freshly compiled version.

**`xcrun` cannot find a compiler** — Install Xcode Command Line Tools with `xcode-select --install`.

## Notes and limitations

- The UVC `status` request is **read-only** and does not forcibly seize the webcam from macOS.
- `on` and `off` report that the AVFoundation setting was accepted; you can follow them with `status` to verify the camera's reported UVC setting.
- The hardware-status feature has been confirmed in one C925e/macOS Tahoe setup, but has not been broadly tested.
- The utility is intentionally limited to the Logitech C925e, rather than claiming universal support for Logitech webcams.

## License

No license is included unless a separate `LICENSE` file is added to the repository. If you want others to reuse and modify the source, consider adding an open-source license such as MIT.
