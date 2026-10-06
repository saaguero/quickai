#!/bin/bash
# Exercise the harness providers end to end: binary detection under a
# Finder-like environment, the streaming protocol, session reuse, and teardown.
#
# Run it after touching HarnessDetector, ProcessRunner, OpenCodeServer,
# OpenCodeClient, ClaudeCodeClient, CopilotClient or AntigravityClient. It
# spends a few tokens on each harness, never touches the user's conversation
# store, and skips whichever CLI is not installed.
#
# The two checks that matter most:
#
# - OpenCode, "reasoning stays out of the answer": opencode labels reasoning
#   deltas with field "text" just like real answer text, so a filter that trusts
#   `field` still compiles, still answers, and silently prints the model's
#   thinking into every reply.
# - Claude Code, "answers with a stray API key in the environment": the whole
#   point of a harness is that the subscription pays, so the child's environment
#   is scrubbed and the CLI's own `apiKeySource` is asserted before streaming.
#   The section runs with a bogus ANTHROPIC_API_KEY exported on purpose.
#
# HARNESS_TEST_MODEL overrides the auto-picked free opencode model.
# CLAUDE_TEST_MODEL overrides the claude model (default: haiku).
# COPILOT_TEST_MODEL overrides the copilot model (default: auto, the only value
# some plans accept).
# ANTIGRAVITY_TEST_MODEL overrides the agy model (default: the first "flash-low"
# in `agy models`).
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SOURCES=(
    Sources/QuickAI/ProcessRunner.swift
    Sources/QuickAI/HarnessDetector.swift
    Sources/QuickAI/OpenCodeServer.swift
    Sources/QuickAI/OpenCodeClient.swift
    Sources/QuickAI/ClaudeCodeClient.swift
    Sources/QuickAI/CopilotClient.swift
    Sources/QuickAI/AntigravityClient.swift
    Sources/QuickAI/ModelCatalog.swift
    Sources/QuickAI/ChatClient.swift
    Sources/QuickAI/Models.swift
)

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

@main
struct HarnessTest {
    static var failures = 0

    static func check(_ label: String, _ condition: Bool, _ detail: String = "") {
        if !condition { failures += 1 }
        let suffix = detail.isEmpty || condition ? "" : "  (\(detail))"
        print("\(condition ? "ok  " : "FAIL") \(label)\(suffix)")
    }

    static func skip(_ label: String, _ why: String) {
        print("skip \(label)  (\(why))")
    }

    /// Collapses whitespace so a comparison is not defeated by re-wrapping.
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    static func main() async {
        switch CommandLine.arguments.dropFirst().first ?? "opencode" {
        case "detect": await detect(.opencode)
        case "claude-detect": await detect(.claudeCode)
        case "claude": await claudeChecks()
        case "copilot-detect": await detect(.copilot)
        case "copilot": await copilotChecks()
        case "antigravity-detect": await detect(.antigravity)
        case "antigravity": await antigravityChecks()
        default: await opencodeChecks()
        }
    }

    static func detect(_ kind: HarnessKind) async {
        guard let install = HarnessDetector.detect(kind) else {
            print("FAIL \(kind.executableName) binary not found")
            exit(1)
        }
        print("ok   detected \(install.version) at \(install.path)")
        exit(0)
    }

    // MARK: - OpenCode

