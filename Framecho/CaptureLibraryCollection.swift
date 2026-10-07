import AppKit
import SwiftUI

enum CaptureLibraryAction: String {
    case preview = "Quick Look"
    case edit = "Edit"
    case rename = "Rename…"
    case copy = "Copy"
    case copyLink = "Copy Link"
    case export = "Export…"
    case reveal = "Reveal in Finder"
    case trash = "Move to Trash"

    var title: String {
        switch self {
        case .preview: String(localized: "Quick Look")
        case .edit: String(localized: "Edit")
        case .rename: String(localized: "Rename…")
        case .copy: String(localized: "Copy")
        case .copyLink: String(localized: "Copy Link")
        case .export: String(localized: "Export…")
        case .reveal: String(localized: "Reveal in Finder")
        case .trash: String(localized: "Move to Trash")
        }
    }
}

/// Both layouts use NSCollectionView's reuse queue. Changing selection doesn't
/// reload the collection; data changes reconcile selection by stable media IDs.
struct CaptureLibraryCollection: NSViewRepresentable {
    let sections: [CaptureLibrarySection]
    let revision: Int
    let layout: CaptureLibraryLayout
    /// 0 is the smallest grid card, 1 the largest.
    let thumbnailScale: Double
    @Binding var selection: Set<String>
    let isBusy: Bool
    let onAction: (CaptureLibraryAction) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        let collection = LibraryCollectionView()
        collection.autoresizingMask = [.width]
        collection.setAccessibilityLabel(String(localized: "Captures"))
        collection.backgroundColors = [.clear]
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.allowsEmptySelection = true
        collection.configureLayout(layout)
        (collection.collectionViewLayout as? LibraryCollectionLayout)?.thumbnailScale = thumbnailScale
        collection.dataSource = context.coordinator
        collection.delegate = context.coordinator
        collection.command = { [weak coordinator = context.coordinator] action in
            guard let coordinator, !coordinator.parent.isBusy else { return }
            coordinator.parent.onAction(action)
        }
        collection.contextMenuProvider = { [weak coordinator = context.coordinator] event in
            coordinator?.menu(for: event)
        }
        scrollView.documentView = collection
        context.coordinator.collection = collection
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let old = coordinator.parent
        coordinator.parent = self
        guard let collection = coordinator.collection else { return }
        coordinator.updating = true
        defer { coordinator.updating = false }
        if old.revision != revision || old.layout != layout || coordinator.initialLoad {
            coordinator.initialLoad = false
            coordinator.indices = Dictionary(uniqueKeysWithValues: sections.enumerated().flatMap { section in
                section.element.items.enumerated().map { ($0.element.id, IndexPath(item: $0.offset, section: section.offset)) }
            })
            (collection.collectionViewLayout as? LibraryCollectionLayout)?.displayLayout = layout
            collection.reloadData()
            collection.collectionViewLayout?.invalidateLayout()
        }
        if old.thumbnailScale != thumbnailScale,
           let flow = collection.collectionViewLayout as? LibraryCollectionLayout {
            flow.thumbnailScale = thumbnailScale
            flow.invalidateLayout()
        }
        let paths = Set(selection.compactMap { coordinator.indices[$0] })
        if collection.selectionIndexPaths != paths { collection.selectionIndexPaths = paths }
    }

    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
        var parent: CaptureLibraryCollection
        weak var collection: LibraryCollectionView?
        var updating = false
        var initialLoad = true
        var indices: [String: IndexPath] = [:]

        init(_ parent: CaptureLibraryCollection) { self.parent = parent }

        func item(at indexPath: IndexPath) -> CaptureLibraryItem? {
            guard parent.sections.indices.contains(indexPath.section) else { return nil }
            let items = parent.sections[indexPath.section].items
            return items.indices.contains(indexPath.item) ? items[indexPath.item] : nil
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int {
            parent.sections.count
        }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            parent.sections.indices.contains(section) ? parent.sections[section].items.count : 0
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let cell = collectionView.makeItem(withIdentifier: LibraryCollectionItem.identifier, for: indexPath)
            if let cell = cell as? LibraryCollectionItem, let item = item(at: indexPath) {
                cell.configure(item, layout: parent.layout)
            }
            return cell
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
            at indexPath: IndexPath
        ) -> NSView {
            let view = collectionView.makeSupplementaryView(
                ofKind: kind, withIdentifier: LibrarySectionHeader.identifier, for: indexPath
            )
            if let header = view as? LibrarySectionHeader, parent.sections.indices.contains(indexPath.section) {
                let section = parent.sections[indexPath.section]
                header.configure(title: section.title ?? "", count: section.items.count)
            }
            return view
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            referenceSizeForHeaderInSection section: Int
        ) -> NSSize {
            hasTitle(section) ? NSSize(width: collectionView.bounds.width, height: 34) : .zero
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            layout collectionViewLayout: NSCollectionViewLayout,
            insetForSectionAt section: Int
        ) -> NSEdgeInsets {
            hasTitle(section)
                ? NSEdgeInsets(top: 2, left: 16, bottom: 14, right: 16)
                : NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        }

        private func hasTitle(_ section: Int) -> Bool {
            parent.sections.indices.contains(section) && parent.sections[section].title != nil
        }

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            selectionChanged()
        }

        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            selectionChanged()
        }

        func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
            (item as? LibraryCollectionItem)?.clearContent()
        }

        func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
            if let cell = item as? LibraryCollectionItem, let entry = self.item(at: indexPath) {
                cell.configure(entry, layout: parent.layout)
            }
        }

        private func selectionChanged() {
            guard !updating, let collection else { return }
            parent.selection = Set(collection.selectionIndexPaths.compactMap { item(at: $0)?.id })
        }

        func menu(for event: NSEvent) -> NSMenu? {
            guard let collection,
                  let path = collection.indexPathForItem(at: collection.convert(event.locationInWindow, from: nil)) else { return nil }
            if !collection.selectionIndexPaths.contains(path) {
                collection.selectionIndexPaths = [path]
                selectionChanged()
            }
            let count = collection.selectionIndexPaths.count
            let menu = NSMenu()
            menu.autoenablesItems = false
            var actions: [CaptureLibraryAction] = [.preview, .edit, .rename, .copy]
            if count == 1, item(at: path)?.cloudURL != nil { actions.append(.copyLink) }
            actions += [.export, .reveal, .trash]
            for action in actions {
                if action == .copy || action == .trash { menu.addItem(.separator()) }
                let item = NSMenuItem(title: action.title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = action.rawValue
                item.isEnabled = !parent.isBusy && (!(action == .rename || action == .edit || action == .preview) || count == 1)
                menu.addItem(item)
            }
            return menu
        }

        @objc private func performMenuAction(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String,
                  let action = CaptureLibraryAction(rawValue: raw), !parent.isBusy else { return }
            parent.onAction(action)
        }
    }
}

