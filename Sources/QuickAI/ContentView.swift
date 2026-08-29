import MarkdownUI
import SwiftUI

enum ContentViewMetrics {
    static let shortcutsBarHeight: CGFloat = 58
}

/// Transparent drag area for the panel's chrome (header and input rows).
/// `isMovableByWindowBackground` cannot be used instead: it swallows the drag
/// that text selection needs in the answer area.
struct WindowDragHandle: NSViewRepresentable {
    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
        override var mouseDownCanMoveWindow: Bool { false }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct ContentView: View {
    @ObservedObject var model: ChatViewModel
    @ObservedObject var settings: AppSettings
    var onHeightChange: @MainActor (CGFloat) -> Void

    @FocusState private var inputFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var isExpanded: Bool { model.hasContent || model.isShowingHistory }

    // Depth, Raycast-style: every row of the panel sits on one sunken surface
    // (compact bar included, so expanding is a surface widening rather than a
    // change of color), and only the follow-up input is lifted off it, so the
    // place you type reads as a field instead of more conversation.
    private var isDark: Bool { colorScheme == .dark }
    private var panelTint: Color { Color.black.opacity(isDark ? 0.18 : 0) }
    private var sunkenBackground: Color { Color.black.opacity(isDark ? 0.22 : 0.045) }
    private var raisedBackground: Color { Color.white.opacity(isDark ? 0.06 : 0.5) }

    /// The follow-up input floats on the sunken body as a rounded pill: it is
    /// the one place you type, so it is the one thing lifted off the surface.
    /// The header deliberately stays flat on the same dark (its own padding is
    /// what separates it from the first message).
    private func floatingChrome<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(raisedBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .frame(height: 56)
            .background(WindowDragHandle())
            .background(sunkenBackground)
    }

    private var desiredHeight: CGFloat {
        let bar = model.isShowingShortcuts ? ContentViewMetrics.shortcutsBarHeight : 0
        return (isExpanded ? PanelController.expandedHeight : PanelController.compactHeight) + bar
    }

    var body: some View {
        VStack(spacing: 0) {
            if !isExpanded {
                compactInputRow
                    .frame(height: PanelController.compactHeight)
            } else {
                headerBar
                Group {
                    if model.isShowingHistory {
                        HistoryView(model: model, settings: settings)
                    } else {
                        conversationScroll
                    }
                }
                .background(sunkenBackground)
                bottomInputRow
            }
            if model.isShowingShortcuts {
                ShortcutsBar()
            }
        }
        .frame(width: PanelController.panelWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            ZStack {
                // Glass, Raycast-style. The solid layer is capped below full:
                // at 100% the panel went flat and stopped separating from a
                // dark desktop, which is the whole reason the material is
                // there. A lower panelOpacity is still honored as set, the cap
                // only keeps the top of the range from sealing the glass.
                VisualEffectBackground(material: isDark ? .hudWindow : .popover)
                Color(nsColor: .windowBackgroundColor).opacity(min(settings.panelOpacity, 0.72))
                panelTint
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            // A lit top edge fading into the sides: the hairline that reads as
            // the rim of a piece of glass, rather than a drawn border.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isDark ? 0.22 : 0.55),
                            Color.white.opacity(isDark ? 0.05 : 0.15),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        )
        .overlay(alignment: .top) { flashView }
        // Drawn into the window's transparent ring (PanelController.shadowMargin,
        // where the window's own shadow is off), so it must stay inside it or
        // the window edge clips it.
        .shadow(color: Color.black.opacity(isDark ? 0.45 : 0.18), radius: 16, y: 5)
        .padding(PanelController.shadowMargin)
        .onChange(of: desiredHeight) { onHeightChange($0) }
        .onChange(of: isExpanded) { _ in
            // the input row is swapped (top/bottom): re-focus once the new field exists
            DispatchQueue.main.async { inputFocused = true }
        }
        .onChange(of: model.conversation.id) { _ in
            DispatchQueue.main.async { inputFocused = true }
        }
        .onChange(of: model.inputText) { _ in
            if model.isShowingHistory { model.historyIndex = 0 }
        }
        .onReceive(NotificationCenter.default.publisher(for: PanelController.panelDidShow)) { _ in
            inputFocused = true
        }
        .onAppear { inputFocused = true }
    }

    // MARK: - Header (persistent conversation title, Raycast-style)

    private var headerBar: some View {
        HStack(spacing: 12) {
            Text(headerTitle)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
            Spacer()
            providerMenu()
        }
        // 22 matches the conversation's horizontal padding, so the title sits
        // on the same left edge as the answers below it
        .padding(.horizontal, 22)
        .frame(height: 54)
        .background(WindowDragHandle())
        .background(sunkenBackground)
    }

    private var headerTitle: String {
        if model.isShowingHistory { return "Conversation History" }
        let title = model.conversation.title
        return title.isEmpty ? "New Conversation" : title
    }

    // MARK: - Inputs

    private var compactInputRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            TextField("Ask anything…", text: $model.inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .regular))
                .autocorrectionDisabled(true)
                .focused($inputFocused)
                .onSubmit { model.submitCurrentInput() }
            providerMenu(fontSize: 13)
        }
        .padding(.horizontal, 20)
        .frame(maxHeight: .infinity)
        .background(WindowDragHandle())
        // same dark as the conversation body, so growing into the expanded
        // panel is one surface widening, not a change of color
        .background(sunkenBackground)
    }

    private var bottomInputRow: some View {
        floatingChrome {
            HStack(spacing: 12) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 17)
                TextField(
                    model.isShowingHistory ? "Search conversations…" : "Ask a follow-up…",
                    text: $model.inputText
                )
                .textFieldStyle(.plain)
                .font(.system(size: CGFloat(settings.answerFontSize)))
                // never autocorrect: in history mode this field is a search box
                // and macOS would silently rewrite partial words like "defi"
                .autocorrectionDisabled(true)
                .focused($inputFocused)
                .onSubmit { model.submitCurrentInput() }
                if model.isStreaming {
                    Text("⎋ stop")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
    }

    private func providerMenu(fontSize: CGFloat = 13) -> some View {
        ModelPickerButton(
            openrouterChoices: settings.openrouterChoices,
            localChoices: settings.localChoices,
            harnessChoices: settings.harnesses.map { ($0.kind, $0.choices) },
            current: settings.currentChoice,
            label: settings.currentProvider.shortLabel,
            fontSize: fontSize,
            onSelect: { settings.select($0) }
        )
        .fixedSize()
    }

    // MARK: - Conversation

    /// Live reasoning, shown while the answer has not started. Progress only:
    /// it is dimmed, tail-clipped so it cannot grow the panel, and dropped the
    /// moment real text arrives.
    private var reasoningView: some View {
        let trace = model.reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
        return Text(trace.isEmpty ? "Thinking…" : String(trace.suffix(400)))
            .font(.system(size: max(11, CGFloat(settings.answerFontSize) - 3)))
            .italic()
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var conversationScroll: some View {
        let exchanges = makeExchanges(model.conversation.messages)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(exchanges) { exchange in
                        userBubble(exchange.question)
                        if let answer = exchange.answer {
                            answerView(answer)
                        } else if model.isStreaming && exchange.id == exchanges.last?.id {
                            if model.draft.isEmpty {
                                reasoningView
                            } else {
                                answerView(model.draft + " ▍")
                            }
                        }
                    }
                    if let error = model.error {
                        answerView("> ⚠️ **Error:** \(error)\n>\n> Press ⌘R to retry.")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 22)
                // the title bar needs air under it: without this gap the first
                // message reads as part of the header
                .padding(.top, 22)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.draft) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.reasoning) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: model.conversation.messages.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            // opening a conversation (history, ⌘[ / ⌘]) lands on the newest
            // message, never at the top: the last answer is what it was opened
            // for. async because the rows do not exist yet on this pass, and
            // the message count alone cannot carry it (two conversations of
            // the same length would not change it).
            .onChange(of: model.conversation.id) { _ in
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear {
                DispatchQueue.main.async { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private func userBubble(_ question: String) -> some View {
        HStack {
            Spacer(minLength: 60)
            Text(question)
                .font(.system(size: CGFloat(settings.answerFontSize)))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
        }
        .frame(maxWidth: .infinity)
    }

    private func answerView(_ markdown: String) -> some View {
        Markdown(markdown)
            .markdownTheme(
                Theme.docC.text {
                    FontSize(CGFloat(settings.answerFontSize))
                }
            )
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var flashView: some View {
        if let flash = model.flash {
            Text(flash)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 10)
                .transition(.opacity)
        }
    }
}

private struct ExchangeItem: Identifiable {
    let id: Int
    let question: String
    var answer: String?
}

private func makeExchanges(_ messages: [Message]) -> [ExchangeItem] {
    var exchanges: [ExchangeItem] = []
    for message in messages {
        switch message.role {
        case .user:
            exchanges.append(ExchangeItem(id: exchanges.count, question: message.content))
        case .assistant:
            if !exchanges.isEmpty {
                exchanges[exchanges.count - 1].answer = message.content
            }
        case .system:
            break
        }
    }
    return exchanges
}

struct HistoryView: View {
    @ObservedObject var model: ChatViewModel
    @ObservedObject var settings: AppSettings

    private static let relative = RelativeDateTimeFormatter()

    /// Titles match the answer text size; timestamps stay a notch smaller.
    private var titleFontSize: CGFloat { CGFloat(settings.answerFontSize) }
    private var timestampFontSize: CGFloat { max(10, titleFontSize - 4) }

    var body: some View {
        let rows = model.filteredHistoryRows
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if rows.isEmpty {
                        Text(model.history.isEmpty ? "No conversations yet" : "No matches")
                            .font(.system(size: titleFontSize))
                            .foregroundStyle(.secondary)
                            .padding(30)
                    }
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        let conversation = row.conversation
                        let isSelected = index == model.historyIndex
                        Button {
                            model.openConversation(conversation)
                        } label: {
                            HStack(spacing: 10) {
                                highlighted(row.title, ranges: row.highlights, color: SearchHighlight.color)
                                    .font(.system(size: titleFontSize))
                                    .lineLimit(1)
                                Spacer()
                                Text(Self.relative.localizedString(for: conversation.updatedAt, relativeTo: Date()))
                                    .font(.system(size: timestampFontSize))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSelected ? Color.accentColor.opacity(0.22) : Color.clear)
                        )
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                model.deleteConversation(conversation)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 10)
            }
            // scroll by conversation id, never by row index: an index-based
            // .id() would make each row view identified by its position, so
            // SwiftUI would reuse row 0's view across a new search and leave
            // the old title (and its highlights) on screen
            .onChange(of: model.historyIndex) { index in
                guard rows.indices.contains(index) else { return }
                proxy.scrollTo(rows[index].id)
            }
        }
    }
}

