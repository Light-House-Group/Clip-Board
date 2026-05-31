// UIViews.swift
//
// Shared SwiftUI/AppKit bridge views, history content view, floating panel controller,
// menu-bar status item with right-click menu, and the hotkey recorder window.

import SwiftUI
import AppKit
import Foundation
import Combine
import Carbon
import ApplicationServices

// Semantic key codes to avoid magic numbers
private enum KeyCode {
    static let down: UInt16 = 125
    static let up: UInt16 = 126
    static let `return`: UInt16 = 36
    static let escape: UInt16 = 53
}

// MARK: - KeyDown Handling View

struct KeyDownHandlingView: NSViewRepresentable {
    var onKeyDown: (NSEvent) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            onKeyDown(event)
            return event
        }
        context.coordinator.monitor = monitor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator { var monitor: Any? }
}

extension View {
    func onKeyDown(_ handler: @escaping (NSEvent) -> Void) -> some View {
        background(KeyDownHandlingView(onKeyDown: handler))
    }
}

// MARK: - Visual Effect Background

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    let isEmphasized: Bool

    init(material: NSVisualEffectView.Material = .hudWindow,
         blendingMode: NSVisualEffectView.BlendingMode = .withinWindow,
         isEmphasized: Bool = true) {
        self.material = material
        self.blendingMode = blendingMode
        self.isEmphasized = isEmphasized
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = isEmphasized
        view.wantsLayer = true
        view.layer?.cornerRadius = HistoryUI.cornerRadius
        // Match SwiftUI's `.continuous` clip so the material's rounding is the same squircle
        // as the overlay stroke — otherwise the two corner shapes disagree subtly.
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
        nsView.isEmphasized = isEmphasized
    }
}

// MARK: - Shared UI constants and container

private enum HistoryUI {
    static let cornerRadius: CGFloat = 14
    static let panelWidth: CGFloat = 340
    static let panelHeight: CGFloat = 500
    static let contentWidth: CGFloat = 328
    static let contentHeight: CGFloat = 408

    static let outerPadding: CGFloat = 12
    static let innerHorizontal: CGFloat = 10
    static let innerVertical: CGFloat = 6
    static let rowCorner: CGFloat = 10
}

struct SharedHistoryRootView: View {
    let itemsVM: ItemsViewModel

    init(itemsVM: ItemsViewModel) {
        self.itemsVM = itemsVM
    }