final class LibraryCollectionView: NSCollectionView {
    var command: ((CaptureLibraryAction) -> Void)?
    var contextMenuProvider: ((NSEvent) -> NSMenu?)?

    func configureLayout(_ displayLayout: CaptureLibraryLayout) {
        let flow = LibraryCollectionLayout()
        flow.displayLayout = displayLayout
        // Installing a layout initializes AppKit's data-source/reuse machinery.
        // Registering first loses the class registration and makes the first
        // dequeue fall back to a nonexistent CaptureLibraryCell nib.
        collectionViewLayout = flow
        register(LibraryCollectionItem.self, forItemWithIdentifier: LibraryCollectionItem.identifier)
        register(
            LibrarySectionHeader.self,
            forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
            withIdentifier: LibrarySectionHeader.identifier
        )
    }

    override func menu(for event: NSEvent) -> NSMenu? { contextMenuProvider?(event) }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, !selectionIndexPaths.isEmpty { command?(.preview) }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), event.charactersIgnoringModifiers == "c" { command?(.copy); return }
        if flags.contains(.command), event.keyCode == 51 { command?(.trash); return }
        if !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) {
            if event.keyCode == 49 { command?(.preview); return }
            if event.keyCode == 36 { command?(.rename); return }
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) { command?(.copy) }
}

final class LibraryCollectionLayout: NSCollectionViewFlowLayout {
    var displayLayout: CaptureLibraryLayout = .grid
    var thumbnailScale: Double = 0.3

    override func prepare() {
        let width = max(200, collectionView?.enclosingScrollView?.contentSize.width ?? 800)
        preparedWidth = collectionView?.bounds.width ?? 0
        minimumInteritemSpacing = 16
        minimumLineSpacing = displayLayout == .grid ? 16 : 2
        if displayLayout == .grid {
            let target = 180 + 200 * min(max(thumbnailScale, 0), 1)
            let columns = max(1, floor((width - 16) / (target + 16)))
            let cellWidth = floor((width - 32 - (columns - 1) * 16) / columns)
            itemSize = CGSize(width: cellWidth, height: floor(cellWidth * 0.625) + 62)
        } else {
            itemSize = CGSize(width: width - 32, height: 46)
        }
        super.prepare()
    }

