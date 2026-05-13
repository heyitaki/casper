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
    // CASPER: sticky group header rendered OUTSIDE NSOutlineView's
    // floatsGroupRows machinery. NSOutlineView's built-in floating chrome
    // wraps the row in an NSVisualEffectView that lets scrolling content
    // bleed through. Managing the sticky as our own opaque overlay (via
    // `addFloatingSubview(_:for:)`) gives us guaranteed opacity and full
    // control over the show/hide threshold.
    private let stickyContainer = CasperFindStickyHeaderContainer()
    private let stickyHeader: CasperFindGroupHeaderCellView
    private var stickyGroup: CasperFindGroupItem?
    private var stickyExpanded: Bool = false
    private var scrollObserver: NSObjectProtocol?

    private var query: String = ""
    private var groupItems: [CasperFindGroupItem] = []
    private var collapsedPaths: Set<String> = []

    init() {
        outlineView = CasperFindOutlineView()
        dataSource = CasperFindOutlineDataSource()
        stickyHeader = CasperFindGroupHeaderCellView(
            identifier: NSUserInterfaceItemIdentifier("CasperFindStickyHeaderCell")
        )
        super.init(frame: .zero)
        configure()
    }

    deinit {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configure() {
        translatesAutoresizingMaskIntoConstraints = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        horizontalScrollElasticity = .none
        // CASPER: disable vertical elastic bounce — without it, a hard upward
        // flick on a short result set briefly drives documentVisibleRect.minY
        // above zero and flashes the sticky overlay on a list that doesn't
        // even scroll.
        verticalScrollElasticity = .none
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = false
        // CASPER: reserve the top 24pt for the sticky overlay so AppKit
        // navigation (scrollRowToVisible, arrow-key scroll-to-selection) keeps
        // rows out of the area the overlay covers. At scroll origin the band
        // is empty (sticky is hidden); once the user scrolls the sticky
        // fills that reserved space.
        contentInsets = NSEdgeInsets(top: 24, left: 0, bottom: 0, right: 0)

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
        // CASPER: floatsGroupRows is OFF — see `stickyContainer` comment in the
        // property block. We render the pinned group header ourselves so we
        // can guarantee opacity (NSOutlineView's built-in floating chrome
        // composites a vibrancy view behind the row that leaks scrolling
        // content through).
        outlineView.floatsGroupRows = false
        outlineView.backgroundColor = .clear
        outlineView.intercellSpacing = NSSize(width: 0, height: 0)
        outlineView.autosaveExpandedItems = false
        // CASPER: breathing room above the first row lives outside the scroll
        // view (as a top-anchor constant in FileExplorerView). Doing it that
        // way means NSClipView's bounds-clipping fully hides rows scrolling
        // past the floating group header — vs `contentInsets.top` which lets
        // content render in the inset region above the floating row.

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

        setupStickyHeader()
    }

    private func setupStickyHeader() {
        stickyContainer.translatesAutoresizingMaskIntoConstraints = false
        stickyContainer.isHidden = true
        stickyContainer.onToggle = { [weak self] in
            guard let self, let group = self.stickyGroup else { return }
            self.toggleGroup(group)
        }

        stickyHeader.translatesAutoresizingMaskIntoConstraints = false
        stickyContainer.addSubview(stickyHeader)

        // CASPER: addFloatingSubview keeps the view pinned to the scroll
        // view's coordinate system regardless of document-view scroll, so the
        // sticky stays at the top edge as the user scrolls.
        addFloatingSubview(stickyContainer, for: .vertical)

        NSLayoutConstraint.activate([
            stickyContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            stickyContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stickyContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stickyContainer.heightAnchor.constraint(equalToConstant: 24),

            stickyHeader.topAnchor.constraint(equalTo: stickyContainer.topAnchor),
            stickyHeader.leadingAnchor.constraint(equalTo: stickyContainer.leadingAnchor),
            stickyHeader.trailingAnchor.constraint(equalTo: stickyContainer.trailingAnchor),
            stickyHeader.bottomAnchor.constraint(equalTo: stickyContainer.bottomAnchor),
        ])

        contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateStickyHeader()
            }
        }
        updateStickyHeader()
    }

    private func updateStickyHeader() {
        let scrollY = contentView.documentVisibleRect.minY
        guard scrollY > 0.5 else {
            stickyGroup = nil
            stickyContainer.isHidden = true
            return
        }

        // Find the topmost group whose row sits at-or-above the visible top.
        // We probe a few pixels INTO the visible area so a group header that's
        // exactly at the top still counts as "covered" by the sticky.
        let probeY = scrollY + 1
        let topRow = outlineView.row(at: NSPoint(x: 0, y: probeY))
        guard topRow >= 0 else {
            stickyGroup = nil
            stickyContainer.isHidden = true
            return
        }
        var group: CasperFindGroupItem?
        var r = topRow
        while r >= 0 {
            if let item = outlineView.item(atRow: r) as? CasperFindGroupItem {
                group = item
                break
            }
            r -= 1
        }
        guard let group else {
            stickyGroup = nil
            stickyContainer.isHidden = true
            return
        }
        let isExpanded = outlineView.isItemExpanded(group)
        // CASPER: fires on every scroll tick; skip the full reconfigure
        // (NSImage symbol lookups, attributedString assignments, tooltip)
        // when the displayed group and chevron state are unchanged.
        if stickyGroup === group, stickyExpanded == isExpanded, !stickyContainer.isHidden {
            return
        }
        stickyGroup = group
        stickyExpanded = isExpanded
        stickyHeader.configure(with: group.group, isExpanded: isExpanded)
        stickyContainer.isHidden = false
    }

    // MARK: - Snapshot ingestion

    func apply(_ snapshot: FileSearchSnapshot) {
        query = snapshot.query
        let groups = CasperFindGrouper.group(snapshot.results)
        let nextItems = groups.map { CasperFindGroupItem(group: $0) }
        groupItems = nextItems
        outlineView.reloadData()
        for item in nextItems where !collapsedPaths.contains(item.group.relativePath) {
            outlineView.expandItem(item)
        }
        if outlineView.selectedRow < 0, outlineView.numberOfRows > 0 {
            outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateStickyHeader()
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
        updateStickyHeader()
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
        self.hitItems = group.hits.map { CasperFindHitItem(hit: $0) }
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? CasperFindGroupItem else { return false }
        return group.relativePath == other.group.relativePath
    }

    override var hash: Int { group.relativePath.hashValue }
}

