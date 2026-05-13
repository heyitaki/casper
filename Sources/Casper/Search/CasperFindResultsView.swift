// CASPER: VS Code-style grouped Find sidebar. Replaces the flat NSTableView (FileExplorerSearchResultsTableView) when CasperFindUIConfig.useGroupedFindResults is on: hits are folded under per-file collapsible headers (icon + bold filename + gray dir + hit-count badge); hit rows render the matched line with every query occurrence highlighted and a leading ellipsis when the match sits past the first ~12 chars. Delete this whole feature once upstream cmux ships a grouped Find UI.

import AppKit

@MainActor
final class CasperFindResultsView: NSScrollView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onFocus: (() -> Void)?
    /// Called with the absolute path of the row's file plus the 1-indexed
    /// (line, column) of the match. For group-header rows `(1, 1)` is sent
    /// (open the file at the top).
    var onOpenFilePreview: ((String, Int, Int) -> Void)?

    private let outlineView: CasperFindOutlineView
    private let dataSource: CasperFindOutlineDataSource

    private var query: String = ""
    private var groupItems: [CasperFindGroupItem] = []
    private var groupItemByPath: [String: CasperFindGroupItem] = [:]
    private var collapsedPaths: Set<String> = []

    init() {
        outlineView = CasperFindOutlineView()
        dataSource = CasperFindOutlineDataSource()
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        horizontalScrollElasticity = .none
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = false

        outlineView.headerView = nil
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.style = .plain
        outlineView.selectionHighlightStyle = .regular
        outlineView.rowSizeStyle = .custom
        // CASPER: chevron is drawn manually inside CasperFindGroupHeaderCellView at a known x,
        // so the auto outline-cell is hidden (frameOfOutlineCell returns .zero) and per-level
        // indentation is suppressed — group and hit cell views both start at x=0, and their
        // internal layout (icon at +Layout.iconX, hit text at +Layout.iconX) gives consistent
        // alignment without depending on NSOutlineView's chevron-width quirks.
        outlineView.indentationPerLevel = 0
        outlineView.allowsMultipleSelection = false
        outlineView.allowsEmptySelection = true
        outlineView.autoresizesOutlineColumn = false
        // CASPER: pin the currently-scrolled group header to the top of the viewport so the
        // user can see which file the visible hits belong to while scrolling long result lists.
        outlineView.floatsGroupRows = true
        outlineView.backgroundColor = .clear
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.autosaveExpandedItems = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("CasperFindResultsColumn"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        column.minWidth = 60
        column.width = 220
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        dataSource.host = self
        outlineView.dataSource = dataSource
        outlineView.delegate = dataSource
        outlineView.target = self
        outlineView.action = #selector(handleClick)
        outlineView.doubleAction = #selector(handleDoubleClick)
        outlineView.onCommit = { [weak self] in self?.onCommit?() }
        outlineView.onCancel = { [weak self] in self?.onCancel?() }
        outlineView.onFocus = { [weak self] in self?.onFocus?() }

        documentView = outlineView
    }

    // MARK: - Snapshot ingestion

    func apply(_ snapshot: FileSearchSnapshot) {
        query = snapshot.query
        let groups = CasperFindGrouper.group(snapshot.results)
        let nextItems = groups.map { CasperFindGroupItem(group: $0) }
        groupItems = nextItems
        groupItemByPath = Dictionary(uniqueKeysWithValues: nextItems.map { ($0.group.relativePath, $0) })
        outlineView.reloadData()
        for item in nextItems where !collapsedPaths.contains(item.group.relativePath) {
            outlineView.expandItem(item)
        }
        if outlineView.selectedRow < 0, outlineView.numberOfRows > 0 {
            outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    // MARK: - Selection / keyboard interop

    func moveSelection(by delta: Int) {
        let total = outlineView.numberOfRows
        guard total > 0 else { return }
        let current = outlineView.selectedRow
        let starting = current >= 0 ? current : (delta >= 0 ? -1 : total)
        let target = min(max(starting + delta, 0), total - 1)
        outlineView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        outlineView.scrollRowToVisible(target)
    }

    func openSelected() {
        let row = outlineView.selectedRow
        guard row >= 0 else { return }
        openItem(atRow: row)
    }

    func focusOutline() -> Bool {
        guard let window else { return false }
        return window.makeFirstResponder(outlineView)
    }

    var rowCount: Int { outlineView.numberOfRows }

    // MARK: - Click handling

    @objc private func handleClick(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0 else { return }
        guard let item = outlineView.item(atRow: row) else { return }
        if let group = item as? CasperFindGroupItem {
            toggleGroup(group)
        }
    }

    @objc private func handleDoubleClick(_ sender: Any?) {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        guard row >= 0 else { return }
        openItem(atRow: row)
    }

    private func openItem(atRow row: Int) {
        guard let item = outlineView.item(atRow: row) else { return }
        if let hit = item as? CasperFindHitItem {
            onOpenFilePreview?(hit.hit.path, hit.hit.lineNumber, hit.hit.columnNumber)
        } else if let group = item as? CasperFindGroupItem {
            onOpenFilePreview?(group.group.path, 1, 1)
        }
    }

    private func toggleGroup(_ group: CasperFindGroupItem) {
        if outlineView.isItemExpanded(group) {
            outlineView.collapseItem(group)
            collapsedPaths.insert(group.group.relativePath)
        } else {
            outlineView.expandItem(group)
            collapsedPaths.remove(group.group.relativePath)
        }
    }

    // MARK: - Data source helpers

    fileprivate var groupsForDataSource: [CasperFindGroupItem] { groupItems }
    fileprivate var queryForRendering: String { query }

    fileprivate func reloadGroupRow(for group: CasperFindGroupItem) {
        let row = outlineView.row(forItem: group)
        guard row >= 0 else { return }
        outlineView.reloadItem(group)
    }
}

// MARK: - Outline view subclass

@MainActor
final class CasperFindOutlineView: NSOutlineView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    var onFocus: (() -> Void)?

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        // CASPER: hide the automatic disclosure triangle. We draw our own
        // chevron at a fixed x inside CasperFindGroupHeaderCellView so it
        // visually aligns with the search field above (which sits at +8)
        // and the hit row icons below.
        return .zero
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .carriageReturn?, .enter?:
            onCommit?()
            return
        default:
            break
        }
        if event.keyCode == 53 { // Escape
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Item wrappers

@MainActor
final class CasperFindGroupItem: NSObject {
    let group: CasperFindFileGroup
    let hitItems: [CasperFindHitItem]

    init(group: CasperFindFileGroup) {
        self.group = group
        self.hitItems = group.hits.map { CasperFindHitItem(filePath: group.path, hit: $0) }
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? CasperFindGroupItem else { return false }
        return group.relativePath == other.group.relativePath
    }

    override var hash: Int { group.relativePath.hashValue }
}

@MainActor
final class CasperFindHitItem: NSObject {
    let filePath: String
    let hit: FileSearchResult

    init(filePath: String, hit: FileSearchResult) {
        self.filePath = filePath
        self.hit = hit
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? CasperFindHitItem else { return false }
        if hit.path != other.hit.path { return false }
        if hit.lineNumber != other.hit.lineNumber { return false }
        if hit.columnNumber != other.hit.columnNumber { return false }
        return true
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(hit.path)
        hasher.combine(hit.lineNumber)
        hasher.combine(hit.columnNumber)
        return hasher.finalize()
    }
}

// MARK: - Data source / delegate

@MainActor
private final class CasperFindOutlineDataSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var host: CasperFindResultsView?

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return host?.groupsForDataSource.count ?? 0 }
        if let group = item as? CasperFindGroupItem { return group.hitItems.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            return host?.groupsForDataSource[index] ?? NSObject()
        }
        if let group = item as? CasperFindGroupItem {
            return group.hitItems[index]
        }
        return NSObject()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is CasperFindGroupItem
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if item is CasperFindGroupItem { return 24 }
        return 20
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let group = item as? CasperFindGroupItem {
            let identifier = NSUserInterfaceItemIdentifier("CasperFindGroupHeaderCell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? CasperFindGroupHeaderCellView)
                ?? CasperFindGroupHeaderCellView(identifier: identifier)
            cell.configure(with: group.group, isExpanded: outlineView.isItemExpanded(group))
            return cell
        }
        if let hit = item as? CasperFindHitItem {
            let identifier = NSUserInterfaceItemIdentifier("CasperFindHitCell")
            let cell = (outlineView.makeView(withIdentifier: identifier, owner: nil) as? CasperFindHitCellView)
                ?? CasperFindHitCellView(identifier: identifier)
            cell.configure(with: hit.hit, query: host?.queryForRendering ?? "")
            return cell
        }
        return nil
    }

    // CASPER: mark per-file headers as group rows so NSOutlineView floats the
    // currently-scrolled header at the top of the viewport.
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is CasperFindGroupItem
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { true }

    func outlineViewItemDidExpand(_ notification: Notification) {
        refreshGroupCell(for: notification)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        refreshGroupCell(for: notification)
    }

    private func refreshGroupCell(for notification: Notification) {
        guard let group = notification.userInfo?["NSObject"] as? CasperFindGroupItem else { return }
        host?.reloadGroupRow(for: group)
    }
}

