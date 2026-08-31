# QuickAI

QuickAI is a native macOS replacement for Raycast Quick AI, which went Pro-only in Raycast 2.0. A hotkey opens a Spotlight-style panel, you ask, the answer streams back as full-width Markdown, and Enter alone sends the follow-up.

Mac only. SwiftUI + AppKit, built with SPM, no Xcode project (Command Line Tools are enough). It started as a Raycast extension and was abandoned there: the extension API cannot pin a text input over full-width markdown, which is the whole interaction this app exists for.

## What makes QuickAI special

Four things it cannot lose while it grows.

### 1. It answers on a subscription you already pay for

Harness providers run a coding-agent CLI that is already installed and logged in (`opencode`, `claude`, `copilot`), so the answer is covered by that subscription and no metered API key is involved. Anything that quietly moves a turn onto API billing is a bug, not a trade-off.

### 2. It cannot touch the machine

The panel is a place to ask questions, not an agent. Lean mode disables every tool, and safe mode is the floor even with lean mode off: never `--auto` for opencode, never `--dangerously-skip-permissions` or `--permission-mode bypassPermissions` for claude, never `--allow-all-tools`, `--allow-all` or `--yolo` for copilot.

### 3. It is faster than the thought that opened it

⌥Space to a focused input, first token as early as the provider can give it. No spinner that lies, no animation that repaints while an answer streams, no work on the main thread between the hotkey and the caret.

### 4. Nothing is destroyed

Deleting a conversation moves it to a 30-day bin. `emptyTrash()` is the only irreversible operation in the whole app, and it is behind a confirmation.

## How to work here

Santi's preferences override anything in this file. The ones that come up constantly:

- **Never commit or push unless he asks.** Editing, staging and branching are fine; the tree stays dirty until he says so.
- **Nothing lands on main directly.** Every change arrives by PR from a branch; a repository ruleset enforces it (PRs only, squash or rebase, review threads resolved before merge, no bypass for anyone). A trivial fix takes the same path, just as a smaller PR.
- **Verify in the bundled app**, not in `swift run`, and not by reasoning about the code.
- **Checks come in two tiers, and only one is free to run.** The scripts and anything else that runs headless (a child process, a pty) are background checks: run them whenever. Anything that drives the screen with synthetic input (osascript keystrokes into the panel, clicking, pressing his hotkey) is a UI test: **ask Santi first, every time**, because his keyboard may be mid-sentence in another window. This rule exists because a session once typed a test question into Raycast while he was working.
- Code, comments and output strings are in English whatever language the conversation is in.
- No em dashes in anything a human reads.
- Session state (plans, notes, decisions) lives in `.agent/`, which is gitignored. It never lands in a commit.

## A small glossary

- **panel** is the floating window itself: compact (one input row) or expanded (header, body, follow-up input).
- **provider** is where an answer comes from: OpenRouter, a local OpenAI-compatible server, or a harness.
- **harness** is a coding-agent CLI used as a provider, one `HarnessKind` per CLI.
- **lean mode** is a harness running with QuickAI's own system prompt and no tools. It is the default.
- **turn** is one question and its answer. For claude and copilot it is also one child process.
- **chunk** is one `StreamChunk` off a provider: `.reasoning` (live progress, never saved) or `.text` (the answer).
- **conversation** is the durable thread, stored in `conversations.json`, capped at 50, deleted into `trash.json`.

## The three ways to hurt yourself