    /// AppKit applies the new bounds before asking, so compare against the
    /// width the current layout was built for, not the collection's bounds.
    private var preparedWidth: CGFloat = 0

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != preparedWidth
    }
}

/// A date heading with its capture count, aligned with the cards' content.
final class LibrarySectionHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("CaptureLibrarySectionHeader")
    private let host = NSHostingView(rootView: LibrarySectionHeaderContent(title: "", count: 0))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, count: Int) {
        host.rootView = LibrarySectionHeaderContent(title: title, count: count)
    }
}

private struct LibrarySectionHeaderContent: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(count, format: .number)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, 22)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

final class LibraryCollectionItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("CaptureLibraryCell")
    private var entry: CaptureLibraryItem?
    private var displayLayout: CaptureLibraryLayout = .grid
    private var host: NSHostingView<LibraryCellContent>?

    override func loadView() {
        let host = NSHostingView(rootView: LibraryCellContent(item: nil, layout: .grid, selected: false))
        host.sizingOptions = []
        self.host = host
        view = host
    }

    override var isSelected: Bool { didSet { updateContent() } }

    func configure(_ entry: CaptureLibraryItem, layout: CaptureLibraryLayout) {
        self.entry = entry
        displayLayout = layout
        updateContent()
    }

    func clearContent() {
        entry = nil
        updateContent()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        clearContent()
    }

    private func updateContent() {
        _ = view
        host?.rootView = LibraryCellContent(item: entry, layout: displayLayout, selected: isSelected)
    }
}

