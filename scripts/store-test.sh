#!/bin/bash
# Exercise ConversationStore's destructive paths (delete, delete all, restore,
# 30-day purge, empty) in a throwaway directory.
#
# ConversationStore(directory:) exists for exactly this: a store built with the
# default initializer writes to ~/Library/Application Support/QuickAI, and this
# test calls emptyTrash(). Running it against the default path once wiped a real
# conversation history. Always pass a temp directory.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

@main
struct StoreTest {
    static var failures = 0

    static func check(_ label: String, _ condition: Bool) {
        if !condition { failures += 1 }
        print("\(condition ? "ok  " : "FAIL") \(label)")
    }

    static func main() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quickai-store-test-\(UUID().uuidString)", isDirectory: true)
        let store = ConversationStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        func make(_ title: String) -> Conversation {
            var conversation = Conversation.fresh(providerId: "openrouter")
            conversation.title = title
            conversation.messages = [
                Message(role: .user, content: "question for \(title)"),
                Message(role: .assistant, content: "answer for \(title)"),
            ]
            return conversation
        }
        let alpha = make("alpha"), beta = make("beta"), gamma = make("gamma")
        for conversation in [alpha, beta, gamma] { store.upsert(conversation) }
        check("three stored", store.load().count == 3)

        store.delete(id: beta.id)
        check("delete leaves two", store.load().count == 2)
        check("delete fills the bin", store.loadTrash().count == 1)
        check("bin keeps the title", store.loadTrash().first?.conversation.title == "beta")
        check("bin keeps both messages", store.loadTrash().first?.conversation.messages.count == 2)

        store.restore(id: beta.id)
        check("restore brings it back", store.load().count == 3)
        check("restore empties the bin", store.loadTrash().isEmpty)

        check("deleteAll reports the count", store.deleteAll() == 3)
        check("deleteAll leaves nothing", store.load().isEmpty)
        check("deleteAll fills the bin", store.loadTrash().count == 3)

        store.restore(id: alpha.id)
        store.delete(id: alpha.id)
        check("no duplicates in the bin", store.loadTrash().filter { $0.id == alpha.id }.count == 1)

        let trashURL = directory.appendingPathComponent("trash.json")
        var raw = try! JSONDecoder().decode([TrashedConversation].self, from: Data(contentsOf: trashURL))
        raw[0].deletedAt = Date().addingTimeInterval(-Double(ConversationStore.trashRetentionDays + 1) * 86_400)
        let expired = raw[0].id
        try! JSONEncoder().encode(raw).write(to: trashURL)
        let alive = store.loadTrash()
        check("expired entry purged", !alive.contains { $0.id == expired })
        check("unexpired entries kept", alive.count == raw.count - 1)
        let onDisk = try! JSONDecoder().decode([TrashedConversation].self, from: Data(contentsOf: trashURL))
        check("purge is persisted", onDisk.count == raw.count - 1)

        store.emptyTrash()
        check("emptyTrash clears the bin", store.loadTrash().isEmpty)

        print(failures == 0 ? "all good (\(ConversationStore.trashRetentionDays)-day retention)" : "\(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
SWIFT

# HarnessDetector (and the ProcessRunner it uses) come along because `Provider`
# carries a `HarnessInstall`, and Equatable synthesis needs the whole type.
swiftc -O -parse-as-library "$WORK/main.swift" \
    Sources/QuickAI/Models.swift \
    Sources/QuickAI/HarnessDetector.swift \
    Sources/QuickAI/ProcessRunner.swift \
    -o "$WORK/store-test"
"$WORK/store-test"