1. **Testing the store against the real directory.** `ConversationStore`'s delete paths write real files and `emptyTrash()` is irreversible. Pointing `HOME` elsewhere does NOT redirect `FileManager.urls(for: .applicationSupportDirectory…)`. This wiped a real history once. Use `ConversationStore(directory:)` and `./scripts/store-test.sh`, which builds its own temp dir.
2. **Putting a turn on API billing.** Three independent layers keep the subscription in charge, because a flag choice alone is not verifiable at runtime: the `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_BASE_URL` variables are scrubbed from the child environment, `--bare` is never passed, and `apiKeySource` from the `system/init` event must read `none` before a single chunk is yielded. Never remove a layer because another one covers it. Copilot's metered path is BYOK, which is env-only: `COPILOT_PROVIDER_*` and the GitHub token overrides (`COPILOT_GITHUB_TOKEN`, `GH_TOKEN`, `GITHUB_TOKEN`) are scrubbed, and the private `COPILOT_HOME` is the second layer, since no config file can re-enable BYOK.
3. **Writing into the user's own agent state.** QuickAI writes no opencode config and never touches theirs (`prompt_async` takes `system` and `tools` per request, so no `OPENCODE_CONFIG` file is needed). Throwaway calls such as titles use `--no-session-persistence` so they never land in the user's Claude Code history. The opencode child gets its own empty working directory, a random per-launch password, and `OPENCODE_DISABLE_PROJECT_CONFIG`. The copilot child always runs with a QuickAI-private `COPILOT_HOME` (auth is in the Keychain, service "copilot-cli", so login survives): that one override is what keeps QuickAI's sessions out of the user's resume list, their MCP servers from spawning under the panel, and their memory untouched. Copilot has no `--no-session-persistence`, so do not "simplify" back to the real `~/.copilot`.

## Hit every surface

The most common defect here is a change that works on the path you tested. Before calling something done, walk this list and say which entries applied:

- **Providers.** OpenRouter, local server, opencode, claude, copilot. A provider-shaped change needs a decision for each one, even if the decision is "not supported here".
- **Panel states.** Compact and expanded, chat and history. The panel keeps its state while hidden, so anything that must be fresh on reopen has to be refreshed explicitly (`PanelController.show()` restarts the history search for exactly this reason).
- **Appearance.** Auto, Light and Dark all ship. No view may hard-code a color to one appearance; derive it from `colorScheme`.
- **Keyboard and mouse.** Every panel action is reachable by keyboard, and the shortcuts bar (⌘/) lists it. A new binding that only works with the mouse is half a feature.
- **Bundle versus `swift build`.** ATS, LSUIElement and the UserDefaults domain only exist in the bundle.

## Build and run

- `swift build` compiles. `./scripts/bundle.sh` assembles `build/QuickAI.app` (icns, Info.plist, ad-hoc codesign); `--universal` cross-compiles arm64 + x86_64 into separate scratch paths and `lipo`s them, since SwiftPM's own `--arch` needs full Xcode.
- Install what you built: `./scripts/bundle.sh && pkill -x QuickAI; ditto build/QuickAI.app /Applications/QuickAI.app && open /Applications/QuickAI.app`.
- `VERSION=x.y.z ./scripts/dmg.sh` wraps the universal app in `dist/QuickAI-<version>.dmg` + `.sha256`. A `v*` tag runs it in CI and uploads both. `CODESIGN_IDENTITY` switches both scripts from ad-hoc to a real Developer ID.
- `bundle.sh` stamps `CFBundleVersion` with a build timestamp, shown as the first item of the status-bar menu. It is the fastest way to confirm a rebuild actually replaced the running app.
- One dependency: MarkdownUI (`gonzalezreal/swift-markdown-ui`), for full-width markdown with tables and code blocks.

## Verifying

There is no XCTest target. Each check is a script, and each one covers something a human would not catch by reading:

- `./scripts/store-test.sh` after touching `ConversationStore`.
- `./scripts/harness-test.sh` after touching `HarnessDetector`, `ProcessRunner`, `OpenCodeServer`, `OpenCodeClient`, `ClaudeCodeClient` or `CopilotClient`. It covers detection under a Finder-like environment, channel separation, session reuse, no leftover process, the claude subscription guard, the copilot BYOK scrub, and that nothing lands in the user's own `~/.copilot`. Sections skip cleanly when a CLI is missing; it spends a few tokens on a free opencode model, on claude's `haiku`, and on copilot's `auto`.
- `./scripts/fzf-parity.sh` after touching `FuzzySearch.swift`. It diffs the port against the real `fzf` binary over the actual conversation titles.
- Anything visual gets a screenshot of the installed app. No check covers appearance.