    var body: some View {
        ZStack(alignment: .top) {
            VisualEffectView(material: .sidebar, blendingMode: .withinWindow, isEmphasized: false)
                .clipShape(RoundedRectangle(cornerRadius: HistoryUI.cornerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: HistoryUI.cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                // Symmetric shadow: a large downward offset made the bottom corners read
                // softer/rounder than the top. A near-centered glow keeps all four corners
                // visually identical while still lifting the panel off the desktop.
                .shadow(color: Color.black.opacity(0.22), radius: 18, x: 0, y: 2)

            // No drag grabber — the entire panel is draggable via
            // `isMovableByWindowBackground`, so the capsule was decorative-only
            // and just pushed real content down.
            VStack(spacing: 0) {
                ContentView()
                    .environmentObject(itemsVM)
                    .padding(.horizontal, HistoryUI.innerHorizontal)

                attributionFooter
                    .padding(.horizontal, HistoryUI.innerHorizontal)
                    .padding(.top, 6)
                    .padding(.bottom, HistoryUI.innerVertical + 2)
            }
        }
        .padding(HistoryUI.outerPadding)
        .frame(width: HistoryUI.panelWidth, height: HistoryUI.panelHeight)
        .background(Color.clear)
    }

    /// Centered attribution footer. Quiet styling so it doesn't compete with content.
    private var attributionFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Clip-Board by Siddharth Sangwan")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Focus ringless TextField (macOS)

struct FocusRinglessTextField: NSViewRepresentable {
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusRinglessTextField
        init(_ parent: FocusRinglessTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            if parent.text != field.stringValue {
                parent.text = field.stringValue
            }
        }
    }

    var title: String
    @Binding var text: String
    var isFocused: Bool

    func makeNSView(context: Context) -> NSTextField {
        let tf = NSTextField(string: text)
        tf.placeholderString = title
        tf.isBordered = false
        tf.isBezeled = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        tf.delegate = context.coordinator
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        if nsView.placeholderString != title {
            nsView.placeholderString = title
        }
        nsView.focusRingType = .none

        if isFocused,
           nsView.window != nil,
           nsView.currentEditor() == nil,
           nsView.acceptsFirstResponder {
            DispatchQueue.main.async {
                nsView.becomeFirstResponder()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
}

// MARK: - ContentView

struct ContentView: View {
    @EnvironmentObject var itemsVM: ItemsViewModel
    @State private var searchText: String = ""
    @State private var debouncedSearchText: String = ""
    @State private var searchDebounceTask: DispatchWorkItem? = nil
    @State private var selectedID: UUID? = nil
    @State private var copiedTimestamps: [UUID: Date] = [:]
    @State private var hoverID: UUID? = nil
    /// Which row's full-text popover is currently visible (one at a time across the list).
    @State private var previewItemID: UUID? = nil
    @FocusState private var searchFocused: Bool
    @State private var visibleLimit: Int = 30
    private let maxVisible: Int = 200
    @State private var keyboardNavigated: Bool = false
    private let copyHighlightDuration: TimeInterval = 0.6

    // Multi-select mode — entered via row context-menu "Select".
    // Click anywhere on a row toggles its selection; no leading checkboxes.
    @State private var isMultiSelectMode: Bool = false
    @State private var multiSelectedIDs: Set<UUID> = []

    // System confirmation before Clear destroys a batch of items.
    private enum ClearScope { case unpinnedOnly, all }
    @State private var pendingClear: ClearScope? = nil

    private func enterSelectMode(initialID: UUID? = nil) {
        isMultiSelectMode = true
        multiSelectedIDs = initialID.map { [$0] } ?? []
        previewItemID = nil
        selectedID = nil
    }
    private func exitSelectMode() {
        isMultiSelectMode = false
        multiSelectedIDs.removeAll()
    }
    private func toggleMultiSelection(_ id: UUID) {
        if multiSelectedIDs.contains(id) { multiSelectedIDs.remove(id) }
        else { multiSelectedIDs.insert(id) }
    }
    private func deleteMultiSelected() {
        for id in multiSelectedIDs {
            itemsVM.deleteItem(id)
            if selectedID == id { selectedID = nil }
            if previewItemID == id { previewItemID = nil }
            copiedTimestamps.removeValue(forKey: id)
        }
        exitSelectMode()
    }

    /// Single-pass snapshot of items split into pinned/unpinned display buckets.
    /// Stored in `@State` and recomputed only when its inputs change (items, search,
    /// visible-limit) so the body recomputation triggered by hover / selection /
    /// preview-id changes doesn't repeat the O(n) filter on every tick.
    private struct Snapshot: Equatable {
        var ordered: [ClipItem]
        var displayPinned: [ClipItem]
        var displayUnpinned: [ClipItem]
        var displayItems: [ClipItem] { displayPinned + displayUnpinned }
    }

    @State private var snapshotState = Snapshot(ordered: [], displayPinned: [], displayUnpinned: [])
    private var snapshot: Snapshot { snapshotState }

    private func recomputeSnapshot() {
        let q = debouncedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var pinned: [ClipItem] = []
        var unpinned: [ClipItem] = []
        for item in itemsVM.items {
            if !q.isEmpty && !item.text.localizedCaseInsensitiveContains(q) { continue }
            if item.pinned { pinned.append(item) } else { unpinned.append(item) }
        }
        let ordered = pinned + unpinned
        let limit = min(visibleLimit, maxVisible, ordered.count)
        let pinnedInDisplay = min(pinned.count, limit)
        let next = Snapshot(
            ordered: ordered,
            displayPinned: Array(pinned.prefix(pinnedInDisplay)),
            displayUnpinned: Array(unpinned.prefix(limit - pinnedInDisplay))
        )
        if next != snapshotState { snapshotState = next }
    }

    private func isRecentlyCopied(_ id: UUID) -> Bool {
        guard let ts = copiedTimestamps[id] else { return false }
        return Date().timeIntervalSince(ts) < copyHighlightDuration
    }
    private func scheduleCopiedCleanup(for id: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + copyHighlightDuration) {
            if let ts = copiedTimestamps[id], Date().timeIntervalSince(ts) >= copyHighlightDuration {
                copiedTimestamps.removeValue(forKey: id)
            }
        }
    }

    private enum RowAction { case copy }
    private func perform(action: RowAction, id: UUID) {
        guard let item = itemsVM.items.first(where: { $0.id == id }) else { return }
        switch action {
        case .copy:
            selectedID = id
            copiedTimestamps[id] = Date()
            scheduleCopiedCleanup(for: id)
            HistoryWindowController.shared.close()

            if item.isImage, let fileName = item.imageFileName {
                // Decrypt off-main, then paste the image into the previous app.
                DispatchQueue.global(qos: .userInitiated).async {
                    let png = ImageStore.shared.loadPNG(fileName: fileName)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        if let png { AutoPaster.pasteIntoPreviousApp(imageData: png) }
                    }
                }
            } else {
                let pasteItem = item
                // Defer slightly so the panel finishes ordering out before we activate the
                // previous app and synthesize Cmd-V into it. The item-aware overload
                // restores any captured RTF/RTFD/HTML so styled copies paste at fidelity.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    AutoPaster.pasteIntoPreviousApp(item: pasteItem)
                }
            }
        }
    }

    @ViewBuilder
    private func rows(for items: [ClipItem]) -> some View {
        ForEach(items, id: \.id) { item in
            ClipRow(
                item: item,
                isSelected: selectedID == item.id,
                isCopied: isRecentlyCopied(item.id),
                isMultiSelectMode: isMultiSelectMode,
                isMultiSelected: multiSelectedIDs.contains(item.id),
                previewItemID: $previewItemID
            )
            .id(item.id)
            .contentShape(Rectangle())
            .onTapGesture {
                if isMultiSelectMode {
                    toggleMultiSelection(item.id)
                } else {
                    perform(action: .copy, id: item.id)
                }
            }
            .onHover { hovering in
                if hovering { hoverID = item.id; selectedID = item.id } else if hoverID == item.id { hoverID = nil; if selectedID == item.id { selectedID = nil } }
            }
            .contextMenu {
                Button(item.pinned ? "Unpin" : "Pin") { withAnimation(.easeInOut(duration: 0.15)) { itemsVM.togglePin(item.id) } }
                Button("Copy") { perform(action: .copy, id: item.id) }
                Button(isMultiSelectMode ? "Add to Selection" : "Select") {
                    if isMultiSelectMode {
                        multiSelectedIDs.insert(item.id)
                    } else {
                        enterSelectMode(initialID: item.id)
                    }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    itemsVM.deleteItem(item.id)
                    if selectedID == item.id { selectedID = nil }
                    if previewItemID == item.id { previewItemID = nil }
                    multiSelectedIDs.remove(item.id)
                    copiedTimestamps.removeValue(forKey: item.id)
                }
            }
            .onAppear {
                let snap = snapshot
                if let last = snap.displayItems.last, last.id == item.id {
                    let total = snap.ordered.count
                    if visibleLimit < min(total, maxVisible) { visibleLimit = min(visibleLimit + 30, min(total, maxVisible)) }
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // "Clipboard" title removed per design — search bar leads the panel.
            searchBar
                .padding(.horizontal, HistoryUI.innerHorizontal)
                .padding(.top, 15)
                .padding(.bottom, 8)

            Divider().opacity(0.6).padding(.bottom, 6)

            ScrollViewReader { proxy in
                let snap = snapshot
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if snap.displayItems.isEmpty {
                            emptyState
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        } else {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                if !snap.displayPinned.isEmpty {
                                    rows(for: snap.displayPinned)
                                    Divider().opacity(0.6).padding(.vertical, 2)
                                }
                                rows(for: snap.displayUnpinned)
                            }
                            .padding(.horizontal, 7)
                            .padding(.bottom, 56)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .coordinateSpace(name: "historyScroll")
                .frame(width: HistoryUI.contentWidth, height: HistoryUI.contentHeight)
                .scrollIndicators(.hidden)
                .safeAreaInset(edge: .bottom) { Color.clear.frame(height: 8) }
                .transaction { $0.animation = nil }
                .onChange(of: selectedID) { _, id in
                    guard keyboardNavigated, let id else { return }
                    keyboardNavigated = false
                    withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) }
                }
                .onKeyDown(handleKeyEvent(_:))
            }
        }
        .onAppear {
            recomputeSnapshot()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { searchFocused = true }
        }
        .onChange(of: searchText) { _, newValue in
            searchDebounceTask?.cancel()
            if newValue.isEmpty { debouncedSearchText = ""; visibleLimit = 30; return }
            let task = DispatchWorkItem { debouncedSearchText = newValue; visibleLimit = 30 }
            searchDebounceTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: task)
        }
        .onChange(of: itemsVM.items) { _, _ in recomputeSnapshot() }
        .onChange(of: debouncedSearchText) { _, _ in recomputeSnapshot() }
        .onChange(of: visibleLimit) { _, _ in recomputeSnapshot() }
        .confirmationDialog(
            pendingClear == .all ? "Clear all items, including pinned?" : "Clear all unpinned items?",
            isPresented: Binding(
                get: { pendingClear != nil },
                set: { newValue in if !newValue { pendingClear = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(pendingClear == .all ? "Clear Everything" : "Clear Unpinned", role: .destructive) {
                let scope = pendingClear
                pendingClear = nil
                clearHistory(removePinned: scope == .all)
            }
            .keyboardShortcut(.defaultAction) // Enter / Return triggers the destructive action.
            Button("Cancel", role: .cancel) { pendingClear = nil }
                .keyboardShortcut(.cancelAction) // Esc cancels.
        } message: {
            Text(pendingClear == .all
                 ? "This permanently removes every clipboard entry, including pinned ones. This cannot be undone."
                 : "This permanently removes all unpinned clipboard entries. Pinned items will be kept. This cannot be undone.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard").font(.system(size: 24)).foregroundStyle(.secondary)
            Text("No items found").foregroundStyle(.secondary).font(.footnote)
        }.padding(.vertical, 18)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                FocusRinglessTextField(title: "Search clipboard", text: $searchText, isFocused: searchFocused)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary.opacity(0.9))
                    }.buttonStyle(.plain).help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, HistoryUI.innerVertical)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(NSColor.controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.white.opacity(0.06)))

            if isMultiSelectMode {
                Button("Cancel") { exitSelectMode() }
                    .font(.footnote)
                    .controlSize(.small)
                Button(role: .destructive) {
                    deleteMultiSelected()
                } label: {
                    Image(systemName: "trash"); Text("Delete \(multiSelectedIDs.count)")
                }
                .font(.footnote)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(multiSelectedIDs.isEmpty)
                .help("Delete the selected items")
            } else {
                Button(role: .destructive) {
                    let alsoPinned = NSEvent.modifierFlags.contains(.option)
                    pendingClear = alsoPinned ? .all : .unpinnedOnly
                } label: {
                    Image(systemName: "trash"); Text("Clear")
                }
                .font(.footnote)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Clear unpinned items (⌥-click to include pinned)")
            }
        }
    }

    private func clearHistory(removePinned: Bool) {
        itemsVM.clearHistory(removePinned: removePinned)
        selectedID = nil
        copiedTimestamps.removeAll()
        searchText = ""
    }

    private func handleKeyEvent(_ event: NSEvent) {
        switch event.keyCode {
        case KeyCode.down:
            let ordered = snapshot.ordered
            guard !ordered.isEmpty else { return }
            keyboardNavigated = true
            previewItemID = nil
            if let currentID = selectedID, let idx = ordered.firstIndex(where: { $0.id == currentID }) {
                selectedID = ordered[min(idx + 1, ordered.count - 1)].id
            } else { selectedID = ordered.first?.id }
        case KeyCode.up:
            let ordered = snapshot.ordered
            guard !ordered.isEmpty else { return }
            keyboardNavigated = true
            previewItemID = nil
            if let currentID = selectedID, let idx = ordered.firstIndex(where: { $0.id == currentID }) {
                selectedID = ordered[max(idx - 1, 0)].id
            } else { selectedID = ordered.last?.id }
        case KeyCode.return:
            if let id = selectedID { perform(action: .copy, id: id) }
        case KeyCode.escape:
            if previewItemID != nil { previewItemID = nil }
            else if isMultiSelectMode { exitSelectMode() }
            else if !searchText.isEmpty { searchText = "" }
            else { selectedID = nil; HistoryWindowController.shared.close() }
        default: break
        }
    }
}