struct LibraryCellContent: View {
    let item: CaptureLibraryItem?
    let layout: CaptureLibraryLayout
    let selected: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Group {
            if let item {
                Group {
                    if layout == .grid {
                        VStack(alignment: .leading, spacing: 8) {
                            thumbnail(item)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            labels(item)
                                .padding(.horizontal, 4)
                                .padding(.bottom, 4)
                        }
                        .padding(6)
                        .background(cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(cardStroke, lineWidth: selected ? 2 : 0.5)
                        }
                    } else {
                        listRow(item)
                    }
                }
                .onHover { isHovering = $0 }
                .onChange(of: item.id) { _, _ in isHovering = false }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: selected)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel(for: item))
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            } else { Color.clear }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func accessibilityLabel(for item: CaptureLibraryItem) -> String {
        var parts = [item.name, item.kindTitle, item.subtitle]
        if item.hasDraft { parts.append(String(localized: "Draft")) }
        if item.cloudURL != nil { parts.append(String(localized: "Shared")) }
        return parts.joined(separator: ", ")
    }

    /// A Finder-style row: the selection fills with the accent color and
    /// the text turns white. Columns follow LibraryListColumn, so they match
    /// the header at any width.
    private func listRow(_ item: CaptureLibraryItem) -> some View {
        let secondary: Color = selected ? .white.opacity(0.85) : .secondary
        return GeometryReader { proxy in
            let columns = LibraryListColumn.visible(forContentWidth: proxy.size.width - 12)
            HStack(spacing: LibraryListColumn.spacing) {
                HStack(spacing: 10) {
                    thumbnail(item).frame(width: 54, height: 34)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.hasDraft { LibraryDraftBadge(onAccent: selected) }
                    if item.cloudURL != nil {
                        Image(systemName: "link")
                            .foregroundStyle(secondary)
                            .help("Shared to the cloud")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(columns) { column in
                    Text(column.value(for: item))
                        .foregroundStyle(secondary)
                        .frame(width: column.width, alignment: column.alignment)
                }
            }
            .padding(.horizontal, 6)
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .font(.system(size: 12.5))
        .monospacedDigit()
        .lineLimit(1)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(
            selected ? Color.accentColor : Color.primary.opacity(isHovering ? 0.04 : 0),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private var cardFill: Color {
        if selected { return Color.accentColor.opacity(0.14) }
        return Color.primary.opacity(isHovering ? 0.035 : 0.012)
    }

    private var cardStroke: Color {
        if selected { return Color.accentColor.opacity(contrast == .increased ? 1 : 0.85) }
        return Color.primary.opacity(0.08)
    }

    private func labels(_ item: CaptureLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
            }
            Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func thumbnail(_ item: CaptureLibraryItem) -> some View {
        CaptureLibraryThumbnail(item: item)
            .clipShape(.rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo {
                    LibraryThumbnailBadge {
                        Label(item.durationText, systemImage: "play.fill")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if layout == .grid, item.hasDraft {
                    LibraryThumbnailBadge {
                        Text("Draft").font(.system(size: 10, weight: .semibold))
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if layout == .grid, item.cloudURL != nil {
                    LibraryThumbnailBadge {
                        Image(systemName: "link").font(.system(size: 10, weight: .semibold))
                    }
                    .help("Shared to the cloud")
                }
            }
    }
}

/// A dark capsule over a thumbnail, legible on light and dark captures.
private struct LibraryThumbnailBadge<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal, 6).padding(.vertical, 3)
            .foregroundStyle(.white)
            .background(.black.opacity(0.65), in: Capsule())
            .padding(7)
    }
}

/// Marks a recording with unsaved edits by word, not only by color.
struct LibraryDraftBadge: View {
    var onAccent = false

    var body: some View {
        Text("Draft")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(onAccent ? Color.white : Color.orange)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(onAccent ? Color.white.opacity(0.22) : Color.orange.opacity(0.14), in: Capsule())
    }
}

/// The list's optional columns, after Name. They drop out lowest priority
/// first when the width can't hold them, so neither the header nor a row
/// ever asks for more width than the window gives it.
enum LibraryListColumn: CaseIterable, Identifiable {
    case created, kind, duration, dimensions

    static let spacing: CGFloat = 12
    static let minimumNameWidth: CGFloat = 200
    /// Rows sit inside the 16pt section inset plus the row's own padding.
    static let leadingInset: CGFloat = 22

    var id: Self { self }

    var width: CGFloat {
        switch self {
        case .created: 150
        case .kind: 110
        case .duration: 56
        case .dimensions: 96
        }
    }

    var alignment: Alignment {
        switch self {
        case .created, .kind: .leading
        case .duration, .dimensions: .trailing
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .created: "Created"
        case .kind: "Kind"
        case .duration: "Duration"
        case .dimensions: "Dimensions"
        }
    }

    func value(for item: CaptureLibraryItem) -> String {
        switch self {
        case .created: item.createdAt.formatted(date: .abbreviated, time: .shortened)
        case .kind: item.kindTitle
        case .duration: item.isVideo ? item.durationText : "—"
        case .dimensions: item.pixelWidth > 0 ? item.dimensions : "—"
        }
    }

    /// The columns that fit beside a readable name, in display order.
    static func visible(forContentWidth width: CGFloat) -> [Self] {
        var remaining = width - minimumNameWidth
        var fitting: Set<Self> = []
        for column in allCases where remaining >= column.width + spacing {
            fitting.insert(column)
            remaining -= column.width + spacing
        }
        return [.kind, .dimensions, .duration, .created].filter(fitting.contains)
    }
}

/// Column titles above the list. Name and Created sort when clicked;
/// clicking Created again flips between newest and oldest first.
struct LibraryListHeader: View {
    @Binding var sortOrder: CaptureLibrarySort
    @State private var width: CGFloat = 0

    /// Always-visible scroll bars take width from the rows below but not from
    /// the header, so the header gives it up too to keep columns aligned.
    private static var scrollerWidth: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            : 0
    }

    var body: some View {
        let columns = LibraryListColumn.visible(
            forContentWidth: width - 2 * LibraryListColumn.leadingInset - Self.scrollerWidth
        )
        HStack(spacing: LibraryListColumn.spacing) {
            column("Name", sort: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(columns) { item in
                Group {
                    if item == .created {
                        column(item.title, sort: sortOrder == .newest ? .oldest : .newest,
                               isActive: sortOrder == .newest || sortOrder == .oldest)
                    } else {
                        Text(item.title)
                    }
                }
                .frame(width: item.width, alignment: item.alignment)
            }
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.leading, LibraryListColumn.leadingInset)
        .padding(.trailing, LibraryListColumn.leadingInset + Self.scrollerWidth)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .overlay(alignment: .bottom) { Divider().padding(.horizontal, 16) }
    }

    private func column(_ title: LocalizedStringResource, sort: CaptureLibrarySort, isActive: Bool? = nil) -> some View {
        let active = isActive ?? (sortOrder == sort)
        return Button {
            sortOrder = sort
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if active {
                    Image(systemName: sortOrder == .oldest ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
            }
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? [.isSelected] : [])
        .help(String(localized: "Sort by \(String(localized: title))"))
    }
}
