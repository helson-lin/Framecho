import AppKit
import SwiftUI

struct CaptureLibraryInspector: View {
    let model: CaptureLibraryModel
    @State private var byteCount: Int64?
    @State private var pendingCloudDelete: CaptureLibraryItem?
    @State private var pendingCloudUpload: CaptureLibraryItem?

    private var items: [CaptureLibraryItem] { model.selectedItems }

    var body: some View {
        Group {
            if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Capture details")
                        .font(.headline)
                    Text("Select a screenshot or recording\nto take a closer look.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if items.count == 1, let item = items.first {
                            header(item)
                            information(item)
                            if let link = item.cloudURL { cloud(item, link: link) }
                        } else {
                            multipleSelection
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !items.isEmpty { actionBar }
        }
        .onChange(of: items.map(\.id)) { _, _ in
            pendingCloudUpload = nil
        }
        .task(id: items.map(\.thumbnailKey)) {
            byteCount = nil
            let urls = items.map(\.ownedURL)
            let scan = Task.detached(priority: .utility) {
                urls.reduce(Int64(0)) { total, url in
                    Task.isCancelled ? total : total + CaptureLibraryScanner.sizeOnDisk(of: url)
                }
            }
            let size = await withTaskCancellationHandler { await scan.value } onCancel: { scan.cancel() }
            guard !Task.isCancelled else { return }
            byteCount = size
        }
        .alert("Delete from cloud?", isPresented: Binding(
            get: { pendingCloudDelete != nil }, set: { if !$0 { pendingCloudDelete = nil } }
        ), presenting: pendingCloudDelete) { item in
            Button("Delete", role: .destructive) {
                model.deleteCloudCopy(item)
                pendingCloudDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingCloudDelete = nil }
        } message: { _ in
            Text("This permanently removes the cloud copy and breaks its share link. Your local capture stays in the Library.")
        }
    }

    // MARK: - Single capture

    private func header(_ item: CaptureLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { model.perform(.preview) } label: {
                CaptureLibraryThumbnail(item: item)
                    .aspectRatio(1.45, contentMode: .fit)
                    .clipShape(.rect(cornerRadius: 11))
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: item.isVideo ? "play.fill" : "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(10)
                    }
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .accessibilityLabel("Quick Look \(item.name)")
            .help("Open a large preview")

            VStack(alignment: .leading, spacing: 7) {
                Text(item.name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    statusBadge(item.kindTitle, symbol: item.isVideo ? "video" : "photo")
                    if item.hasDraft {
                        statusBadge(String(localized: "Draft"), symbol: "circle.lefthalf.filled")
                    } else if item.hasEdits {
                        statusBadge(String(localized: "Edited"), symbol: "slider.horizontal.3")
                    }
                    if item.cloudURL != nil {
                        statusBadge(String(localized: "Shared"), symbol: "link")
                    }
                }
            }
        }
    }