// MARK: - ClipRow View

struct ClipRow: View {
    let item: ClipItem
    var isSelected: Bool
    var isCopied: Bool
    var isMultiSelectMode: Bool = false
    var isMultiSelected: Bool = false
    @Binding var previewItemID: UUID?
    @EnvironmentObject var itemsVM: ItemsViewModel
    @State private var isHovered: Bool = false
    @State private var hoverWorkItem: DispatchWorkItem?
    /// Set by the row's text measurement: true when `lineLimit(2)` actually clips the content.
    @State private var isTextTruncated: Bool = false

    /// Image rows are always previewable (full-size on hover). Text rows are previewable
    /// only when the row is actually visually truncated — measured, not guessed.
    private var previewEligible: Bool {
        item.isImage || isTextTruncated
    }

    /// Maximum on-screen height for an image thumbnail inside a row.
    private static let imageRowMaxHeight: CGFloat = 200

    /// Bound to the popover; reads/writes the parent's shared `previewItemID`
    /// so only one preview is visible across the whole list at a time. Gated on
    /// `previewEligible` so that even if some upstream sets `previewItemID` to a
    /// non-truncated row, no popover is shown — the full text is already visible
    /// in the row itself.
    private var showPreview: Binding<Bool> {
        Binding(
            get: { previewItemID == item.id && previewEligible },
            set: { isOn in
                if isOn { previewItemID = item.id }
                else if previewItemID == item.id { previewItemID = nil }
            }
        )
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .short
        return f
    }()

    private var timeString: String { Self.formatter.string(from: item.date) }