struct ShortcutsBar: View {
    private static let shortcuts: [(String, String)] = [
        ("↩", "send"),
        ("⎋", "stop · close"),
        ("⌘N", "new"),
        ("⌘⇧C", "copy answer"),
        ("⌘⇧A", "copy all"),
        ("⌘Y", "history"),
        ("⇞ ⇟", "scroll"),
        ("⌘⌫", "delete chat"),
        ("⌘[ ⌘]", "prev · next chat"),
        ("⌘P", "model"),
        ("⌘R", "retry"),
        ("⌘⇧R", "reset position"),
        ("⌘,", "settings"),
        ("⌘W", "hide"),
        ("⌘Q", "quit"),
    ]

    var body: some View {
        combinedText
            .font(.system(size: 11))
            .multilineTextAlignment(.center)
            .lineSpacing(4)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .frame(height: ContentViewMetrics.shortcutsBarHeight)
            .background(.regularMaterial)
    }

    private var combinedText: Text {
        var result = Text(verbatim: "")
        for (index, pair) in Self.shortcuts.enumerated() {
            if index > 0 {
                result = result + Text(verbatim: "    ")
            }
            result = result
                + Text(pair.0).fontWeight(.semibold).foregroundColor(.primary)
                + Text(" \(pair.1)").foregroundColor(.secondary)
        }
        return result
    }
}

