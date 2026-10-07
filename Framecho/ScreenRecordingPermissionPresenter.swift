import AppKit
import SwiftUI

/// Stays beside System Settings while the full-screen setup guide fades away.
@MainActor
final class ScreenRecordingPermissionPresenter {
    static let shared = ScreenRecordingPermissionPresenter()

    private var panel: NSPanel?

    private init() {}

    func show() {
        if let panel {
            panel.orderFrontRegardless()
            return
        }
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(720, visibleFrame.width - 48)
        let hosting = NSHostingView(rootView: ScreenRecordingPermissionGuide(
            onClose: { ScreenRecordingPermissionPresenter.shared.dismiss() }
        ).frame(width: width))
        let size = hosting.fittingSize
        let panel = PermissionGuidePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = String(localized: "Allow Screen Recording")
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + 24
        ))
        PreviewWindowCaptureExclusion.shared.register(window: panel)
        self.panel = panel
        AppPermissionCenter.shared.beginObserving()
        panel.orderFrontRegardless()
    }

    func dismiss() {
        guard let panel else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        AppPermissionCenter.shared.endObserving()
    }
}

private final class PermissionGuidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct ScreenRecordingPermissionGuide: View {
    let onClose: () -> Void

    @State private var center = AppPermissionCenter.shared

    var body: some View {
        HStack(spacing: 18) {
            PermissionAppIcon()
                .frame(width: 64, height: 64)
                .help("Drag the Framecho icon into the list, then turn it on.")

            VStack(alignment: .leading, spacing: 6) {
                Text("Allow Framecho in Screen & System Audio Recording")
                    .font(.system(size: 17, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Drag the Framecho icon into the list, then turn it on.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Open System Settings") { center.openSettings(for: .screenRecording) }
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                    Button("Reopen") { center.relaunch() }
                        .help("Turned it on in System Settings? Quit and reopen Framecho to apply it.")
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .keyboardShortcut(.cancelAction)
        }
        .padding(22)
        .background(.background, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18).strokeBorder(.separator, lineWidth: 1)
        }
        .onChange(of: center.isScreenRecordingGranted) { _, granted in
            if granted { onClose() }
        }
    }
}

/// Drag the application bundle's file URL, rather than a picture of its icon.
private struct PermissionAppIcon: NSViewRepresentable {
    func makeNSView(context: Context) -> PermissionAppIconView {
        let view = PermissionAppIconView()
        view.image = NSApp.applicationIconImage
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityLabel(String(localized: "Framecho app icon"))
        view.setAccessibilityHelp(String(localized: "Drag the Framecho icon into the list, then turn it on."))
        return view
    }

    func updateNSView(_ nsView: PermissionAppIconView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PermissionAppIconView, context: Context) -> CGSize? {
        CGSize(width: 64, height: 64)
    }
}

private final class PermissionAppIconView: NSImageView, NSDraggingSource {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let image else { return }
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Never let another drop target move the running application bundle.
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
