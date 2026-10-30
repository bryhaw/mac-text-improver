# Agent and contributor instructions

## This is a public repository

Everything committed here is visible to anyone. These rules apply to every change, by people or agents:

- **Never commit secrets.** That includes API keys, tokens, passwords, certificates, signing identities, provisioning profiles, `.env` files and `.npmrc` files. Tests that need a key-shaped value build it at runtime, for example `["sk", "test", "123"].join("-")`, so the literal never appears in source.
- **Never commit personal or internal details.** That means home-directory paths (`/Users/<name>/`), work or personal email addresses, internal hostnames, company package feeds, machine names and team IDs. Use `$HOME`, `~`, `example.com` or placeholders instead.
- **Never commit user content or logs.** Real text from a user's messages, screenshots of private conversations, and `*.log` files stay out of the repo.
- **Commit as a GitHub noreply identity** (`<id>+<user>@users.noreply.github.com`). Don't embed tokens in remote URLs or the git config.
- **`helper/package-lock.json` must resolve only from `https://registry.npmjs.org/`.** If a private registry rewrites `resolved` URLs, change them back before committing. The integrity hashes are the same.
- **Run the guard before every commit and push:** `scripts/check-secrets.sh` (all tracked files) or `scripts/check-secrets.sh --staged`. Enable the hook once per clone with `git config core.hooksPath .githooks`. CI runs the same check on every push and pull request. If the guard flags a false positive, reword the content rather than weakening the check, unless the pattern itself is wrong.

## Handling user data in code

- API keys live only in the macOS Keychain (`Keychain.swift`). The app sends them to the helper over stdin in a `configure` message. They are never passed through environment variables, command-line arguments, files or logs.
- Never log the text being checked, model output or keys. `Log.swift` and the helper's stderr should record only events, states and timings. Use `redact()` in `helper/providers.mjs` for any provider error that is shown or logged.
- Text is sent only to the provider the user selected.

## Layout

- `app/Sources/`: the Swift/AppKit menu-bar app (hotkeys, Accessibility text capture, preview panel, provider and model menus, Keychain).
- `helper/`: the Node helper. `proofread-helper.mjs` handles the line-delimited JSON protocol and routing, `providers.mjs` holds the OpenAI and Anthropic HTTP clients, and `proofread-core.mjs` holds the prompts and output cleanup.
- `build.sh`: builds and signs `Copilot Proofreader.app` and installs it to `~/Applications`.

## Build and test

```bash
cd helper && npm test          # helper unit tests (network is mocked)
./build.sh --no-open           # build, sign and install without launching
```