// MARK: - Shared layout constants

// CASPER: shared x positions for the grouped Find UI. The chevron is anchored
// at `chevronX` (matching the search field's leading inset above), and both the
// group icon AND the hit row text start at `iconX` so the two row types align
// pixel-for-pixel.
enum CasperFindCellLayout {
    static let chevronX: CGFloat = 8
    static let chevronWidth: CGFloat = 12
    static let chevronIconGap: CGFloat = 4
    static let iconWidth: CGFloat = 16
    static var iconX: CGFloat { chevronX + chevronWidth + chevronIconGap }
}

// MARK: - Header cell

@MainActor
final class CasperFindGroupHeaderCellView: NSTableCellView {
    private let chevronView = NSImageView()
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")
    private let badgeLabel = NSTextField(labelWithString: "")
    private let badgeBackground = NSView()

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        // CASPER: opaque background so the cell hides the hit rows underneath
        // when NSOutlineView floats this row as a sticky group header.
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.imageScaling = .scaleProportionallyDown
        chevronView.contentTintColor = .secondaryLabelColor
        chevronView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        addSubview(chevronView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 13, weight: .regular)
        nameLabel.textColor = .labelColor
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.maximumNumberOfLines = 1
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(nameLabel)

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        pathLabel.font = .systemFont(ofSize: 11, weight: .regular)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingHead
        pathLabel.maximumNumberOfLines = 1
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        addSubview(pathLabel)

