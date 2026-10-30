# Mac Text Improver (Copilot Proofreader)

A native macOS menu-bar app that checks your spelling and grammar with **GitHub Copilot**, in any app, before you hit send.

Press **⌃⌘S** while you type in Slack, Teams, Outlook, Messages, a browser, or anywhere else. A small panel shows the suggested fixes: deletions in red, additions in green. Press **Return** to put the corrected text back in place. A typical check takes about 2 seconds.

It catches what the built-in macOS checker misses: grammar, wrong words that are spelled correctly (their/there, then/than), missing words, capitalization, and punctuation. It keeps your tone and meaning.

## What it does

| Shortcut | Action |
| --- | --- |
| **⌃⌘S** | **Fix:** corrects spelling, grammar, and punctuation only. |
| **⌃⇧⌘S** | **Improve Wording:** fixes errors and also smooths awkward phrasing. |

- If you've selected text, only the selection is checked. If nothing is selected, the whole text field is checked.
- If nothing needs fixing, a brief "Looks good" check appears.
- Your clipboard is restored after each check.

In the preview panel:

| Key | Action |
| --- | --- |
| **Return** | Replace your text with the fix |
| **⌘C** | Copy the fixed text |
| **⌘P** | Rewrite it with Improve Wording |
| **Esc** | Cancel |

## Requirements

- macOS 13 (Ventura) or later, on Apple silicon or Intel
- Xcode Command Line Tools, for `swiftc`: `xcode-select --install`
- Node.js 20 or later, e.g. `brew install node`
- A GitHub account with an active **GitHub Copilot** subscription

## Getting started

1. **Clone and build.**

   ```bash
   git clone https://github.com/bryhaw/mac-text-improver.git
   cd mac-text-improver
   ./build.sh
   ```

   This installs the helper's npm packages, compiles the app, and installs it to `~/Applications/Copilot Proofreader.app`. Then it launches the app. A ✓ icon appears in the menu bar.

2. **Grant Accessibility permission.** The app needs it to copy your text and paste the fix back. When prompted, open **System Settings → Privacy & Security → Accessibility** and turn on **Copilot Proofreader**.

3. **Sign in to GitHub Copilot.** The app reuses an existing Copilot sign-in on your Mac, for example from the Copilot CLI. If none is found, it opens your browser to sign in on first use.

4. **Try it.** Type something like `i think their going to be late to the meeting tommorow` in any text box. Press **⌃⌘S**, then **Return**.

Optional: choose **Open at Login** from the menu-bar icon.

## Menu-bar options

- **Model:**
  - GPT-6 Luna is the default: fast and low cost.
  - MAI Code 2 Flash is free.
  - Claude Sonnet is the most thorough.
- **Shortcut:** ⌃⌘S (default), ⌃⌥S, ⌃⌘E, or ⌃⌥G. Improve Wording always adds ⇧ to the shortcut you choose.
- **Show Changes Before Replacing:** turn this off to replace your text immediately.
- **Open at Login**
- **Restart Copilot Helper**

## Privacy

- Text is sent only when you press the shortcut, and only to GitHub Copilot through the official SDK.
- Each check runs in a fresh session with no tools, no MCP servers, and no saved history. Your draft is treated as text to fix, not as instructions.
- Nothing you type is stored or logged. The diagnostic log records only steps and character counts.
- Password and other secure fields can't be read.
- No tokens or secrets are stored in this repo. Authentication is handled by the Copilot SDK's own sign-in.

## How it works

```
app/      Native Swift/AppKit menu-bar app (no Xcode project needed)
  Sources/
    AppDelegate.swift   menu, hotkeys, check → preview → replace flow
    HotKey.swift        Carbon global hotkey registration
    TextBridge.swift    copy selection (or ⌘A⌘C), paste back, restore clipboard
    ProofPanel.swift    floating preview panel with the word-level diff
    Diff.swift          word-level LCS diff
    HelperClient.swift  talks to the Node helper over line-delimited JSON
    Settings.swift      model choices, shortcut presets, preferences
  make-icon.swift       renders the app icon at build time
helper/   Node process that calls Copilot via @github/copilot-sdk
  proofread-helper.mjs  stdin/stdout JSON bridge, Copilot session handling
  proofread-core.mjs    prompts, output cleanup, and validation
build.sh  build, sign, bundle the helper, install to ~/Applications
```

## Building and signing

```bash
./build.sh            # build, sign, install, and launch
./build.sh --no-open  # build and install without launching
```

- `build.sh` signs with your first **Apple Development** certificate, if you have one, so the Accessibility permission survives rebuilds.
- If you don't have one, it signs ad hoc. Then you'll need to re-enable Accessibility after each rebuild: remove the app from the list and add it again.
- To choose a certificate, set `SIGN_IDENTITY="Apple Development: …" ./build.sh`.

## Development

```bash
cd helper && npm test   # helper unit tests
```

- To preview the panel layout without calling Copilot, run `PROOFREADER_DEMO=preview "$HOME/Applications/Copilot Proofreader.app/Contents/MacOS/Copilot Proofreader"`.
- The app log is at `~/Library/Logs/Copilot Proofreader.log`.
- Copilot runtime logs are in `~/Library/Application Support/Copilot Proofreader/copilot/logs`.

## Troubleshooting

- **The shortcut does nothing:**
  - Make sure Copilot Proofreader is turned on under Accessibility. After a rebuild with a different signature, remove it and add it again.
  - Make sure no other app uses the same shortcut. Pick another from the menu.
- **"Couldn't read any text":** click into the text field first. Some apps block synthetic copy and paste.
- **Sign-in or helper errors:** choose **Restart Copilot Helper** from the menu, then check the logs above.