    private func information(_ item: CaptureLibraryItem) -> some View {
        section("Information") {
            detailRow("Dimensions", value: item.dimensions)
            if item.isVideo { detailRow("Duration", value: item.durationText) }
            detailRow("Size on disk", value: sizeText)
            detailRow("Created", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
            detailRow("Modified", value: item.modifiedAt.formatted(date: .abbreviated, time: .shortened))
        }
    }

    private func cloud(_ item: CaptureLibraryItem, link: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            section("Cloud") {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                    Text(link)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Copy") { model.copyLink(item) }
                        .controlSize(.small)
                        .accessibilityLabel("Copy Cloud Link")
                }
                .font(.system(size: 12))
                .padding(.vertical, 2)
            }
            HStack(spacing: 12) {
                if let url = URL(string: link) {
                    Link("Open Shared Capture", destination: url)
                }
                Spacer()
                Button("Delete from Cloud…", role: .destructive) { pendingCloudDelete = item }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
            }
            .font(.caption)
            .padding(.horizontal, 4)
            .disabled(model.isBusy)
        }
    }

    // MARK: - Several captures

    private var multipleSelection: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(Array(items.prefix(3))) { item in
                        CaptureLibraryThumbnail(item: item)
                            .frame(maxWidth: .infinity)
                            .frame(height: 68)
                            .clipShape(.rect(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                            }
                    }
                }
                Text("\(items.count) captures selected")
                    .font(.system(size: 16, weight: .semibold))
            }
            section("Selection") {
                let screenshots = items.filter { !$0.isVideo }.count
                detailRow("Screenshots", value: screenshots.formatted())
                detailRow("Recordings", value: (items.count - screenshots).formatted())
                if let totalDuration { detailRow("Total duration", value: totalDuration) }
                detailRow("Size on disk", value: sizeText)
                if let dateRange { detailRow("Date range", value: dateRange) }
            }
        }
    }

    private var totalDuration: String? {
        let durations = items.compactMap(\.duration).filter(\.isFinite)
        guard !durations.isEmpty else { return nil }
        return Duration.seconds(durations.reduce(0, +).rounded())
            .formatted(.time(pattern: durations.reduce(0, +) >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    private var dateRange: String? {
        guard let first = items.map(\.createdAt).min(), let last = items.map(\.createdAt).max() else { return nil }
        return (first..<max(last, first.addingTimeInterval(1))).formatted(.interval.day().month(.abbreviated).year())
    }

    // MARK: - Actions

    /// Labeled actions, so each is readable without hovering for a tooltip.
    private var actionBar: some View {
        let single = items.count == 1 ? items.first : nil
        return HStack(alignment: .top, spacing: 4) {
            if let single {
                LibraryInspectorAction(
                    title: single.isVideo ? "Edit" : "Annotate",
                    symbol: single.isVideo ? "film" : "pencil.tip.crop.circle",
                    isProminent: true
                ) { model.perform(.edit) }
            }
            LibraryInspectorAction(title: "Copy", symbol: "doc.on.doc") { model.perform(.copy) }
            LibraryInspectorAction(title: "Export", symbol: "square.and.arrow.up") { model.perform(.export) }
            if let single, single.cloudURL == nil, CloudUploader.shared.isConfigured {
                LibraryInspectorAction(title: "Share", symbol: "icloud.and.arrow.up") { pendingCloudUpload = single }
                    .popover(item: $pendingCloudUpload, arrowEdge: .top) { item in
                        CloudUploadOptionsPopover(suggestedTitle: item.name) { options in
                            model.upload(item, options: options)
                        }
                    }
            } else {
                LibraryInspectorAction(title: "Reveal", symbol: "folder") { model.perform(.reveal) }
            }
            moreActions(allowsRename: single != nil)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .overlay(alignment: .top) { Divider() }
        .disabled(model.isBusy)
    }

    private func moreActions(allowsRename: Bool) -> some View {
        Menu {
            if allowsRename {
                Button("Rename…", systemImage: "pencil") { model.perform(.rename) }
            }
            Button("Reveal in Finder", systemImage: "folder") { model.perform(.reveal) }
            Divider()
            Button("Move to Trash…", systemImage: "trash", role: .destructive) { model.perform(.trash) }
        } label: {
            LibraryInspectorActionLabel(title: "More", symbol: "ellipsis", isProminent: false)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(maxWidth: .infinity)
        .accessibilityLabel("More capture actions")
    }

    // MARK: - Building blocks

    private func section(_ title: LocalizedStringResource, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(spacing: 9) { rows() }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func detailRow(_ title: LocalizedStringResource, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(.secondary).fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.system(size: 12))
        .monospacedDigit()
    }

    private func statusBadge(_ title: String, symbol: String) -> some View {
        Label { Text(title) } icon: { Image(systemName: symbol) }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(0.055), in: Capsule())
    }

    private var sizeText: String {
        byteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? String(localized: "Calculating…")
    }
}

/// An icon tile over a short title. The primary action fills with the
/// accent color; the rest sit on a quiet fill.
private struct LibraryInspectorAction: View {
    let title: LocalizedStringResource
    let symbol: String
    var isProminent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LibraryInspectorActionLabel(title: title, symbol: symbol, isProminent: isProminent)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }
}

private struct LibraryInspectorActionLabel: View {
    let title: LocalizedStringResource
    let symbol: String
    let isProminent: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(isProminent ? Color.white : Color.primary)
                .frame(width: 40, height: 32)
                .background(
                    isProminent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.07)),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(Rectangle())
    }
}