@MainActor
final class CasperFindHitItem: NSObject {
    let hit: FileSearchResult

    init(hit: FileSearchResult) {
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

// MARK: - Sticky group header overlay

// CASPER: opaque container for the manually-managed sticky group header.
// Sits as a floating subview of the scroll view (via addFloatingSubview) so
// it stays pinned to the top during scroll. The opaqueness comes from a
// layer-backed color that exactly matches the sidebar's resolved tone — by
// being OUR view (not NSOutlineView's floating-row wrapper) it's free from
// the NSVisualEffectView translucency that NSOutlineView injects around its
// own floating rows.
@MainActor
final class CasperFindStickyHeaderContainer: NSView {
    static let backgroundColor: NSColor = NSColor(name: nil) { appearance in
        switch appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight]) {
        case .darkAqua?, .vibrantDark?:
            return NSColor(red: 0.137, green: 0.137, blue: 0.149, alpha: 1.0)
        default:
            return NSColor(red: 0.945, green: 0.945, blue: 0.949, alpha: 1.0)
        }
    }

    var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        super.updateLayer()
        let resolved = Self.backgroundColor.usingAppearance(effectiveAppearance)
        layer?.backgroundColor = resolved.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        onToggle?()
    }

    // CASPER: intercept all clicks within the sticky bounds so they route to
    // our toggle handler instead of falling through to the embedded cell's
    // chevron/badge subviews (which would otherwise no-op).
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }
}

@MainActor
fileprivate extension NSColor {
    func usingAppearance(_ appearance: NSAppearance) -> NSColor {
        var resolved: NSColor = self
        appearance.performAsCurrentDrawingAppearance {
            resolved = self.usingColorSpace(.deviceRGB) ?? self
        }
        return resolved
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
    // CASPER: hit text sits a couple points to the right of the icon's frame leading so it
    // visually aligns with the *glyph* of the SF Symbol (which is centered in the 16pt frame),
    // not the frame edge.
    static var hitTextX: CGFloat { iconX + 2 }
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

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBadgeBackgroundColor()
    }

    private func applyBadgeBackgroundColor() {
        let base = NSColor.tertiaryLabelColor.withAlphaComponent(0.25)
        badgeBackground.layer?.backgroundColor = base.usingAppearance(effectiveAppearance).cgColor
    }

    private func setupViews() {
        chevronView.translatesAutoresizingMaskIntoConstraints = false
        chevronView.imageScaling = .scaleProportionallyDown
        chevronView.contentTintColor = .secondaryLabelColor
        chevronView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        addSubview(chevronView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        // CASPER: SF Symbol style — tinted by contentTintColor so the glyph
        // adopts the same secondary tone as the surrounding label text.
        iconView.contentTintColor = .secondaryLabelColor
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
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
        // CASPER: truncate the END of the dirpath when it overflows so the
        // top-level part of the path stays visible (it's the disambiguating
        // bit). Truncating the head would hide which root folder the file
        // lives in.
        pathLabel.lineBreakMode = .byTruncatingTail
        pathLabel.maximumNumberOfLines = 1
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        addSubview(pathLabel)

        badgeBackground.translatesAutoresizingMaskIntoConstraints = false
        badgeBackground.wantsLayer = true
        badgeBackground.layer?.cornerRadius = 8
        addSubview(badgeBackground)
        applyBadgeBackgroundColor()

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
            // CASPER: baseline-align the smaller dirpath text with the larger
            // filename so they sit on the same visual line instead of the
            // dirpath floating above center.
            pathLabel.firstBaselineAnchor.constraint(equalTo: nameLabel.firstBaselineAnchor),
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
        iconView.image = CasperFindFileIcon.symbol(forRelativePath: group.relativePath)
        iconView.contentTintColor = CasperFindFileIcon.symbolTint(forRelativePath: group.relativePath)
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
        // CASPER: NSTextField with attributedStringValue will happily wrap long
        // lines unless the cell is explicitly forced into single-line mode.
        // Long lock-file lines (one giant base64 blob) were wrapping past the
        // row's 20pt height and getting clipped at the bottom.
        previewLabel.cell?.usesSingleLineMode = true
        previewLabel.cell?.wraps = false
        previewLabel.cell?.lineBreakMode = .byTruncatingTail
        addSubview(previewLabel)

        NSLayoutConstraint.activate([
            // CASPER: align hit text with the group icon's glyph (centered in
            // its 16pt frame) so files and their matches form a clean visual
            // column under the search field.
            previewLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: CasperFindCellLayout.hitTextX),
            previewLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            previewLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(with hit: FileSearchResult, query: String) {
        let slice = CasperFindPreviewSlicer.slice(preview: hit.preview, query: query)
        // CASPER: paragraph style forces tail truncation on long single-line
        // matches (lock files, minified JS, base64 blobs). Without it the
        // attributed string can still wrap past the 20pt row height.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributed = NSMutableAttributedString(string: slice.text.isEmpty ? " " : slice.text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
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