## Commits and pull requests

- A commit on a PR branch is its subject line and nothing else: imperative, at most 72 characters, no trailing period, no `type:` prefix. Name what changed for the person using the app (`Open the model selector itself with Cmd+P`), not which files moved. The branch dies at the squash, so a body written here is a body nobody will ever read on main.
- The PR title and body are the real commit message: a squash merge takes them as the subject and body of the commit that lands on main. The title follows the subject rules above. The body only says what the diff cannot: the why, a measured number, an alternative that was tried and dropped. Never a retelling of the diff.
  - Several unrelated changes: one bullet each, one or two lines per bullet.
  - A single change: two to four lines of prose.
  - About 12 lines is the ceiling. Longer than that means it belongs in this file or in a comment next to the code.
- End a branch commit with the `Co-Authored-By:` trailer when an agent wrote the change (the trailer does not count against the one-line rule; the squash dialog collects co-authors from branch commits).
- One concern per PR. If the title needs an "and", consider two PRs.
- Merges are squash or rebase, never a merge commit, and the branch is deleted on merge.
- CodeRabbit reviews every PR. Address or rebut each comment and resolve its thread; the ruleset blocks merging while any review thread is open. Rebutting with a reply is a valid outcome, silently resolving without one is not.
- Never open a PR unless Santi asks. PRs carry a before/after screenshot for anything visual.

## How it works

A Carbon hotkey (no accessibility permission) tells `PanelController` to show a borderless floating `NSPanel` whose content view is a SwiftUI `ContentView`. Key events are intercepted by a panel-local `NSEvent` monitor, since the text field never gives up focus.

`ChatViewModel` owns the conversation and asks a client for an answer. `ChatClient` speaks SSE to an OpenAI-compatible endpoint; `OpenCodeClient` speaks the headless server's SSE protocol; `ClaudeCodeClient` speaks stream-json to a child process; `CopilotClient` speaks copilot's JSONL event stream to a child process. All four yield the same `StreamChunk` stream, so the view knows nothing about providers. Answers are appended to a `Conversation` and persisted by `ConversationStore`.

Harnesses differ in lifetime. The opencode server is one long-lived child, torn down on three separate paths because `applicationWillTerminate` does not fire on SIGTERM. A claude or copilot turn is one short-lived child that exits when its stdin closes, with context kept by the CLI (`--session-id`, then `--resume`, the same two flags on both).

## Where code lives

Everything is in `Sources/QuickAI/`, one main type per file, no subfolders.

- `App.swift`, `AppDelegate.swift`: status item, main menu (an accessory app needs one for ⌘C/⌘V/⌘W to route at all), hotkey registration, settings window.
- `PanelController.swift`: the panel, its geometry and placement, and every panel-local shortcut.
- `ContentView.swift`: compact input row; expanded header, chat or history, follow-up input; shortcuts bar. `SettingsView.swift`: providers, model browser, hotkey recorder, appearance, Danger Zone.
- `ChatViewModel.swift`, `ChatClient.swift`, `Models.swift` (+ `ConversationStore`), `AppSettings.swift`.
- `FuzzySearch.swift` + `SearchHighlight`: a port of fzf's FuzzyMatchV2, used by history and the model browser. `ModelCatalog.swift`, `HotKey.swift`.
- Harnesses: `HarnessDetector.swift`, `ProcessRunner.swift`, `HarnessSettings.swift` (one per kind), `OpenCodeServer.swift`, `OpenCodeClient.swift`, `ClaudeCodeClient.swift`, `CopilotClient.swift`.
- `scripts/` holds build and check scripts, `.github/workflows/release.yml` the release. `.agent/` is untracked session state.

