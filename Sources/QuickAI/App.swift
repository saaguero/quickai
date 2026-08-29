import AppKit

@main
enum QuickAIApp {
    @MainActor
    static func main() {
        let delegate = AppDelegate()
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
    }
}