/// The one and only model selector: an AppKit popup so ⌘P can open the very
/// same menu the mouse gets (SwiftUI's Menu cannot be opened programmatically).
struct ModelPickerButton: NSViewRepresentable {
    static let openMenuNotification = Notification.Name("QuickAI.openModelMenu")

    let openrouterChoices: [String]
    let localChoices: [String]
    /// One entry per harness, in `HarnessKind` order. Empty lists are skipped.
    let harnessChoices: [(HarnessKind, [String])]
    let current: ModelChoice
    let label: String
    var fontSize: CGFloat = 11
    let onSelect: (ModelChoice) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.isBordered = false
        // it draws a focus ring the moment it becomes first responder, which in
        // the compact row reads as a stray box around the model name. The panel
        // opens it by click or ⌘P, never by tabbing, so it needs no keyboard focus
        button.focusRingType = .none
        button.refusesFirstResponder = true
        // medium weight: the label is secondary-colored, so at a small size
        // regular weight reads as noise rather than as the active model
        button.font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        (button.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        context.coordinator.button = button
        context.coordinator.startObserving()
        rebuildMenu(button, coordinator: context.coordinator)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.onSelect = onSelect
        button.font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        rebuildMenu(button, coordinator: context.coordinator)
    }

    private func rebuildMenu(_ button: NSPopUpButton, coordinator: Coordinator) {
        coordinator.onSelect = onSelect
        let menu = NSMenu()
        menu.autoenablesItems = false
        // pull-down buttons use the first item as their title
        menu.addItem(NSMenuItem(title: label, action: nil, keyEquivalent: ""))

        func addSection(title: String, providerId: String, models: [String]) {
            guard !models.isEmpty else { return }
            let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for model in models {
                let choice = ModelChoice(providerId: providerId, model: model)
                let item = NSMenuItem(title: model, action: #selector(Coordinator.pick(_:)), keyEquivalent: "")
                item.target = coordinator
                item.representedObject = choice
                item.state = choice == current ? .on : .off
                item.indentationLevel = 1
                menu.addItem(item)
            }
        }

        addSection(title: "OpenRouter", providerId: "openrouter", models: openrouterChoices)
        if !localChoices.isEmpty {
            menu.addItem(.separator())
            addSection(title: "Local LLM", providerId: "local", models: localChoices)
        }
        for (kind, models) in harnessChoices where !models.isEmpty {
            menu.addItem(.separator())
            addSection(title: kind.displayName, providerId: kind.providerId, models: models)
        }
        button.menu = menu
    }

    final class Coordinator: NSObject {
        weak var button: NSPopUpButton?
        var onSelect: ((ModelChoice) -> Void)?
        private var observer: Any?

        func startObserving() {
            guard observer == nil else { return }
            observer = NotificationCenter.default.addObserver(
                forName: ModelPickerButton.openMenuNotification, object: nil, queue: .main
            ) { [weak self] _ in
                self?.button?.performClick(nil)
            }
        }

        deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        @objc func pick(_ sender: NSMenuItem) {
            guard let choice = sender.representedObject as? ModelChoice else { return }
            onSelect?(choice)
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        // .active, not .followsWindowActiveState: the panel keeps its glass
        // while another app is frontmost, which is most of the time it is up.
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}