## Platform traps

- **Never `.id(index)` a `ForEach` row.** The history list did, so rows were identified by position: SwiftUI reused row 0's view across a new search and left the old title on screen while the data underneath was correct. It looked exactly like a broken search algorithm and cost hours. Rows are keyed by conversation id, and `ScrollViewReader` scrolls to that id.
- **A bundled app launched from Finder does not inherit the shell PATH**, so `which opencode` finds nothing in the context that matters. `HarnessDetector` probes explicit install dirs plus the login shell's PATH (`$SHELL -lic 'echo $PATH'`, ~0.14s, resolved once) and validates each hit with `--version`.
- **`applicationWillTerminate` does not fire on SIGTERM.** Teardown is layered: that delegate method, `DispatchSource` handlers for SIGTERM/SIGINT/SIGHUP, and `OpenCodeServer.reapOrphan()` at launch, which kills a recorded PID only after `ps` confirms it still looks like our server.
- **An aborted claude child takes about a second to die** (measured: 0.89s after SIGTERM, exit 143). A leftover check that sleeps one second reports a graceful exit as a leak; poll instead.
- `isMovableByWindowBackground` must stay false: it swallows the drag that text selection needs. The panel is dragged by its chrome, through `WindowDragHandle`.
- **The window is bigger than the panel, and `hasShadow` must stay false.** `PanelController.shadowMargin` (24pt on every side) is transparent room for the panel's own soft shadow, because a borderless window's system shadow hugs the edge too tightly to lift the panel off a dark desktop. AppKit derives that system shadow from the window's alpha, so once the ring is painted it traced a hard black outline around the whole *window* rect, well outside the panel. Every frame in `PanelController` is a window frame; `settings.panelTopLeft` is stored in panel coordinates so changing the margin never moves a parked panel.
- The input field never gives up focus, so scrolling keys never reach the scroll view on their own. `PanelController` translates them and moves the `NSClipView` of the panel's outermost `NSScrollView`, found breadth-first because a markdown code block brings its own. **Never bind a plain letter:** ⌃U and ⌃D were tried and removed, they cost the input field its kill-line and delete-forward bindings.
- macOS Local Network privacy: the first connection to a LAN server can fail while the TCC prompt shows, and ad-hoc signing can reset the grant on each build. Mitigated by a launch-time warm-up fetch plus one silent retry on connect-class failures with zero bytes received.

## Provider traps