    /// Row content: either a measured 2-line text block or an image thumbnail
    /// shrunk to the row width (aspect preserved, height capped).
    @ViewBuilder
    private var rowContent: some View {
        if item.isImage, let fileName = item.imageFileName {
            ClipThumbnail(
                fileName: fileName,
                pixelWidth: item.imageWidth ?? 1,
                pixelHeight: item.imageHeight ?? 1,
                maxHeight: Self.imageRowMaxHeight
            )
            .allowsHitTesting(false)
        } else {
            // No textSelection — it would swallow row clicks. Truncation is measured so
            // the hover preview only offers itself when content is actually clipped.
            TruncatingText(text: item.text, isTruncated: $isTextTruncated)
                .allowsHitTesting(false)
        }
    }

    private var pinBadge: some View {
        Group {
            if item.pinned {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 16, height: 16)
                        .allowsHitTesting(false)
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .symbolRenderingMode(.hierarchical)
                }
                .transition(.opacity.combined(with: .scale))
                .animation(.easeInOut(duration: 0.15), value: item.pinned)
            }
        }
    }

    private var metaRow: some View {
        HStack(spacing: 5) {
            pinBadge
            // Source-app chip — icon + name, so it's clear where the copy came from.
            if let icon = AppIconProvider.icon(forBundleID: item.sourceBundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 13, height: 13)
            }
            if let name = item.sourceAppName, !name.isEmpty {
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("·")
                    .font(.caption2)
                    .foregroundStyle(.secondary.opacity(0.6))
            }
            Text(timeString)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var pinButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                itemsVM.togglePin(item.id)
            }
        }) {
            Image(systemName: item.pinned ? "pin.fill" : "pin")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(item.pinned ? Color.accentColor : .secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            item.pinned
                            ? Color.accentColor.opacity(0.18)
                            : ((isHovered || isSelected) ? Color.secondary.opacity(0.12) : Color.clear)
                        )
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(
                            Color.white.opacity(item.pinned ? 0.18 : ((isHovered || isSelected) ? 0.08 : 0.04)),
                            lineWidth: 1
                        )
                )
                .transition(.opacity.combined(with: .scale))
                .animation(.easeInOut(duration: 0.15), value: item.pinned)
                .animation(.easeInOut(duration: 0.12), value: isHovered || isSelected)
        }
        .buttonStyle(.plain)
        .help(item.pinned ? "Unpin" : "Pin")
    }

    @ViewBuilder
    private var trailingActions: some View {
        if isMultiSelectMode {
            // In select mode the row's trailing space conveys selection state instead
            // of offering per-row actions (which would conflict with click-to-select).
            Image(systemName: isMultiSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(isMultiSelected ? Color.accentColor : .secondary.opacity(0.6))
                .symbolRenderingMode(.hierarchical)
                .allowsHitTesting(false)
        } else {
            // Pin only — copy is redundant with the row tap (which auto-pastes) and the
            // right-click "Copy" menu. Removed the doc-on-clipboard glyph for visual quiet.
            pinButton
                .opacity(isHovered ? 1 : 0.75)
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: HistoryUI.rowCorner, style: .continuous)
            .fill(backgroundColor)
    }

    private var rowStroke: some View {
        RoundedRectangle(cornerRadius: HistoryUI.rowCorner, style: .continuous)
            .stroke(Color.white.opacity((isHovered || isSelected) ? 0.14 : 0.07), lineWidth: 1)
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                rowContent
                metaRow
            }

            Spacer(minLength: 8)

            trailingActions
        }
        .padding(.vertical, HistoryUI.innerVertical)
        .padding(.horizontal, 9)
        .background(rowBackground)
        .overlay(rowStroke)
        .clipShape(RoundedRectangle(cornerRadius: HistoryUI.rowCorner, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: HistoryUI.rowCorner, style: .continuous))
        .scaleEffect(isHovered ? 1.035 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.9), value: isHovered)
        .onHover { hover in
            isHovered = hover
            scheduleOrCancelPreview(hovering: hover)
        }
        .popover(isPresented: showPreview, arrowEdge: .trailing) {
            if item.isImage, let fileName = item.imageFileName {
                FullImagePopover(
                    fileName: fileName,
                    pixelWidth: item.imageWidth ?? 1,
                    pixelHeight: item.imageHeight ?? 1
                )
            } else {
                FullTextPopover(text: item.text)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(item.isImage ? "Clipboard image" : "Clipboard item"))
        .accessibilityValue(Text(item.text))
    }

    /// Hover-in: immediately dismiss any other row's preview, then start a 1s timer
    /// for this row (only when content might be truncated). Hover-out: cancel the
    /// pending timer — but do NOT clear `previewItemID`, so the user can move the
    /// cursor INTO the popover to select text. The popover is also dismissed when
    /// any other row receives hover, or on keyboard up/down.
    private func scheduleOrCancelPreview(hovering: Bool) {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        guard hovering else { return }
        if previewItemID != nil && previewItemID != item.id {
            previewItemID = nil
        }
        guard previewEligible else { return }
        let work = DispatchWorkItem {
            // Only open if this row is still hovered when the timer fires.
            if isHovered { previewItemID = item.id }
        }
        hoverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private var backgroundColor: Color {
        if isMultiSelected { return Color.accentColor.opacity(0.22) }
        if isCopied { return Color.green.opacity(0.15) }
        if isSelected { return Color.accentColor.opacity(0.14) }
        if isHovered { return Color.gray.opacity(0.06) }
        return Color.white.opacity(0.02)
    }
}

// MARK: - Preview preference keys

/// Max-reducing CGFloat preference key, reused for content-size measurement.
private struct MaxCGFloatKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct VisibleHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct FullHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Shared glassy popover chrome (Liquid-Glass-style translucent surface + hairline edge).
private struct GlassPopoverBackground: View {
    var body: some View {
        VisualEffectView(material: .popover, blendingMode: .behindWindow, isEmphasized: false)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .ignoresSafeArea()
    }
}

// MARK: - Truncating text (measures real truncation)

/// Renders text clipped to two lines, and reports — via `isTruncated` — whether the
/// content is *actually* visually clipped at the current width. Compares the rendered
/// (2-line) height against the full unconstrained height laid out at the same width.
private struct TruncatingText: View {
    let text: String
    @Binding var isTruncated: Bool
    @State private var visibleH: CGFloat = 0
    @State private var fullH: CGFloat = 0

