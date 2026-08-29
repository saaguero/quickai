import AppKit
import SwiftUI

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PanelController {
    static let panelDidShow = Notification.Name("QuickAI.panelDidShow")

    static let panelWidth: CGFloat = 840
    static let compactHeight: CGFloat = 64
    static let expandedHeight: CGFloat = 570

    /// The window is larger than the panel on every side, and that ring is
    /// transparent: it is where the shadow gets drawn. A borderless window's
    /// own shadow hugs the edge too tightly to lift the panel off a dark
    /// desktop, which is what makes Raycast's read as floating. Every frame
    /// computed here is a *window* frame, so it includes the ring twice.
    static let shadowMargin: CGFloat = 24
    static var windowWidth: CGFloat { panelWidth + shadowMargin * 2 }
    static func windowHeight(forContent height: CGFloat) -> CGFloat { height + shadowMargin * 2 }

    private let panel: KeyPanel
    private let viewModel: ChatViewModel
    private var isRepositioning = false
    private var moveObserver: NSObjectProtocol?
    private let settings: AppSettings
    private let openSettings: @MainActor () -> Void
    private var keyMonitor: Any?

    init(viewModel: ChatViewModel, settings: AppSettings, openSettings: @escaping @MainActor () -> Void) {
        self.viewModel = viewModel
        self.settings = settings
        self.openSettings = openSettings

        panel = KeyPanel(
            contentRect: NSRect(
                x: 0, y: 0,
                width: Self.windowWidth,
                height: Self.windowHeight(forContent: Self.compactHeight)
            ),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The panel draws its own shadow into the transparent ring (see
        // shadowMargin). The window's shadow has to be off: AppKit derives it
        // from the window's alpha, so once the ring is painted it traced a hard
        // contour around the *window* rect, a black outline floating well
        // outside the panel.
        panel.hasShadow = false
        panel.hidesOnDeactivate = true
        // dragging must select text in the answer, not move the window
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let root = ContentView(model: viewModel, settings: settings) { [weak self] height in
            self?.setPanelHeight(height)
        }
        panel.contentView = NSHostingView(rootView: root)

        // the panel is dragged by its chrome (see WindowDragHandle): remember
        // where the user parked it, but ignore our own repositioning
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isRepositioning else { return }
                // remembered in *panel* coordinates, not window ones, so the
                // shadow ring can change size without moving a parked panel
                self.settings.panelTopLeft = CGPoint(
                    x: self.panel.frame.minX + Self.shadowMargin,
                    y: self.panel.frame.maxY - Self.shadowMargin
                )
            }
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event) ?? event
            }
        }
    }

    func toggle() {
        if panel.isKeyWindow && panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        viewModel.autoResetIfIdle()
        if viewModel.isShowingHistory { viewModel.restartHistorySearch() }
        position()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: Self.panelDidShow, object: nil)
        // reopening lands at the newest message: hint at what is above it
        flashScrollers(delay: 0.15)
    }

    func hide() {
        panel.orderOut(nil)
    }

    func showHistory() {
        show()
        if !viewModel.isShowingHistory { viewModel.toggleHistory() }
        else { viewModel.restartHistorySearch() }
    }

    private func desiredHeightNow() -> CGFloat {
        let bar = viewModel.isShowingShortcuts ? ContentViewMetrics.shortcutsBarHeight : 0
        let base = (viewModel.hasContent || viewModel.isShowingHistory) ? Self.expandedHeight : Self.compactHeight
        return base + bar
    }

    private func position() {
        let height = desiredHeightNow()
        let topLeft = settings.panelTopLeft.flatMap(clampedToAScreen) ?? defaultTopLeft(height: height)
        guard let topLeft else { return }
        setFrameQuietly(windowFrame(panelTopLeft: topLeft, contentHeight: height))
    }

    /// Panel top-left to window frame: the window carries the shadow ring on
    /// every side, so it starts one margin up and to the left of the panel.
    private func windowFrame(panelTopLeft: CGPoint, contentHeight: CGFloat) -> NSRect {
        NSRect(
            x: panelTopLeft.x - Self.shadowMargin,
            y: panelTopLeft.y + Self.shadowMargin - Self.windowHeight(forContent: contentHeight),
            width: Self.windowWidth,
            height: Self.windowHeight(forContent: contentHeight)
        )
    }

    /// Default spot: primary screen, like Raycast, regardless of mouse location.
    private func defaultTopLeft(height: CGFloat) -> CGPoint? {
        let screen = NSScreen.screens.first ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return nil }
        return CGPoint(x: visible.midX - Self.panelWidth / 2, y: visible.maxY - visible.height * 0.16)
    }

    /// Keeps a remembered position usable after a monitor change: the top edge
    /// has to stay on some screen, otherwise fall back to the default.
    private func clampedToAScreen(_ topLeft: CGPoint) -> CGPoint? {
        for screen in NSScreen.screens {
            let visible = screen.visibleFrame
            guard topLeft.y > visible.minY, topLeft.y <= visible.maxY,
                  topLeft.x + Self.panelWidth > visible.minX, topLeft.x < visible.maxX else { continue }
            return CGPoint(
                x: min(max(topLeft.x, visible.minX), visible.maxX - Self.panelWidth),
                y: min(topLeft.y, visible.maxY)
            )
        }
        return nil
    }

    /// Programmatic moves must not be mistaken for the user dragging the panel.
    private func setFrameQuietly(_ frame: NSRect, animate: Bool = false) {
        isRepositioning = true
        panel.setFrame(frame, display: true, animate: animate)
        isRepositioning = false
    }

    /// ⌘⇧R: forget the dragged position and go back to the default spot.
    func resetPosition() {
        settings.panelTopLeft = nil
        position()
        viewModel.showFlash("Panel position reset")
    }

    /// `height` is the panel's own height, as measured by `ContentView`.
    func setPanelHeight(_ height: CGFloat) {
        var frame = panel.frame
        let target = Self.windowHeight(forContent: height)
        guard frame.height != target else { return }
        let top = frame.maxY
        frame.size.height = target
        frame.origin.y = top - target
        setFrameQuietly(frame, animate: true)
    }

    // MARK: - Keyboard scrolling

    private var isExpanded: Bool { viewModel.hasContent || viewModel.isShowingHistory }

    /// How far one key press moves the answer area.
    private enum ScrollCommand {
        /// A screenful, minus a little overlap so no line is jumped over.
        case page(Int)
        /// -1 top, +1 bottom.
        case edge(Int)
    }

    /// The input field always keeps focus, so none of these ever reach the
    /// scroll view on their own: the panel has to translate them.
    /// Letter keys are deliberately left alone (⌃U and ⌃D would cost the input
    /// field its kill-line and delete-forward bindings).
    private func scrollCommand(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) -> ScrollCommand? {
        switch (event.keyCode, modifiers) {
        case (121, []): return .page(1) // Page Down (fn+↓)
        case (116, []): return .page(-1) // Page Up (fn+↑)
        case (119, []): return .edge(1) // End (fn+→)
        case (115, []): return .edge(-1) // Home (fn+←)
        case (125, [.control]): return .page(1) // ⌃↓
        case (126, [.control]): return .page(-1) // ⌃↑
        case (125, [.command]): return .edge(1) // ⌘↓
        case (126, [.command]): return .edge(-1) // ⌘↑
        default: return nil
        }
    }

    private func perform(_ command: ScrollCommand) {
        if viewModel.isShowingHistory {
            pageHistorySelection(command)
        } else {
            scrollConversation(command)
        }
        flashScrollers()
    }

    /// Overlay scrollers only reveal themselves for a real trackpad or mouse
    /// scroll, so keyboard scrolling has to ask. The bar is the only cue for
    /// how much is left above and below, then it fades on its own.
    /// `delay` waits for a view that is still being built (a conversation
    /// opening replaces the whole scroll view).
    private func flashScrollers(delay: TimeInterval = 0) {
        guard delay > 0 else {
            mainScrollView()?.flashScrollers()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.mainScrollView()?.flashScrollers()
        }
    }

    /// History selection moves scroll the list, so they flash the bar too.
    private func moveHistorySelection(_ delta: Int) {
        viewModel.moveHistorySelection(delta)
        flashScrollers()
    }

    /// The panel's main scroll view (the chat, or the history list). Found
    /// breadth-first: a markdown code block carries its own horizontal scroll
    /// view, and only the outermost one is the answer area.
    private func mainScrollView() -> NSScrollView? {
        guard let root = panel.contentView else { return nil }
        var queue: [NSView] = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scrollView = view as? NSScrollView, scrollView.documentView != nil {
                return scrollView
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    private func scrollConversation(_ command: ScrollCommand) {
        guard let scrollView = mainScrollView() else { return }
        let clip = scrollView.contentView
        let visible = clip.bounds.height
        let maxOffset = max(0, (scrollView.documentView?.bounds.height ?? visible) - visible)
        // SwiftUI's document view is flipped (y grows downward, 0 is the top);
        // handle the other orientation anyway, it is one sign either way
        let isFlipped = scrollView.documentView?.isFlipped ?? true
        let current = isFlipped ? clip.bounds.origin.y : maxOffset - clip.bounds.origin.y

        let target: CGFloat
        switch command {
        case .page(let direction): target = current + CGFloat(direction) * visible * 0.9
        case .edge(let direction): target = direction > 0 ? maxOffset : 0
        }
        let offset = min(max(target, 0), maxOffset)

        let origin = NSPoint(x: clip.bounds.origin.x, y: isFlipped ? offset : maxOffset - offset)
        guard abs(origin.y - clip.bounds.origin.y) > 0.5 else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            clip.animator().setBoundsOrigin(origin)
        }
        scrollView.reflectScrolledClipView(clip)
    }

    /// History is a selection list, so paging moves the cursor and lets the
    /// list follow. Scrolling it away from the selection would only last until
    /// the next arrow key snapped it back.
    private func pageHistorySelection(_ command: ScrollCommand) {
        let count = viewModel.filteredHistoryRows.count
        guard count > 0 else { return }
        switch command {
        case .page(let direction): viewModel.moveHistorySelection(direction * visibleHistoryRows(total: count))
        case .edge(let direction): viewModel.moveHistorySelection(direction * count)
        }
    }

    /// Rows in a screenful, measured off the list itself so it keeps up with
    /// the answer font size instead of assuming a row height.
    private func visibleHistoryRows(total: Int) -> Int {
        guard let scrollView = mainScrollView(), total > 0 else { return 8 }
        let rowHeight = (scrollView.documentView?.bounds.height ?? 0) / CGFloat(total)
        guard rowHeight > 1 else { return 8 }
        return max(1, Int(scrollView.contentView.bounds.height / rowHeight))
    }

    // MARK: - Panel-local keyboard shortcuts

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel else { return event }

        // Escape: dismiss shortcuts overlay, stop streaming, leave history, or dismiss
        if event.keyCode == 53 {
            if viewModel.isShowingShortcuts {
                viewModel.isShowingShortcuts = false
            } else if viewModel.isStreaming {
                viewModel.stop()
            } else if viewModel.isShowingHistory {
                // first Esc clears an active search, second leaves history
                if viewModel.inputText.isEmpty {
                    viewModel.isShowingHistory = false
                } else {
                    viewModel.inputText = ""
                }
            } else {
                hide()
            }
            return nil
        }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let characters = event.charactersIgnoringModifiers?.lowercased()

        // Scrolling keys, before history navigation: that block matches the
        // arrows without looking at modifiers, so it would eat ⌃↑ / ⌃↓ here.
        if isExpanded, let command = scrollCommand(event, modifiers: modifiers) {
            perform(command)
            return nil
        }

        // History navigation: arrows, ctrl+j/k, ctrl+n/p, Enter opens
        if viewModel.isShowingHistory {
            if event.keyCode == 125 { moveHistorySelection(1); return nil }
            if event.keyCode == 126 { moveHistorySelection(-1); return nil }
            if modifiers == [.control], let characters {
                if characters == "j" || characters == "n" { moveHistorySelection(1); return nil }
                if characters == "k" || characters == "p" { moveHistorySelection(-1); return nil }
            }
            // ⌘⌫ deletes the selected conversation (macOS "move to trash")
            if event.keyCode == 51, modifiers == [.command] {
                viewModel.deleteSelectedHistory()
                return nil
            }
            if event.keyCode == 36 {
                viewModel.openSelectedHistory()
                // the whole scroll view is replaced by the conversation's one
                flashScrollers(delay: 0.15)
                return nil
            }
        }

        // ⌘/ toggles the shortcuts overlay (⌘? also accepted)
        if modifiers.contains(.command), characters == "/" || event.characters == "?" {
            viewModel.isShowingShortcuts.toggle()
            return nil
        }

        // ⌘[ / ⌘] navigate older / newer conversations (shift optional)
        if modifiers.subtracting(.shift) == [.command], let characters {
            if characters == "[" { viewModel.navigateConversations(-1); flashScrollers(delay: 0.15); return nil }
            if characters == "]" { viewModel.navigateConversations(1); flashScrollers(delay: 0.15); return nil }
        }

        guard modifiers.contains(.command), let characters else {
            return event
        }

        switch (characters, modifiers) {
        case ("n", [.command]):
            viewModel.newConversation()
            return nil
        case ("c", [.command, .shift]):
            viewModel.copyLastAnswer()
            return nil
        case ("a", [.command, .shift]):
            viewModel.copyConversation()
            return nil
        case ("y", [.command]):
            viewModel.toggleHistory()
            flashScrollers(delay: 0.15)
            return nil
        case ("p", [.command]):
            // opens the existing top-right selector, same menu the mouse gets
            NotificationCenter.default.post(name: ModelPickerButton.openMenuNotification, object: nil)
            return nil
        case ("r", [.command]):
            viewModel.retry()
            return nil
        case ("r", [.command, .shift]):
            resetPosition()
            return nil
        case (",", [.command]):
            openSettings()
            return nil
        case ("w", [.command]):
            hide()
            return nil
        case ("q", [.command]):
            NSApp.terminate(nil)
            return nil
        default:
            return event
        }
    }
}
