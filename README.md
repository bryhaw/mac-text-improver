# Mac Text Improver (Copilot Proofreader)

A native macOS menu-bar app that checks your spelling and grammar with AI, in any app, before you hit send. It uses **GitHub Copilot** by default, or your own **OpenAI** or **Anthropic** API key.

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
- Formatting is kept. Images, links, bold, and signatures stay in place, and only the words that changed are replaced. This works in web apps like Outlook on the web, Slack, and Teams, and in native apps like TextEdit and Notes. If a fix can't be placed precisely, the app falls back to pasting plain text.
- Line breaks, blank lines, and spacing from your original are always preserved.

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
- One of these:
  - a GitHub account with an active **GitHub Copilot** subscription (the default), or
  - an **OpenAI** or **Anthropic** API key

## Getting started

1. **Clone and build.**

   ```bash
   git clone https://github.com/bryhaw/mac-text-improver.git
   cd mac-text-improver
   ./build.sh
   ```

   This installs the helper's npm packages, compiles the app, and installs it to `~/Applications/Copilot Proofreader.app`. Then it launches the app. A ✓ icon appears in the menu bar.

2. **Grant Accessibility permission.** The app needs it to copy your text and paste the fix back. When prompted, open **System Settings → Privacy & Security → Accessibility** and turn on **Copilot Proofreader**.

3. **Connect a provider.**
   - **GitHub Copilot (default):** the app reuses an existing Copilot sign-in on your Mac, for example from the Copilot CLI. If none is found, it opens your browser to sign in on first use.
   - **OpenAI or Anthropic:** choose **Provider → OpenAI** or **Provider → Anthropic** from the menu-bar icon and paste your API key. See [Providers](#providers).

4. **Try it.** Type something like `i think their going to be late to the meeting tommorow` in any text box. Press **⌃⌘S**, then **Return**.

The app keeps itself running: it starts when you log in and reopens automatically if it ever crashes. macOS may show a **Background Items Added** notification the first time. To turn this off, uncheck **Open at Login** in the menu.

## Providers

| Provider | What you need | Billing |
| --- | --- | --- |
| **GitHub Copilot** (default) | A Copilot subscription | Your Copilot plan |
| **OpenAI** | An API key from [platform.openai.com/api-keys](https://platform.openai.com/api-keys) | Your OpenAI API account, pay per use |
| **Anthropic** | An API key from [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys) | Your Anthropic API account, pay per use |

- Switch providers from **Provider** in the menu. When you pick OpenAI or Anthropic for the first time, the app asks for a key and checks it straight away.
- To replace or remove a key, choose **Provider → OpenAI API Key…** or **Anthropic API Key…**.
- Keys are stored only in your **macOS Keychain**, under "Copilot Proofreader API Keys". They're never written to disk, logs, or this repo.
- ChatGPT Plus and Claude Pro/Max subscriptions aren't supported. Those plans don't include API access; you need an API key.
- After a rebuild with a different signing certificate, macOS may ask whether the app can read its Keychain item. Choose **Always Allow**.

## Menu-bar options

- **Provider:** GitHub Copilot, OpenAI, or Anthropic, plus key management.
- **Model:** lists the models your provider offers. A fast, low-cost model is picked by default:
  - On Copilot, GPT-6 Luna is the default. MAI Code 2 Flash is free, and Claude Sonnet is the most thorough.
  - On OpenAI and Anthropic, the list comes from your account. **Custom Model ID…** lets you enter any model ID.
- **Shortcut:** ⌃⌘S (default), ⌃⌥S, ⌃⌘E, or ⌃⌥G. Improve Wording always adds ⇧ to the shortcut you choose.
- **Show Changes Before Replacing:** turn this off to replace your text immediately.
- **Open at Login:** on by default. Starts the app at login and relaunches it after a crash. Choosing **Quit** stops it until you open it again or log in.
- **Restart Helper**

## Privacy

- Text is sent only when you press the shortcut, and only to the provider you selected:
  - GitHub Copilot, through the official SDK, or
  - `api.openai.com` / `api.anthropic.com`, directly over HTTPS.
- Each check is a single, stateless request with no tools and no saved history. Your draft is treated as text to fix, not as instructions.
- Your provider's own data policies apply. API requests aren't used for training by default on OpenAI or Anthropic.
- Nothing you type is stored or logged. The diagnostic log records only steps and character counts.
- Password and other secure fields can't be read.
- API keys live only in the macOS Keychain. The app passes them to the helper over a private pipe, never through environment variables, arguments, or files.
- No tokens or secrets are stored in this repo. Copilot authentication is handled by the Copilot SDK's own sign-in.

## How it works

```
app/      Native Swift/AppKit menu-bar app (no Xcode project needed)
  Sources/
    AppDelegate.swift   menu, hotkeys, check → preview → replace flow
    HotKey.swift        Carbon global hotkey registration
    TextBridge.swift    copy selection (or ⌘A⌘C), paste back, restore clipboard
    ProofPanel.swift    floating preview panel with the word-level diff
    Diff.swift          word-level LCS diff; keeps the original's line breaks and spacing
    RichText.swift      applies fixes inside copied HTML/RTF so images, links, and styles survive
    HelperClient.swift  talks to the Node helper over line-delimited JSON
    Settings.swift      providers, model choices, shortcut presets, preferences
    Keychain.swift      stores OpenAI/Anthropic API keys in the macOS Keychain
  make-icon.swift       renders the app icon at build time
helper/   Node process that calls the selected provider
  proofread-helper.mjs  stdin/stdout JSON bridge, provider routing, Copilot sessions
  providers.mjs         OpenAI and Anthropic API clients and model listing
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
cd helper && npm test   # helper unit tests (network is mocked; no keys needed)
```

This is a **public repository**. Read [AGENTS.md](AGENTS.md) before contributing. Enable the secret guard once per clone:

```bash
git config core.hooksPath .githooks   # runs scripts/check-secrets.sh on every commit
```

CI runs the same check on every push and pull request.

- To preview the panel layout without calling a provider, run `open -n --env PROOFREADER_DEMO=preview "$HOME/Applications/Copilot Proofreader.app"`. Use `PROOFREADER_DEMO=apikey` to show the API key dialog.
- The app log is at `~/Library/Logs/Copilot Proofreader.log`.
- Copilot runtime logs are in `~/Library/Application Support/Copilot Proofreader/copilot/logs`.

## Troubleshooting

- **The shortcut does nothing:**
  - Make sure Copilot Proofreader is turned on under Accessibility. After a rebuild with a different signature, remove it and add it again.
  - Make sure no other app uses the same shortcut. Pick another from the menu.
  - A preview left open no longer blocks the shortcut. Switching apps dismisses the preview, and pressing the shortcut again starts a fresh check. AI requests time out after 60 seconds.
- **The app isn't running (no menu-bar icon):**
  - Open it from `~/Applications`. Make sure **Open at Login** is checked, and that Copilot Proofreader is allowed under **System Settings → General → Login Items & Extensions**.
  - Check the launch agent with `launchctl print gui/$(id -u)/com.bryhaw.copilot-proofreader.agent`. The log records each launch, quit, and crash.
- **"Couldn't read any text":** click into the text field first. Some apps block synthetic copy and paste.
- **Sign-in or helper errors:** choose **Restart Helper** from the menu, then check the logs above.
- **"Rejected your API key":** choose **Update Key** in the error, or **Provider → OpenAI API Key…** / **Anthropic API Key…**. Check that the key is active and that the account has billing set up.
- **"Doesn't recognize the model":** pick another model from **Model**, or enter one with **Custom Model ID…**.