    var body: some View {
        Text(text)
            .lineLimit(2)
            .truncationMode(.tail)
            .font(.system(size: 13))
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { g in
                Color.clear.preference(key: VisibleHeightKey.self, value: g.size.height)
            })
            .background(
                // Hidden, unconstrained-height copy laid out at the same width.
                Text(text)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hidden()
                    .background(GeometryReader { g in
                        Color.clear.preference(key: FullHeightKey.self, value: g.size.height)
                    })
            )
            .onPreferenceChange(VisibleHeightKey.self) { v in visibleH = v; recompute() }
            .onPreferenceChange(FullHeightKey.self) { f in fullH = f; recompute() }
    }

    private func recompute() {
        // Sub-pixel rounding and font-metric quirks can make a non-truncated 2-line
        // block measure 0.5–2 pt taller via the unconstrained background than via
        // the lineLimit foreground. A generous slack (half a line at 13pt body =
        // ~8pt) ensures only genuine clipping flags as truncation, so the hover
        // preview never opens for text already fully visible in the row.
        let truncated = fullH > visibleH + 8
        guard truncated != isTruncated else { return }
        DispatchQueue.main.async { isTruncated = truncated }
    }
}

// MARK: - Image thumbnail (row) & full image preview (popover)

/// A decrypted image thumbnail shrunk to the row width with aspect preserved and a
/// capped height. Reserves layout space from the known pixel dimensions before the
/// (off-main) decrypt+decode completes, so rows don't jump as images load.
private struct ClipThumbnail: View {
    let fileName: String
    let pixelWidth: Int
    let pixelHeight: Int
    let maxHeight: CGFloat
    @State private var image: NSImage?

    private var aspect: CGFloat {
        pixelWidth > 0 && pixelHeight > 0 ? CGFloat(pixelWidth) / CGFloat(pixelHeight) : 16.0 / 9.0
    }

    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: maxHeight)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.10))
                        .overlay(Image(systemName: "photo").foregroundStyle(.secondary.opacity(0.5)))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear(perform: load)
    }

    private func load() {
        guard image == nil else { return }
        let fn = fileName
        DispatchQueue.global(qos: .userInitiated).async {
            let img = ImageStore.shared.loadThumbnail(fileName: fn, maxPixelSize: 800)
            DispatchQueue.main.async { self.image = img }
        }
    }
}

/// Full-resolution image preview shown on hover, in a glassy popover sized to the image
/// aspect (clamped). Scrollable when the image is capped.
private struct FullImagePopover: View {
    let fileName: String
    let pixelWidth: Int
    let pixelHeight: Int
    @State private var image: NSImage?

    private static let maxW: CGFloat = 760
    private static let maxH: CGFloat = 560
    private static let minW: CGFloat = 220
    private static let minH: CGFloat = 140

    private var aspect: CGFloat {
        pixelWidth > 0 && pixelHeight > 0 ? CGFloat(pixelWidth) / CGFloat(pixelHeight) : 16.0 / 9.0
    }

    private var frameSize: CGSize {
        var w = min(CGFloat(max(pixelWidth, 1)), Self.maxW)
        var h = w / aspect
        if h > Self.maxH { h = Self.maxH; w = h * aspect }
        w = min(max(w, Self.minW), Self.maxW)
        h = min(max(h, Self.minH), Self.maxH)
        return CGSize(width: w, height: h)
    }

    var body: some View {
        Group {
            if let image {
                ScrollView([.vertical, .horizontal]) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: frameSize.width)
                }
                .scrollContentBackground(.hidden)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: frameSize.width, height: frameSize.height)
        .background(GlassPopoverBackground())
        .onAppear(perform: load)
    }

    private func load() {
        guard image == nil else { return }
        let fn = fileName
        DispatchQueue.global(qos: .userInitiated).async {
            let img = ImageStore.shared.loadFullImage(fileName: fn)
            DispatchQueue.main.async { self.image = img }
        }
    }
}

// MARK: - Full-text Preview Popover

/// Scrollable, text-selectable popover sized to the *measured* content height (no trailing
/// gap). Width is a clamped estimate; height is the real content height capped at `maxH`.
private struct FullTextPopover: View {
    let text: String

    private static let minW: CGFloat = 320
    private static let maxW: CGFloat = 620
    private static let maxH: CGFloat = 460
    private static let charPx: CGFloat = 6.9
    private static let pad: CGFloat = 14

    @State private var measuredHeight: CGFloat = 0

    private var width: CGFloat {
        let widest = text.components(separatedBy: "\n").map { $0.count }.max() ?? 0
        let estimated = CGFloat(widest) * Self.charPx + Self.pad * 2
        return min(max(Self.minW, estimated), Self.maxW)
    }

    private var height: CGFloat {
        let h = measuredHeight > 0 ? measuredHeight : 56
        return min(h, Self.maxH)
    }

    var body: some View {
        ScrollView {
            Text(text)
                .textSelection(.enabled)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Self.pad)
                .background(GeometryReader { g in
                    Color.clear.preference(key: MaxCGFloatKey.self, value: g.size.height)
                })
        }
        .scrollContentBackground(.hidden)
        .onPreferenceChange(MaxCGFloatKey.self) { measuredHeight = $0 }
        .background(GlassPopoverBackground())
        .frame(width: width, height: height)
    }
}

// MARK: - History Window Controller

final class HistoryWindowController: NSObject, NSWindowDelegate {
    static let shared = HistoryWindowController()

    private var window: NSPanel?
    private var hostingView: NSHostingView<SharedHistoryRootView>?
    private var outsideClickMonitor: Any?

    private override init() {}