    static func opencodeChecks() async {
        guard let install = HarnessDetector.detect(.opencode) else {
            print("FAIL opencode binary not found")
            exit(1)
        }
        defer { print(failures == 0 ? "all good" : "\(failures) failed") }

        var models: [ModelInfo] = []
        do {
            models = try await ModelCatalog.fetchOpenCode(install: install)
        } catch {
            check("model catalog loads", false, error.localizedDescription)
            await OpenCodeServer.shared.stop()
            exit(1)
        }
        check("model catalog loads", !models.isEmpty, "no models returned")

        // Prefer OpenCode Zen's free tier: it needs no extra provider and, unlike
        // a locally configured provider, does not depend on a LAN box being up.
        let override = ProcessInfo.processInfo.environment["HARNESS_TEST_MODEL"]
        let free = models.first { $0.id.hasPrefix("opencode/") && $0.id.contains("free") }
            ?? models.first { $0.id.contains("free") }
        guard let model = override ?? free?.id else {
            skip("streaming checks", "no free model available; set HARNESS_TEST_MODEL")
            await OpenCodeServer.shared.stop()
            exit(failures == 0 ? 0 : 1)
        }
        print("---- using \(model) ----")

        // MARK: one turn, watching the two channels
        let conversation = "harness-test-\(UUID().uuidString)"
        let question = "In one short sentence, what is the capital of France?"
        var answer = ""
        var reasoning = ""
        do {
            for try await chunk in OpenCodeClient.stream(
                install: install,
                model: model,
                systemPrompt: "You are a concise assistant. Answer directly.",
                disableTools: true,
                conversationId: conversation,
                messages: [Message(role: .user, content: question)]
            ) {
                switch chunk {
                case .text(let piece): answer += piece
                case .reasoning(let piece): reasoning += piece
                }
            }
        } catch {
            check("first turn streams", false, error.localizedDescription)
            await OpenCodeServer.shared.stop()
            exit(1)
        }

        check("first turn streams an answer", !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        // The user's own prompt comes back as a text part on the user message.
        // Yielding it would echo the question above every reply.
        check(
            "the question is not echoed into the answer",
            !normalized(answer).contains(normalized(question)),
            "answer starts: \(answer.prefix(60))"
        )

        // The regression this script exists for, checked from both sides.
        //
        // Asserting only "the reasoning is absent from the answer" is not
        // enough: when the routing collapses and every delta is yielded as
        // .text, the reasoning channel goes empty and there is nothing left to
        // compare against, so that check silently passes. Requiring the channel
        // to receive something is what actually catches it.
        let trimmedReasoning = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        check(
            "reasoning reaches its own channel",
            !trimmedReasoning.isEmpty,
            "nothing arrived as .reasoning: either the part-type routing regressed "
                + "and everything is going to .text, or this model does not think. "
                + "Re-run with HARNESS_TEST_MODEL set to a reasoning model to tell them apart"
        )
        if trimmedReasoning.count >= 20 {
            let fingerprint = String(normalized(trimmedReasoning).prefix(40))
            check(
                "reasoning stays out of the answer",
                !normalized(answer).contains(fingerprint),
                "reasoning leaked: \(trimmedReasoning.prefix(60))"
            )
        }

        // MARK: follow-up, which only works if the session was reused
        let token = "4471"
        var second = ""
        do {
            _ = try await collectOpenCode(
                install: install, model: model, conversation: conversation,
                question: "Remember the number \(token). Reply with just: OK"
            )
            second = try await collectOpenCode(
                install: install, model: model, conversation: conversation,
                question: "What number did I ask you to remember? Reply with the digits only."
            )
        } catch {
            check("follow-up streams", false, error.localizedDescription)
        }
        check(
            "context survives across turns (session reuse)",
            second.contains(token),
            "expected \(token), got: \(second.prefix(60))"
        )

        await OpenCodeServer.shared.stop()
        exit(failures == 0 ? 0 : 1)
    }

    static func collectOpenCode(
        install: HarnessInstall, model: String, conversation: String, question: String
    ) async throws -> String {
        var text = ""
        for try await chunk in OpenCodeClient.stream(
            install: install,
            model: model,
            systemPrompt: "You are a concise assistant. Answer directly.",
            disableTools: true,
            conversationId: conversation,
            messages: [Message(role: .user, content: question)]
        ) {
            if case .text(let piece) = chunk { text += piece }
        }
        return text
    }

    // MARK: - Claude Code

    static func claudeChecks() async {
        guard let install = HarnessDetector.detect(.claudeCode) else {
            print("FAIL claude binary not found")
            exit(1)
        }
        defer { print(failures == 0 ? "all good" : "\(failures) failed") }

        let model = ProcessInfo.processInfo.environment["CLAUDE_TEST_MODEL"] ?? "haiku"
        let strayKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
        print("---- using \(model), stray ANTHROPIC_API_KEY in the environment: \(strayKey.isEmpty ? "no" : "yes") ----")

        let conversation = "harness-test-\(UUID().uuidString)"
        let token = "4471"
        let question = "Remember the number \(token). Reply with just: OK"
        var answer = ""
        do {
            answer = try await collectClaude(
                install: install, model: model, conversation: conversation, question: question
            )
        } catch {
            // The guard fires here when the environment scrub regresses: the
            // CLI reports a metered key source and nothing is sent.
            check("first turn streams", false, error.localizedDescription)
            exit(1)
        }

        check(
            "answers with a stray ANTHROPIC_API_KEY in the environment",
            !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "the subscription guard or the environment scrub regressed"
        )
        check(
            "the question is not echoed into the answer",
            !normalized(answer).contains(normalized(question)),
            "answer starts: \(answer.prefix(60))"
        )

        var second = ""
        do {
            second = try await collectClaude(
                install: install, model: model, conversation: conversation,
                question: "What number did I ask you to remember? Reply with the digits only."
            )
        } catch {
            check("follow-up streams", false, error.localizedDescription)
        }
        check(
            "context survives across turns (--session-id then --resume)",
            second.contains(token),
            "expected \(token), got: \(second.prefix(60))"
        )

        // A conversation title is a throwaway call and must not land in the
        // user's Claude Code session history.
        let before = claudeSessionFileCount()
        do {
            var text = ""
            for try await chunk in ClaudeCodeClient.stream(
                install: install, model: model,
                systemPrompt: "Answer with the requested text only.",
                lean: true,
                conversationId: "title-\(UUID().uuidString)",
                messages: [Message(role: .user, content: "Reply with just: OK")],
                ephemeral: true
            ) {
                if case .text(let piece) = chunk { text += piece }
            }
            check("an ephemeral call still answers", !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } catch {
            check("an ephemeral call still answers", false, error.localizedDescription)
        }
        let after = claudeSessionFileCount()
        check(
            "an ephemeral call writes no session file",
            after == before,
            "session files in QuickAI's workspace went from \(before) to \(after)"
        )

        exit(failures == 0 ? 0 : 1)
    }

    static func collectClaude(
        install: HarnessInstall, model: String, conversation: String, question: String
    ) async throws -> String {
        var text = ""
        for try await chunk in ClaudeCodeClient.stream(
            install: install,
            model: model,
            systemPrompt: "You are a concise assistant. Answer directly.",
            lean: true,
            conversationId: conversation,
            messages: [Message(role: .user, content: question)]
        ) {
            if case .text(let piece) = chunk { text += piece }
        }
        return text
    }

    // MARK: - Copilot

    static func copilotChecks() async {
        guard let install = HarnessDetector.detect(.copilot) else {
            print("FAIL copilot binary not found")
            exit(1)
        }
        defer { print(failures == 0 ? "all good" : "\(failures) failed") }

        let model = ProcessInfo.processInfo.environment["COPILOT_TEST_MODEL"] ?? "auto"
        let byok = ProcessInfo.processInfo.environment["COPILOT_PROVIDER_BASE_URL"] ?? ""
        print("---- using \(model), stray COPILOT_PROVIDER_BASE_URL in the environment: \(byok.isEmpty ? "no" : "yes") ----")

        let catalog = await ModelCatalog.fetchCopilot(install: install)
        check(
            "model catalog parses out of `copilot help config`",
            catalog.count > 1 && catalog.first?.id == "auto",
            "got \(catalog.count) entries"
        )

        let conversation = "harness-test-\(UUID().uuidString)"
        let token = "4471"
        let question = "Remember the number \(token). Reply with just: OK"
        var answer = ""
        do {
            answer = try await collectCopilot(
                install: install, model: model, conversation: conversation, question: question
            )
        } catch {
            // This fires when the BYOK scrub regresses: the stray provider
            // variables point at a dead endpoint, so the turn cannot succeed
            // unless the child's environment was cleaned.
            check("first turn streams", false, error.localizedDescription)
            exit(1)
        }

        check(
            "answers with stray COPILOT_PROVIDER_* variables in the environment",
            !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "the BYOK environment scrub regressed"
        )
        check(
            "the question is not echoed into the answer",
            !normalized(answer).contains(normalized(question)),
            "answer starts: \(answer.prefix(60))"
        )

        var second = ""
        do {
            second = try await collectCopilot(
                install: install, model: model, conversation: conversation,
                question: "What number did I ask you to remember? Reply with the digits only."
            )
        } catch {
            check("follow-up streams", false, error.localizedDescription)
        }
        check(
            "context survives across turns (--session-id then --resume)",
            second.contains(token),
            "expected \(token), got: \(second.prefix(60))"
        )

        // A rejected model must surface the CLI's own message. The panel once
        // showed the generic "ended without a result event" fallback instead,
        // because stderr was snapshotted before the exiting child had written
        // it. Costs nothing: validation happens before any model call.
        do {
            _ = try await collectCopilot(
                install: install, model: "quickai-test-nonexistent-model",
                conversation: "harness-test-\(UUID().uuidString)",
                question: "Reply with just: OK"
            )
            check("a rejected model surfaces the CLI's error", false, "the turn unexpectedly succeeded")
        } catch {
            let message = error.localizedDescription
            check(
                "a rejected model surfaces the CLI's error",
                message.contains("is not available"),
                "got: \(message.prefix(90))"
            )
        }

        // A conversation title is a throwaway call; it must answer, and the
        // shell wrapper asserts around this whole section that nothing landed
        // in the user's own ~/.copilot.
        do {
            var text = ""
            for try await chunk in CopilotClient.stream(
                install: install, model: model,
                systemPrompt: "Answer with the requested text only.",
                lean: true,
                conversationId: "title-\(UUID().uuidString)",
                messages: [Message(role: .user, content: "Reply with just: OK")],
                ephemeral: true
            ) {
                if case .text(let piece) = chunk { text += piece }
            }
            check("an ephemeral call still answers", !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } catch {
            check("an ephemeral call still answers", false, error.localizedDescription)
        }

        exit(failures == 0 ? 0 : 1)
    }

    static func collectCopilot(
        install: HarnessInstall, model: String, conversation: String, question: String
    ) async throws -> String {
        var text = ""
        for try await chunk in CopilotClient.stream(
            install: install,
            model: model,
            systemPrompt: "You are a concise assistant. Answer directly.",
            lean: true,
            conversationId: conversation,
            messages: [Message(role: .user, content: question)]
        ) {
            if case .text(let piece) = chunk { text += piece }
        }
        return text
    }

    // MARK: - Antigravity

    static func antigravityChecks() async {
        guard let install = HarnessDetector.detect(.antigravity) else {
            print("FAIL agy binary not found")
            exit(1)
        }
        defer { print(failures == 0 ? "all good" : "\(failures) failed") }

        var catalog: [ModelInfo] = []
        do {
            catalog = try await ModelCatalog.fetchAntigravity(install: install)
        } catch {
            check("model catalog loads from `agy models`", false, error.localizedDescription)
            exit(1)
        }
        check("model catalog loads from `agy models`", !catalog.isEmpty, "no models listed")

        let override = ProcessInfo.processInfo.environment["ANTIGRAVITY_TEST_MODEL"]
        guard let model = override ?? catalog.first(where: { $0.id.contains("flash-low") })?.id ?? catalog.first?.id else {
            skip("streaming checks", "no model available; set ANTIGRAVITY_TEST_MODEL")
            exit(failures == 0 ? 0 : 1)
        }
        let other = catalog.first { $0.id != model && $0.id.contains("flash") }?.id
        print("---- using \(model), stray AGY_ADC_AUTH in the environment: \(ProcessInfo.processInfo.environment["AGY_ADC_AUTH"] == nil ? "no" : "yes") ----")

        // The second billing layer: the private home must shed a
        // `modelProvider` setting (the metered Gemini API route) and keep paid
        // AI credits off, whatever was left in it.
        let settingsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuickAI/antigravity-home/.gemini/antigravity-cli/settings.json")
        try? FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? Data(#"{"modelProvider":"gemini","useG1Credits":true}"#.utf8).write(to: settingsURL)

        // The first question should land on the spare the panel starts when it
        // opens, not pay agy's ~5s of startup (measured cold: ~8s to first token).
        AntigravityClient.prewarm(install: install, model: model, systemPrompt: system, lean: true)
        try? await Task.sleep(nanoseconds: 12_000_000_000)

        let conversation = "harness-test-\(UUID().uuidString)"
        let token = "5183"
        let question = "Remember the number \(token). Reply with just: OK"
        var answer = ""
        var firstToken = 0.0
        do {
            (answer, firstToken) = try await collectAntigravity(
                install: install, model: model, conversation: conversation, messages: [question]
            )
        } catch {
            // Fires when the scrub regresses (AGY_ADC_AUTH switches agy off the
            // Google login), or when the subscription check refuses the child.
            check("first turn streams", false, error.localizedDescription)
            exit(1)
        }
        check(
            "answers with stray AGY_ADC_AUTH / GEMINI_API_KEY in the environment",
            !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "the environment scrub regressed"
        )
        check(
            "the question is not echoed into the answer",
            !normalized(answer).contains(normalized(question)),
            "answer starts: \(answer.prefix(60))"
        )
        check(
            "a pre-warmed first question skips agy's startup",
            firstToken < 6,
            String(format: "first token after %.1fs", firstToken)
        )

        let settings = (try? Data(contentsOf: settingsURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        check(
            "the private home drops modelProvider and keeps AI credits off",
            // agy itself saves `false` by dropping the key
            settings["modelProvider"] == nil && (settings["useG1Credits"] as? Bool ?? false) == false,
            "settings.json: \(settings)"
        )

        let recall = "What number did I ask you to remember? Reply with the digits only."
        var second = ""
        do {
            (second, firstToken) = try await collectAntigravity(
                install: install, model: model, conversation: conversation, messages: [question, answer, recall]
            )
        } catch {
            check("follow-up streams", false, error.localizedDescription)
        }
        check(
            "context survives in the live child",
            second.contains(token),
            "expected \(token), got: \(second.prefix(60))"
        )
        check(
            "a follow-up reuses the live child",
            firstToken < 6,
            String(format: "first token after %.1fs", firstToken)
        )

        // A model switch cannot reuse the child (its model is fixed), so the
        // next one picks the conversation up with --conversation.
        if let other {
            var third = ""
            do {
                (third, _) = try await collectAntigravity(
                    install: install, model: other, conversation: conversation,
                    messages: [question, answer, recall, second, recall]
                )
            } catch {
                check("a model switch keeps the conversation (--conversation)", false, error.localizedDescription)
            }
            check(
                "a model switch keeps the conversation (--conversation)",
                third.contains(token),
                "expected \(token), got: \(third.prefix(60))"
            )
        } else {
            skip("a model switch keeps the conversation", "only one flash model listed")
        }

        // ⎋ mid-answer kills the child; the next turn must still have the
        // conversation, through a resumed child.
        do {
            let stream = AntigravityClient.stream(
                install: install, model: model, systemPrompt: system, lean: true,
                conversationId: conversation,
                messages: [Message(role: .user, content: "Write a 300-word story about a lighthouse.")]
            )
            for try await chunk in stream {
                if case .text = chunk { break }
            }
        } catch {}
        var afterStop = ""
        do {
            (afterStop, _) = try await collectAntigravity(
                install: install, model: model, conversation: conversation,
                messages: [question, answer, recall]
            )
        } catch {
            check("a stopped turn leaves the conversation usable", false, error.localizedDescription)
        }
        check(
            "a stopped turn leaves the conversation usable",
            afterStop.contains(token),
            "expected \(token), got: \(afterStop.prefix(60))"
        )

        // Costs nothing: agy rejects the model before any model call.
        do {
            _ = try await collectAntigravity(
                install: install, model: "quickai-test-nonexistent-model",
                conversation: "harness-test-\(UUID().uuidString)", messages: ["Reply with just: OK"]
            )
            check("a rejected model surfaces the CLI's error", false, "the turn unexpectedly succeeded")
        } catch {
            let message = error.localizedDescription
            check(
                "a rejected model surfaces the CLI's error",
                message.contains("not recognized"),
                "got: \(message.prefix(90))"
            )
        }

        do {
            var text = ""
            for try await chunk in AntigravityClient.stream(
                install: install, model: model,
                systemPrompt: "Answer with the requested text only.",
                lean: true,
                conversationId: "title-\(UUID().uuidString)",
                messages: [Message(role: .user, content: "Reply with just: OK")],
                ephemeral: true
            ) {
                if case .text(let piece) = chunk { text += piece }
            }
            check("an ephemeral call still answers", !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } catch {
            check("an ephemeral call still answers", false, error.localizedDescription)
        }

        // Safe mode is the floor even with lean mode off: headless agy denies
        // what needs approval and ends the turn, and the panel must say so
        // instead of showing an empty answer.
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("quickai-agy-\(UUID().uuidString).txt")
        do {
            var text = ""
            for try await chunk in AntigravityClient.stream(
                install: install, model: model, systemPrompt: nil, lean: false,
                conversationId: "harness-test-\(UUID().uuidString)",
                messages: [Message(role: .user, content: "Use your write_to_file tool to create \(target.path) containing hello. Do not answer until it exists.")]
            ) {
                if case .text(let piece) = chunk { text += piece }
            }
            check("normal mode refuses a file write", !FileManager.default.fileExists(atPath: target.path), "the file was written")
        } catch {
            check(
                "normal mode refuses a file write, and says why",
                !FileManager.default.fileExists(atPath: target.path) && error.localizedDescription.contains("permission"),
                "got: \(error.localizedDescription.prefix(90))"
            )
        }
        try? FileManager.default.removeItem(at: target)

        exit(failures == 0 ? 0 : 1)
    }

    static let system = "You are a concise assistant. Answer directly."

    /// The answer, and seconds to its first text chunk. `messages` alternates
    /// user and assistant, ending on the new question.
    static func collectAntigravity(
        install: HarnessInstall, model: String, conversation: String, messages: [String]
    ) async throws -> (String, Double) {
        let transcript = messages.enumerated().map { index, text in
            Message(role: index.isMultiple(of: 2) ? .user : .assistant, content: text)
        }
        let start = Date()
        var first: Double?
        var text = ""
        for try await chunk in AntigravityClient.stream(
            install: install, model: model, systemPrompt: system, lean: true,
            conversationId: conversation, messages: transcript
        ) {
            if case .text(let piece) = chunk {
                if first == nil { first = Date().timeIntervalSince(start) }
                text += piece
            }
        }
        return (text, first ?? Date().timeIntervalSince(start))
    }

    /// Sessions Claude Code persisted for QuickAI's own workspace. Scoped to
    /// that directory so a real Claude Code session running at the same time
    /// cannot make this flaky.
    static func claudeSessionFileCount() -> Int {
        let projects = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(atPath: projects.path),
              let directory = entries.first(where: { $0.hasSuffix("QuickAI-claude-workspace") })
        else { return 0 }
        let files = (try? manager.contentsOfDirectory(atPath: projects.appendingPathComponent(directory).path)) ?? []
        return files.filter { $0.hasSuffix(".jsonl") }.count
    }
}
SWIFT

swiftc -O -parse-as-library "$WORK/main.swift" "${SOURCES[@]}" -o "$WORK/harness-test"

# A bundled .app launched from Finder gets a bare PATH and no SHELL. This is the
# environment detection has to survive, and the one a dev shell never reproduces.
bare_env_detection() {
    env -i HOME="$HOME" USER="${USER:-}" PATH=/usr/bin:/bin:/usr/sbin:/sbin "$WORK/harness-test" "$1"
}

# Processes matching $1 that were not already running before the test ($2),
# waited on for a few seconds first.
#
# A child that was aborted takes about a second to shut down (measured: 0.9s
# after SIGTERM), so a fixed one-second sleep reports a graceful exit as a leak.
leftover_pids() {
    local pattern="$1" before="$2" now leaked
    local deadline=$((SECONDS + 10))
    while :; do
        now=$(pgrep -f "$pattern" 2>/dev/null | sort || true)
        leaked=$(comm -13 <(echo "$before") <(echo "$now") | tr -d '[:space:]')
        if [ -z "$leaked" ] || [ $SECONDS -ge $deadline ]; then
            echo "$leaked"
            return
        fi
        sleep 0.5
    done
}

status=0

# ---------------------------------------------------------------- OpenCode
if "$WORK/harness-test" detect >/dev/null 2>&1; then
    echo "==== OpenCode ===="
    echo "---- detection under a Finder-like environment ----"
    if ! bare_env_detection detect; then
        echo "FAIL detection fails without a shell PATH (a bundled .app would not find opencode)"
        exit 1
    fi

    # Only servers started by this run may be left behind, so compare against
    # the ones already running (the user may have their own opencode open).
    before=$(pgrep -f "opencode serve" 2>/dev/null | sort || true)

    echo "---- streaming, separation of channels, session reuse ----"
    "$WORK/harness-test" opencode || status=$?

    leaked=$(leftover_pids "opencode serve" "$before")
    if [ -n "$leaked" ]; then
        echo "FAIL the test left an opencode server running (pids: $leaked)"
        status=1
    else
        echo "ok   no opencode server left behind"
    fi
else
    echo "skip  opencode is not installed (brew install opencode, then: opencode auth login)"
fi

# ------------------------------------------------------------- Claude Code
if "$WORK/harness-test" claude-detect >/dev/null 2>&1; then
    echo
    echo "==== Claude Code ===="
    echo "---- detection under a Finder-like environment ----"
    if ! bare_env_detection claude-detect; then
        echo "FAIL detection fails without a shell PATH (a bundled .app would not find claude)"
        exit 1
    fi

    # Proof that the section below has teeth. If the CLI reported "none" even
    # with a key in the environment, "QuickAI scrubs the key" would be an
    # assertion about nothing, which is exactly how the phase 1 reasoning check
    # passed while the bug was live.
    echo "---- the API-key scrub has something to scrub ----"
    unscrubbed=$(printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"}}' \
        | ANTHROPIC_API_KEY=sk-ant-quickai-harness-test-invalid timeout 60 claude \
            --output-format stream-json --verbose --input-format stream-json \
            --tools "" --restricted --safe-mode --no-session-persistence 2>/dev/null \
        | grep -m1 -o '"apiKeySource":"[^"]*"' || true)
    if [ "$unscrubbed" = '"apiKeySource":"none"' ] || [ -z "$unscrubbed" ]; then
        echo "FAIL claude reported ${unscrubbed:-nothing} with ANTHROPIC_API_KEY set, so the next check proves nothing"
        status=1
    else
        echo "ok   claude reports ${unscrubbed} when the key is left in place"
    fi

    before=$(pgrep -f "claude --output-format stream-json" 2>/dev/null | sort || true)

    echo "---- streaming, subscription guard, session reuse ----"
    # The bogus key is deliberate: the client must strip it from the child's
    # environment, and the answer below is the proof that it did.
    ANTHROPIC_API_KEY=sk-ant-quickai-harness-test-invalid "$WORK/harness-test" claude || status=$?

    leaked=$(leftover_pids "claude --output-format stream-json" "$before")
    if [ -n "$leaked" ]; then
        echo "FAIL the test left a claude process running (pids: $leaked)"
        status=1
    else
        echo "ok   no claude process left behind"
    fi
else
    echo
    echo "skip  claude is not installed (install Claude Code, then: claude auth login)"
fi

# ----------------------------------------------------------- GitHub Copilot
if "$WORK/harness-test" copilot-detect >/dev/null 2>&1; then
    echo
    echo "==== GitHub Copilot ===="
    echo "---- detection under a Finder-like environment ----"
    if ! bare_env_detection copilot-detect; then
        echo "FAIL detection fails without a shell PATH (a bundled .app would not find copilot)"
        exit 1
    fi

    # Proof that the section below has teeth: with the BYOK variables in place,
    # copilot routes to that provider instead of the subscription, so a dead
    # endpoint must sink the turn. If it answered anyway, "QuickAI scrubs the
    # BYOK variables" would be an assertion about nothing.
    echo "---- the BYOK scrub has something to scrub ----"
    if printf 'hi' | COPILOT_HOME="$WORK/copilot-byok-home" \
        COPILOT_PROVIDER_BASE_URL=http://127.0.0.1:1/v1 COPILOT_PROVIDER_API_KEY=bogus COPILOT_MODEL=test-model \
        timeout 90 copilot --output-format json --no-auto-update >/dev/null 2>&1; then
        echo "FAIL copilot answered with a dead BYOK endpoint configured, so the next check proves nothing"
        status=1
    else
        echo "ok   copilot fails against the dead BYOK endpoint when the variables are left in place"
    fi

    # Nothing QuickAI does may land in the user's own ~/.copilot: sessions go
    # to a private COPILOT_HOME, including the throwaway title calls.
    user_sessions_before=$(ls "$HOME/.copilot/session-state" 2>/dev/null | wc -l)

    before=$(pgrep -f "copilot --output-format json" 2>/dev/null | sort || true)

    echo "---- streaming, BYOK scrub, session reuse ----"
    # The dead endpoint is deliberate: the client must strip COPILOT_PROVIDER_*
    # from the child's environment, and the answer below is the proof that it did.
    COPILOT_PROVIDER_BASE_URL=http://127.0.0.1:1/v1 COPILOT_PROVIDER_API_KEY=bogus COPILOT_MODEL=test-model \
        "$WORK/harness-test" copilot || status=$?

    user_sessions_after=$(ls "$HOME/.copilot/session-state" 2>/dev/null | wc -l)
    if [ "$user_sessions_after" -ne "$user_sessions_before" ]; then
        echo "FAIL the test wrote into the user's ~/.copilot/session-state ($user_sessions_before -> $user_sessions_after)"
        status=1
    else
        echo "ok   the user's own ~/.copilot was not touched"
    fi

    leaked=$(leftover_pids "copilot --output-format json" "$before")
    if [ -n "$leaked" ]; then
        echo "FAIL the test left a copilot process running (pids: $leaked)"
        status=1
    else
        echo "ok   no copilot process left behind"
    fi
else
    echo
    echo "skip  copilot is not installed (brew install copilot-cli, then: copilot login)"
fi

# ------------------------------------------------------------- Antigravity
if "$WORK/harness-test" antigravity-detect >/dev/null 2>&1; then
    echo
    echo "==== Antigravity ===="
    echo "---- detection under a Finder-like environment ----"
    if ! bare_env_detection antigravity-detect; then
        echo "FAIL detection fails without a shell PATH (a bundled .app would not find agy)"
        exit 1
    fi

    # Proof that the section below has teeth, in a throwaway home with the
    # Keychain linked in (the same shape QuickAI builds): left in place,
    # AGY_ADC_AUTH takes agy off the Google login, and GEMINI_API_KEY plus a
    # modelProvider setting reroutes it to the metered API, which agy logs as
    # an authMethod the client refuses.
    echo "---- the billing scrub has something to scrub ----"
    teeth_home="$WORK/agy-teeth-home"
    mkdir -p "$teeth_home/Library" "$teeth_home/.gemini/antigravity-cli" "$WORK/agy-teeth-ws"
    ln -s "$HOME/Library/Keychains" "$teeth_home/Library/Keychains"
    adc_init=$( (cd "$WORK/agy-teeth-ws" && printf '' | HOME="$teeth_home" AGY_ADC_AUTH=1 \
        timeout 60 agy --input-format stream-json --output-format stream-json \
            --log-file "$WORK/agy-teeth-adc.log" 2>/dev/null) | grep -c '"event":"init"' || true)
    if [ "$adc_init" != "0" ]; then
        echo "FAIL agy still started a session with AGY_ADC_AUTH set, so the next check proves nothing"
        status=1
    else
        echo "ok   agy abandons the Google login when AGY_ADC_AUTH is left in place"
    fi
    echo '{"modelProvider":"gemini"}' > "$teeth_home/.gemini/antigravity-cli/settings.json"
    (cd "$WORK/agy-teeth-ws" && printf '' | HOME="$teeth_home" GEMINI_API_KEY=quickai-harness-test-invalid \
        timeout 60 agy --input-format stream-json --output-format stream-json \
            --log-file "$WORK/agy-teeth-key.log" >/dev/null 2>&1) || true
    key_method=$(grep -o 'authMethod=[^, ]*' "$WORK/agy-teeth-key.log" 2>/dev/null | head -1 || true)
    if [ -z "$key_method" ] || [ "$key_method" = "authMethod=consumer" ]; then
        echo "FAIL agy logged ${key_method:-no authMethod} with an API key configured, so the subscription check proves nothing"
        status=1
    else
        echo "ok   agy logs ${key_method} when the API-key route is left in place"
    fi

    # Nothing QuickAI does may land in the user's own ~/.gemini: conversations
    # go to a private HOME, including the throwaway title calls.
    user_conversations_before=$(ls "$HOME/.gemini/antigravity-cli/conversations" 2>/dev/null | wc -l)

    before=$(pgrep -f "agy --input-format stream-json" 2>/dev/null | sort || true)

    echo "---- streaming, billing guard, warm children, session reuse ----"
    # The poison is deliberate: the client must strip it from the child's
    # environment, and the answer below is the proof that it did.
    AGY_ADC_AUTH=1 GEMINI_API_KEY=quickai-harness-test-invalid GOOGLE_GEMINI_BASE_URL=http://127.0.0.1:1 \
        "$WORK/harness-test" antigravity || status=$?

    user_conversations_after=$(ls "$HOME/.gemini/antigravity-cli/conversations" 2>/dev/null | wc -l)
    if [ "$user_conversations_after" -ne "$user_conversations_before" ]; then
        echo "FAIL the test wrote into the user's ~/.gemini ($user_conversations_before -> $user_conversations_after conversations)"
        status=1
    else
        echo "ok   the user's own ~/.gemini was not touched"
    fi

    # The warm children were still up when the test binary exited: closing
    # their stdin is the only teardown they get, so this is the check for it.
    leaked=$(leftover_pids "agy --input-format stream-json" "$before")
    if [ -n "$leaked" ]; then
        echo "FAIL the test left an agy process running (pids: $leaked)"
        status=1
    else
        echo "ok   no agy process left behind"
    fi

    # Every child writes a log with sign-in details; each path that ends a
    # child (a spare expiring, a failure before init, a stopped turn) must
    # delete it.
    logs=$(find "$HOME/Library/Application Support/QuickAI/antigravity-logs" -name '*.log' 2>/dev/null | wc -l | tr -d ' ' || true)
    if [ "$logs" -ne 0 ]; then
        echo "FAIL the test left $logs agy log(s) in Application Support"
        status=1
    else
        echo "ok   no agy log left behind"
    fi
else
    echo
    echo "skip  agy is not installed (install the Antigravity CLI, then run agy once to sign in)"
fi

exit $status