- **opencode: `field` is `"text"` on reasoning deltas too.** The only reliable discriminator is the part's declared `type` (`reasoning` vs `text`), which arrives earlier in a `message.part.updated` event (verified: 0 of 503 deltas arrived before their type). Filtering on `field` alone prints the model's thinking into the answer. Filter by role as well: the user's own prompt comes back as a text part. The regression test asserts the reasoning channel *receives* something, because when the routing collapses everything is yielded as `.text` and an absence-only check passes while the bug is live.
- **`opencode run --format json` buffers.** A 600-word answer arrived as a single event. The headless server is the only transport that streams. Do not "simplify" back to the CLI.
- **claude: the invocation shape is deliberate, do not fix it toward the documented one.** Never `--bare`: its own help says auth becomes "strictly ANTHROPIC_API_KEY or apiKeyHelper", so the flag that reads like the right minimal mode forces API billing. Never `-p`: the help claims `--output-format` needs it, but `--input-format stream-json` runs headless without it, which is what the Agent SDK itself spawns (read out of `sdk.mjs`). `--include-partial-messages` and `--no-session-persistence` carry the same misleading note and also work without `-p`.
- **claude, two flags that look useful and are not:** `--exclude-dynamic-system-prompt-sections` is ignored whenever `--system-prompt` is given, which lean mode always does, and no `--effort` setting ever produced a `thinking_delta`, so its reasoning channel stays empty. It is wired up anyway, and unlike the opencode one that test deliberately does not assert the channel receives anything.
- **claude, normal mode is still safe.** Without a permission handler the CLI denies anything that needs one and tells the model so (measured: the write came back refused, the turn continued, no file appeared). It does not hang waiting for an approval that can never come.
- The question travels on stdin, never in argv. The system prompt does go in argv, so it is visible in `ps`: fine for a personal Mac, worth knowing before putting anything private in the Settings prompt field.
- **copilot: some plans only accept `auto` for `--model`, and it is the plan, not the wrapper.** On the Copilot Student plan every explicit id comes back `not available`, including `claude-haiku-4.5`, the model `auto` itself routes to. Verified against the real `~/.copilot` and interactively: the `/model` picker says "Your Copilot Student plan currently includes only Auto" and lists everything else under "Unavailable models", which is easy to read as a working list. Do not chase this as a QuickAI bug again. The model browser (parsed out of `copilot help config`) still lists them all, because availability is the backend's per-plan call and an unavailable favorite fails per turn with that same readable error, so a plan upgrade needs no code change.
- **copilot: the system prompt travels as `AGENTS.md` in the child's cwd**, one directory per prompt content. There is no `--system-prompt` flag, and `COPILOT_CUSTOM_INSTRUCTIONS_DIRS` looked right but never reached the model (measured with a marker instruction). Copilot's own prompt cannot be shed, so lean mode appends to it rather than replacing it. The question goes on stdin, plain text, no `-p`: `-p` would put it in argv.
- **copilot: `--available-tools=none` is the tool kill switch; a bare `--available-tools=` filters nothing** (measured: all 18 tools stayed visible). With tools filtered the model can still hallucinate a fake tool transcript if the question asks it to run something; nothing executes (no `tool.execution_start` events). Without any allow flags, a real tool call is denied and the turn continues, same as claude, despite the help claiming `--allow-all-tools` is "required for non-interactive mode".
- OpenRouter free tier is the model `openrouter/free`, a router over free models. Not `openrouter/auto-beta`, which can route to paid. Limits are about 50 requests a day under a $10 lifetime balance, about 1000 above it.

## Taste

- Keyboard first. Every action has a binding, ⌘/ lists them, and the mouse is the alternative rather than the path.
- The model selector shows favorites only. A list of 300 models is a menu nobody reads.
- Reasoning is progress, not content: shown while the answer has not started, dropped the moment text arrives, never saved.
- Colors come from `colorScheme`, sizes from `AppSettings.answerFontSize`. Visual choices live in the code with a comment saying why, not in this file.
- Comments explain why, especially where the obvious approach is wrong. A mistake that cost hours belongs here in Traps instead.
- If a rule here fights the task in front of you, say so and get Santi's sign-off before breaking it.

## Additional tips

- **Known debt: API keys live in UserDefaults, a plaintext plist.** The right fix is Keychain with a migration, parked deliberately: with ad-hoc signing every rebuild changes the code signature, so Keychain would re-prompt anyone building from source on every update. A stable signing certificate fixes this and the Local Network grant at once. Do not "fix" it casually.
- ATS declares `NSAllowsLocalNetworking` only (plain http to local-network hostnames; numeric-IP URLs are exempt anyway). Never widen it to `NSAllowsArbitraryLoads`.
- Never commit keys, and keep personal environment details such as LAN addresses out of tracked files. They belong in `.agent/`.
- MIT licensed. The README is the public face: main selling points, not a feature list.
- Parked until the project has users, both copied from pingdotgg/t3code: structured issue templates with blank issues disabled (a bug report must carry the macOS version, the build timestamp from the status-bar menu, and the active provider, because a report without those three is unanswerable), and the vouch workflow that labels an external PR with a trust status (`vouch:*`) from a checked-in list. Neither earns its keep at zero contributors; revisit at the first stranger's bug report and the first stranger's PR respectively.