    /// Build the panel and force SwiftUI's first render off-screen so the user-visible
    /// first show is instant. Call once after the ItemsViewModel is ready.
    func prewarm(itemsVM: ItemsViewModel) {
        let panel = ensurePanel(itemsVM: itemsVM)
        panel.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        panel.alphaValue = 0
        panel.orderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    func toggle(at screenPoint: NSPoint, itemsVM: ItemsViewModel) {
        if let win = window, win.isVisible, win.alphaValue > 0 {
            close()
        } else {
            show(at: screenPoint, itemsVM: itemsVM)
        }
    }

    func show(at screenPoint: NSPoint, itemsVM: ItemsViewModel) {
        let panel = ensurePanel(itemsVM: itemsVM)
        panel.alphaValue = 1
        positionPanel(panel, at: screenPoint)

        // ignoringOtherApps: true reliably activates LSUIElement apps (clicking the
        // status item alone often isn't enough). AutoPaster filters self-activations,
        // so the user's previous foreground app is preserved as the paste target.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        installOutsideClickMonitor()
    }

    private func ensurePanel(itemsVM: ItemsViewModel) -> NSPanel {
        if let existing = window { return existing }

        let hosting = NSHostingView(rootView: SharedHistoryRootView(itemsVM: itemsVM))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: HistoryUI.panelWidth, height: HistoryUI.panelHeight),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .titled],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        // No hidesOnDeactivate — the global outside-click monitor is our single source
        // of truth for "click outside → close." Two mechanisms would race.
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.transient, .ignoresCycle]
        panel.isOpaque = false
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.delegate = self
        // .none avoids the fade-in delay on show. The panel is meant to feel instant.
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false

        let containerView = NSView()
        containerView.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = containerView

        containerView.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: containerView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            containerView.widthAnchor.constraint(equalToConstant: HistoryUI.panelWidth),
            containerView.heightAnchor.constraint(equalToConstant: HistoryUI.panelHeight)
        ])

        self.window = panel
        self.hostingView = hosting
        return panel
    }

    private func positionPanel(_ panel: NSPanel, at screenPoint: NSPoint) {
        // Pick the screen that actually contains the cursor, not the key-window screen.
        // On a multi-monitor setup `NSScreen.main` would clamp the panel onto the wrong
        // display when the user invokes the hotkey from another monitor.
        let screen = NSScreen.screens.first(where: { $0.frame.contains(screenPoint) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let halfW = HistoryUI.panelWidth / 2
        var origin = NSPoint(
            x: screenPoint.x - halfW,
            y: screenPoint.y - 20 - HistoryUI.panelHeight
        )
        let visible = screen.visibleFrame
        origin.x = max(visible.minX + 8, min(origin.x, visible.maxX - HistoryUI.panelWidth - 8))
        origin.y = max(visible.minY + 8, min(origin.y, visible.maxY - 8))
        panel.setFrameOrigin(origin)
    }

    func close() {
        window?.orderOut(nil)
        removeOutsideClickMonitor()
        // Intentionally keep `window` and `hostingView` for reuse — that's the perf win.
    }

    func windowWillClose(_ notification: Notification) {
        removeOutsideClickMonitor()
    }

    private func installOutsideClickMonitor() {
        outsideClickMonitor.map(NSEvent.removeMonitor)
        outsideClickMonitor = nil
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    private func removeOutsideClickMonitor() {
        outsideClickMonitor.map(NSEvent.removeMonitor)
        outsideClickMonitor = nil
    }
}

// MARK: - Menu Bar Controller (status item + right-click menu)

final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let itemsVM: ItemsViewModel
    private let onShortcutChanged: () -> Void
    private var activeRecorder: HotkeyRecorder?

    init(itemsVM: ItemsViewModel, onShortcutChanged: @escaping () -> Void) {
        self.itemsVM = itemsVM
        self.onShortcutChanged = onShortcutChanged
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard")
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let type = event?.type
        let isCtrl = event?.modifierFlags.contains(.control) ?? false
        if type == .rightMouseUp || (type == .leftMouseUp && isCtrl) {
            showContextMenu()
        } else {
            // Capture the user's foreground app BEFORE the panel activation pulls focus to us.
            AutoPaster.captureFrontmost()
            toggleHistory()
        }
    }

    private func toggleHistory() {
        HistoryWindowController.shared.toggle(at: NSEvent.mouseLocation, itemsVM: itemsVM)
    }

    private func showContextMenu() {
        let menu = NSMenu()

        if !AXIsProcessTrusted() {
            let ax = NSMenuItem(title: "Enable Auto-Paste (Accessibility)…",
                                action: #selector(menuOpenAccessibilitySettings),
                                keyEquivalent: "")
            ax.target = self
            menu.addItem(ax)
            menu.addItem(.separator())
        }

        let shortcut = NSMenuItem(title: "Set Shortcut…", action: #selector(menuSetShortcut), keyEquivalent: "")
        shortcut.target = self
        menu.addItem(shortcut)

        let launch = NSMenuItem(title: "Launch at Login", action: #selector(menuToggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = Preferences.shared.launchAtLogin ? .on : .off
        menu.addItem(launch)

        // History size — submenu with curated presets. The selected preset is checked;
        // if the stored value isn't one of the presets (hand-edited), no item is checked
        // but the submenu title still shows the current value so the state is visible.
        let current = Preferences.shared.historySize
        let historyItem = NSMenuItem(title: "History Size: \(current)", action: nil, keyEquivalent: "")
        let historyMenu = NSMenu()
        for size in Preferences.historySizePresets {
            let sub = NSMenuItem(title: "\(size) items",
                                 action: #selector(menuSetHistorySize(_:)),
                                 keyEquivalent: "")
            sub.target = self
            sub.tag = size
            sub.state = (size == current) ? .on : .off
            historyMenu.addItem(sub)
        }
        historyItem.submenu = historyMenu
        menu.addItem(historyItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Clip Board", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        if let button = statusItem.button {
            let point = NSPoint(x: 0, y: button.bounds.height + 4)
            menu.popUp(positioning: nil, at: point, in: button)
            // popUp can reset the cell's action mask; restore so left-click keeps firing.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func menuOpenAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func menuToggleLaunchAtLogin() {
        Preferences.shared.launchAtLogin.toggle()
    }

    @objc private func menuSetHistorySize(_ sender: NSMenuItem) {
        let size = sender.tag
        guard size > 0 else { return }
        // Setter posts Preferences.historySizeChanged; ItemsViewModel listens and re-trims.
        Preferences.shared.historySize = size
    }

    @objc private func menuSetShortcut() {
        let recorder = HotkeyRecorder(
            initial: Preferences.shared.hotkey,
            onSave: { [weak self] keyCode, modifiers in
                Preferences.shared.hotkey = .init(keyCode: keyCode, modifiers: modifiers)
                self?.onShortcutChanged()
            },
            onClose: { [weak self] in
                self?.activeRecorder = nil
            }
        )
        recorder.show()
        self.activeRecorder = recorder
    }
}

// MARK: - Hotkey Recorder

final class HotkeyRecorder: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var monitor: Any?
    private let model = RecorderModel()
    private let onSave: (UInt32, UInt32) -> Void   // Carbon keyCode, Carbon modifiers
    private let onClose: () -> Void

    init(initial: Preferences.HotkeyConfig,
         onSave: @escaping (UInt32, UInt32) -> Void,
         onClose: @escaping () -> Void) {
        self.onSave = onSave
        self.onClose = onClose
        super.init()
        let initialFlags = HotkeyDisplay.nsFlags(fromCarbon: initial.modifiers)
        model.display = HotkeyDisplay.string(carbonKeyCode: initial.keyCode, carbonModifiers: initial.modifiers)
        model.conflict = HotkeyConflict.description(keyCode: UInt16(initial.keyCode), flags: initialFlags)
    }

    func show() {
        let host = NSHostingView(rootView: RecorderView(
            model: model,
            onCancel: { [weak self] in self?.closeWindow() },
            onSave: { [weak self] in
                guard let self, let captured = self.model.captured else { return }
                self.onSave(UInt32(captured.keyCode), HotkeyDisplay.carbonModifiers(from: captured.flags))
                self.closeWindow()
            }
        ))
        host.frame = NSRect(x: 0, y: 0, width: 380, height: 200)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "Set Shortcut"
        w.contentView = host
        w.center()
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.level = .modalPanel

        // Local monitor only fires while this app is key — the window is key by then.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, NSApp.keyWindow == self.window else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Esc with no modifier cancels — common dialog convention.
            if event.keyCode == UInt16(kVK_Escape) && mods.isEmpty {
                self.closeWindow()
                return nil
            }
            let required: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
            // Ignore plain key presses (no modifier) — a global hotkey without modifiers
            // would be a usability disaster (intercepts every typed key).
            if mods.isDisjoint(with: required) {
                self.model.display = "Press a modifier + key"
                return nil
            }
            self.model.captured = .init(keyCode: event.keyCode, flags: mods)
            self.model.display = HotkeyDisplay.string(keyCode: event.keyCode, flags: mods)
            self.model.conflict = HotkeyConflict.description(keyCode: event.keyCode, flags: mods)
            return nil
        }

        self.window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    private func closeWindow() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        window = nil
        onClose()
    }
}

private final class RecorderModel: ObservableObject {
    struct Captured: Equatable {
        let keyCode: UInt16
        let flags: NSEvent.ModifierFlags
    }
    @Published var display: String = "Press a modifier + key"
    @Published var captured: Captured?
    @Published var conflict: String?
}

private struct RecorderView: View {
    @ObservedObject var model: RecorderModel
    var onCancel: () -> Void
    var onSave: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text("Set Global Shortcut")
                .font(.headline)
            Text("Hold one or more modifier keys (⌘ ⌥ ⌃ ⇧) and press a key.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 6) {
                Text(model.display)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12)))

                // Conflict indicator — orange (warning), not red (error). Always reserves
                // vertical space so the layout doesn't jump when conflict appears/clears.
                HStack(spacing: 6) {
                    if let conflict = model.conflict {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(conflict)
                    } else {
                        Text(" ")
                    }
                }
                .font(.caption)
                .foregroundStyle(model.conflict == nil ? Color.clear : Color.orange)
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(height: 16)
            }

            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Save", action: onSave)
                    .disabled(model.captured == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - Hotkey Conflict Detection

/// Curated catalog of well-known macOS / common-app shortcuts. Returns a short
/// description when the candidate combo matches a known conflict, otherwise nil.
///
/// This is intentionally a hand-maintained list of high-impact combos, not an
/// exhaustive system query (no stable public API exposes user-configured system
/// shortcuts). Covers what users would realistically try first.
private enum HotkeyConflict {
    static func description(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> String? {
        let cmd   = flags.contains(.command)
        let opt   = flags.contains(.option)
        let ctrl  = flags.contains(.control)
        let shift = flags.contains(.shift)
        let kc    = Int(keyCode)

        // ⌘ alone — single-key Cmd shortcuts used by virtually every macOS app.
        if cmd && !opt && !ctrl && !shift {
            switch kc {
            case kVK_ANSI_C: return "Conflicts with Copy"
            case kVK_ANSI_V: return "Conflicts with Paste"
            case kVK_ANSI_X: return "Conflicts with Cut"
            case kVK_ANSI_A: return "Conflicts with Select All"
            case kVK_ANSI_Z: return "Conflicts with Undo"
            case kVK_ANSI_N: return "Conflicts with New (most apps)"
            case kVK_ANSI_O: return "Conflicts with Open (most apps)"
            case kVK_ANSI_S: return "Conflicts with Save (most apps)"
            case kVK_ANSI_W: return "Conflicts with Close Window / Tab"
            case kVK_ANSI_Q: return "Conflicts with Quit Application"
            case kVK_ANSI_T: return "Conflicts with New Tab (most apps)"
            case kVK_ANSI_F: return "Conflicts with Find (most apps)"
            case kVK_ANSI_G: return "Conflicts with Find Next"
            case kVK_ANSI_P: return "Conflicts with Print"
            case kVK_ANSI_M: return "Conflicts with Minimize Window"
            case kVK_ANSI_H: return "Conflicts with Hide Application"
            case kVK_Space:  return "Conflicts with Spotlight Search"
            case kVK_Tab:    return "Conflicts with App Switcher"
            case kVK_ANSI_Comma:  return "Conflicts with Settings"
            case kVK_ANSI_Period: return "Conflicts with Cancel (⌘.)"
            case kVK_Return:      return "Conflicts with Default Action"
            case kVK_ANSI_Grave:  return "Conflicts with Cycle Windows In App"
            case kVK_ANSI_L: return "Conflicts with Focus Address Bar (browsers)"
            case kVK_ANSI_K: return "Conflicts with Command Palette (many apps)"
            default: break
            }
        }

        // ⌘⇧ combos
        if cmd && shift && !opt && !ctrl {
            switch kc {
            case kVK_ANSI_Z: return "Conflicts with Redo"
            case kVK_ANSI_3: return "Conflicts with Screenshot (Full Screen)"
            case kVK_ANSI_4: return "Conflicts with Screenshot (Selection)"
            case kVK_ANSI_5: return "Conflicts with Screenshot Tool"
            case kVK_ANSI_V: return "Conflicts with Paste & Match Style (many apps)"
            case kVK_ANSI_N: return "Conflicts with New Folder (Finder)"
            case kVK_ANSI_A: return "Conflicts with Show Applications (Finder)"
            case kVK_ANSI_D: return "Conflicts with Show Desktop"
            case kVK_ANSI_Q: return "Conflicts with Log Out"
            case kVK_ANSI_T: return "Conflicts with Reopen Last Closed Tab"
            case kVK_ANSI_G: return "Conflicts with Find Previous"
            case kVK_ANSI_P: return "Conflicts with Tab Search (browsers)"
            default: break
            }
        }

        // ⌘⌥ combos
        if cmd && opt && !shift && !ctrl {
            switch kc {
            case kVK_Escape:  return "Conflicts with Force Quit"
            case kVK_ANSI_H:  return "Conflicts with Hide Others"
            case kVK_ANSI_M:  return "Conflicts with Minimize All"
            case kVK_ANSI_W:  return "Conflicts with Close All Windows"
            case kVK_Space:   return "Conflicts with Finder Search"
            case kVK_ANSI_D:  return "Conflicts with Toggle Dock Hiding"
            default: break
            }
        }

        // ⌘⌃ combos
        if cmd && ctrl && !opt && !shift {
            switch kc {
            case kVK_ANSI_Q: return "Conflicts with Lock Screen"
            case kVK_ANSI_F: return "Conflicts with Full Screen (many apps)"
            case kVK_Space:  return "Conflicts with Emoji & Symbols"
            default: break
            }
        }

        // ⌃ alone
        if ctrl && !cmd && !opt && !shift {
            switch kc {
            case kVK_Space: return "Conflicts with Input Source Switch"
            case kVK_F2:    return "Conflicts with Focus Menu Bar"
            case kVK_F3:    return "Conflicts with Mission Control"
            case kVK_F4:    return "Conflicts with Launchpad / App Exposé"
            default: break
            }
        }

        // ⌘⌥⇧ combos
        if cmd && opt && shift && !ctrl {
            switch kc {
            case kVK_ANSI_V: return "Conflicts with Paste & Match Style (many apps)"
            default: break
            }
        }

        return nil
    }
}

// MARK: - Hotkey Display Helpers

private enum HotkeyDisplay {
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command)  { mods |= UInt32(cmdKey) }
        if flags.contains(.option)   { mods |= UInt32(optionKey) }
        if flags.contains(.control)  { mods |= UInt32(controlKey) }
        if flags.contains(.shift)    { mods |= UInt32(shiftKey) }
        return mods
    }

    static func nsFlags(fromCarbon mods: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if mods & UInt32(cmdKey)     != 0 { flags.insert(.command) }
        if mods & UInt32(optionKey)  != 0 { flags.insert(.option) }
        if mods & UInt32(controlKey) != 0 { flags.insert(.control) }
        if mods & UInt32(shiftKey)   != 0 { flags.insert(.shift) }
        return flags
    }

    static func string(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option)  { parts.append("⌥") }
        if flags.contains(.shift)   { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(keyName(for: keyCode))
        return parts.joined()
    }

    static func string(carbonKeyCode: UInt32, carbonModifiers: UInt32) -> String {
        string(keyCode: UInt16(carbonKeyCode), flags: nsFlags(fromCarbon: carbonModifiers))
    }

    private static let keyNameMap: [UInt16: String] = [
        UInt16(kVK_ANSI_A): "A", UInt16(kVK_ANSI_B): "B", UInt16(kVK_ANSI_C): "C",
        UInt16(kVK_ANSI_D): "D", UInt16(kVK_ANSI_E): "E", UInt16(kVK_ANSI_F): "F",
        UInt16(kVK_ANSI_G): "G", UInt16(kVK_ANSI_H): "H", UInt16(kVK_ANSI_I): "I",
        UInt16(kVK_ANSI_J): "J", UInt16(kVK_ANSI_K): "K", UInt16(kVK_ANSI_L): "L",
        UInt16(kVK_ANSI_M): "M", UInt16(kVK_ANSI_N): "N", UInt16(kVK_ANSI_O): "O",
        UInt16(kVK_ANSI_P): "P", UInt16(kVK_ANSI_Q): "Q", UInt16(kVK_ANSI_R): "R",
        UInt16(kVK_ANSI_S): "S", UInt16(kVK_ANSI_T): "T", UInt16(kVK_ANSI_U): "U",
        UInt16(kVK_ANSI_V): "V", UInt16(kVK_ANSI_W): "W", UInt16(kVK_ANSI_X): "X",
        UInt16(kVK_ANSI_Y): "Y", UInt16(kVK_ANSI_Z): "Z",
        UInt16(kVK_ANSI_0): "0", UInt16(kVK_ANSI_1): "1", UInt16(kVK_ANSI_2): "2",
        UInt16(kVK_ANSI_3): "3", UInt16(kVK_ANSI_4): "4", UInt16(kVK_ANSI_5): "5",
        UInt16(kVK_ANSI_6): "6", UInt16(kVK_ANSI_7): "7", UInt16(kVK_ANSI_8): "8",
        UInt16(kVK_ANSI_9): "9",
        UInt16(kVK_Space): "␣", UInt16(kVK_Return): "↩", UInt16(kVK_Tab): "⇥",
        UInt16(kVK_Escape): "⎋", UInt16(kVK_Delete): "⌫",
        UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3",
        UInt16(kVK_F4): "F4", UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6",
        UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8", UInt16(kVK_F9): "F9",
        UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
    ]

    private static func keyName(for keyCode: UInt16) -> String {
        keyNameMap[keyCode] ?? "Key(\(keyCode))"
    }
}