        badgeBackground.translatesAutoresizingMaskIntoConstraints = false
        badgeBackground.wantsLayer = true
        badgeBackground.layer?.cornerRadius = 8
        badgeBackground.layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.25).cgColor
        addSubview(badgeBackground)

        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        badgeLabel.textColor = .secondaryLabelColor
        badgeLabel.alignment = .center
        badgeLabel.maximumNumberOfLines = 1
        badgeLabel.setContentHuggingPriority(.required, for: .horizontal)
        badgeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        badgeBackground.addSubview(badgeLabel)

        NSLayoutConstraint.activate([
            chevronView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CasperFindCellLayout.chevronX),
            chevronView.centerYAnchor.constraint(equalTo: centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: CasperFindCellLayout.chevronWidth),
            chevronView.heightAnchor.constraint(equalToConstant: 12),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CasperFindCellLayout.iconX),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: CasperFindCellLayout.iconWidth),
            iconView.heightAnchor.constraint(equalToConstant: CasperFindCellLayout.iconWidth),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            pathLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            pathLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeBackground.leadingAnchor, constant: -6),

            badgeBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            badgeBackground.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeBackground.heightAnchor.constraint(equalToConstant: 16),
            badgeBackground.widthAnchor.constraint(greaterThanOrEqualToConstant: 20),
            badgeBackground.widthAnchor.constraint(greaterThanOrEqualTo: badgeLabel.widthAnchor, constant: 12),

            badgeLabel.centerXAnchor.constraint(equalTo: badgeBackground.centerXAnchor),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeBackground.centerYAnchor),
        ])
        let shrinkWrap = badgeBackground.widthAnchor.constraint(equalTo: badgeLabel.widthAnchor, constant: 12)
        shrinkWrap.priority = .defaultHigh
        shrinkWrap.isActive = true
    }

    func configure(with group: CasperFindFileGroup, isExpanded: Bool) {
        let symbolName = isExpanded ? "chevron.down" : "chevron.right"
        chevronView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        iconView.image = CasperFindFileIcon.icon(forAbsolutePath: group.path, relativePath: group.relativePath)
        nameLabel.stringValue = group.filename
        pathLabel.stringValue = group.directoryDisplay
        pathLabel.isHidden = group.directoryDisplay.isEmpty
        badgeLabel.stringValue = "\(group.hits.count)"
        toolTip = group.relativePath
    }
}

// MARK: - Hit cell

@MainActor
final class CasperFindHitCellView: NSTableCellView {
    private let previewLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        previewLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        previewLabel.textColor = .secondaryLabelColor
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 1
        previewLabel.allowsDefaultTighteningForTruncation = false
        addSubview(previewLabel)

        NSLayoutConstraint.activate([
            // CASPER: align hit text with the group icon's left edge so files and
            // their matches form a clean visual column under the search field.
            previewLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CasperFindCellLayout.iconX),
            previewLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            previewLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(with hit: FileSearchResult, query: String) {
        let slice = CasperFindPreviewSlicer.slice(preview: hit.preview, query: query)
        let attributed = NSMutableAttributedString(string: slice.text.isEmpty ? " " : slice.text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        if !slice.text.isEmpty {
            // Same hue as SwiftUI Color.orange used by feed-notification badges (FeedPanelView).
            let highlightColor = NSColor.orange.withAlphaComponent(0.45)
            let bounds = NSRange(location: 0, length: (slice.text as NSString).length)
            for range in slice.matchRanges where NSLocationInRange(range.location, bounds)
                && NSMaxRange(range) <= NSMaxRange(bounds) {
                attributed.addAttribute(.backgroundColor, value: highlightColor, range: range)
                attributed.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }
        previewLabel.attributedStringValue = attributed
        toolTip = "\(hit.relativePath):\(hit.lineNumber):\(hit.columnNumber)"
    }
}
