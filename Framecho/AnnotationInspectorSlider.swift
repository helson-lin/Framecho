//
//  AnnotationInspectorSlider.swift
//  Framecho
//

import AppKit
import SwiftUI

/// Display and editing rules for an inspector value. The bound value always
/// stays in model units; `multiplier` only transforms what the user sees and
/// types (for example, 0.45 is displayed as 45%).
struct InspectorValueFormat {
    let multiplier: CGFloat
    let fractionDigits: Int
    let suffix: String
    let showsPositiveSign: Bool
    let step: CGFloat
    let acceptedSuffixes: [String]

    static let integer = InspectorValueFormat(
        multiplier: 1,
        fractionDigits: 0,
        suffix: "",
        showsPositiveSign: false,
        step: 1,
        acceptedSuffixes: []
    )

    static let pixels = InspectorValueFormat(
        multiplier: 1,
        fractionDigits: 0,
        suffix: " px",
        showsPositiveSign: false,
        step: 1,
        acceptedSuffixes: ["pixels", "pixel", "px"]
    )

    static func percent(
        signed: Bool = false,
        fractionDigits: Int = 0
    ) -> InspectorValueFormat {
        InspectorValueFormat(
            multiplier: 100,
            fractionDigits: fractionDigits,
            suffix: "%",
            showsPositiveSign: signed,
            step: step(forFractionDigits: fractionDigits) / 100,
            acceptedSuffixes: ["%"]
        )
    }

    static func degrees(signed: Bool = false) -> InspectorValueFormat {
        InspectorValueFormat(
            multiplier: 1,
            fractionDigits: 0,
            suffix: "°",
            showsPositiveSign: signed,
            step: 1,
            acceptedSuffixes: ["degrees", "degree", "deg", "°"]
        )
    }

    static func decimal(fractionDigits: Int) -> InspectorValueFormat {
        InspectorValueFormat(
            multiplier: 1,
            fractionDigits: fractionDigits,
            suffix: "",
            showsPositiveSign: false,
            step: step(forFractionDigits: fractionDigits),
            acceptedSuffixes: []
        )
    }

    static func magnification(fractionDigits: Int) -> InspectorValueFormat {
        InspectorValueFormat(
            multiplier: 1,
            fractionDigits: fractionDigits,
            suffix: "×",
            showsPositiveSign: false,
            step: step(forFractionDigits: fractionDigits),
            acceptedSuffixes: ["×", "x"]
        )
    }

    func displayString(for value: CGFloat) -> String {
        let scaledValue = value * multiplier
        let number = formattedNumber(scaledValue)
        let sign = showsPositiveSign && roundedForDisplay(scaledValue) > 0 ? "+" : ""
        return sign + number + suffix
    }

    func editingString(for value: CGFloat) -> String {
        formattedNumber(value * multiplier)
    }

    func parse(_ text: String) -> CGFloat? {
        var numericText = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "−", with: "-")

        for acceptedSuffix in acceptedSuffixes {
            numericText = numericText.replacingOccurrences(
                of: acceptedSuffix,
                with: "",
                options: [.caseInsensitive, .anchored, .backwards]
            )
        }

        numericText = numericText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let parsed = try? FloatingPointFormatStyle<Double>.number
            .parseStrategy
            .parse(numericText), parsed.isFinite else {
            return nil
        }

        return CGFloat(parsed) / multiplier
    }

    private func formattedNumber(_ value: CGFloat) -> String {
        let normalizedValue = roundedForDisplay(value)
        return Double(normalizedValue).formatted(
            .number
                .precision(.fractionLength(fractionDigits))
                .grouping(.never)
        )
    }

    private func roundedForDisplay(_ value: CGFloat) -> CGFloat {
        let scale = CGFloat(pow(10, Double(fractionDigits)))
        let rounded = (value * scale).rounded() / scale
        return abs(rounded) < CGFloat.ulpOfOne ? 0 : rounded
    }

    private static func step(forFractionDigits fractionDigits: Int) -> CGFloat {
        1 / CGFloat(pow(10, Double(max(fractionDigits, 0))))
    }
}

/// A compact inspector slider: the label on the left, the exact value on the
/// right, and a fill that shows where the value sits in its range (signed ranges
/// fill outward from a zero mark). Pressing or dragging anywhere on the field
/// sets the value at that point; a handle marks the fill edge while it's in use,
/// and the value steps aside so the handle never covers it. Dragging past
/// either end stretches the field a little and springs back. Hold Option to
/// drag finely, click the value to type one, and use the arrow keys (Shift for
/// bigger steps) while focused.
struct InspectorSlider: View {
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let format: InspectorValueFormat

    private static let fineDragMultiplier: CGFloat = 0.1
    /// Drag distance around zero that lands exactly on zero for signed ranges.
    private static let zeroDetentDistance: CGFloat = 4
    private static let valueWidth: CGFloat = 46
    private static let contentInset: CGFloat = 8
    /// Space kept between the handle and the value beside it.
    private static let handleGap: CGFloat = 6
    private static let handleSize = CGSize(width: 3, height: 14)
    /// Farthest the field stretches when dragged past an end.
    private static let maxStretch: CGFloat = 8
    /// Keyboard steps with Shift move this fraction of the range.
    private static let largeStepFraction: CGFloat = 0.1

    private static let labelFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @FocusState private var focusedPart: FocusedPart?
    @State private var draftText = ""
    @State private var editingBaselineText = ""
    @State private var valueSelection: TextSelection?
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var fieldWidth: CGFloat = 0
    /// Signed overshoot past an end while dragging: negative stretches the
    /// leading edge, positive the trailing edge.
    @State private var stretch: CGFloat = 0
    /// Fine drags move relative to where Option was pressed.
    @State private var fineAnchor: (location: CGFloat, value: CGFloat)?

    private enum FocusedPart: Hashable {
        case slider
        case value
    }

    init(
        _ title: LocalizedStringResource,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        format: InspectorValueFormat
    ) {
        self.init(String(localized: title), value: value, range: range, format: format)
    }

    @_disfavoredOverload
    init<Title: StringProtocol>(
        _ title: Title,
        value: Binding<CGFloat>,
        range: ClosedRange<CGFloat>,
        format: InspectorValueFormat
    ) {
        self.title = String(title)
        self._value = value
        self.range = range
        self.format = format
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: InspectorMetrics.fieldRadius, style: .continuous)
        let layout = currentLayout

        ZStack(alignment: .leading) {
            sliderSurface

            Text(title)
                .font(.inspectorLabel)
                .foregroundStyle(isActive ? Color.primary.opacity(0.85) : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, Self.contentInset)
                .padding(.trailing, Self.valueWidth + Self.contentInset)
                .offset(x: min(stretch, 0))
                .opacity(layout.hidesLabel ? 0 : 1)
                .allowsHitTesting(false)

            if showsHandle {
                Capsule()
                    .fill(Color.primary.opacity(isEnabled ? 0.82 : 0.4))
                    .frame(width: Self.handleSize.width, height: Self.handleSize.height)
                    .offset(x: layout.handleX - Self.handleSize.width / 2)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }

            valueField
                .frame(maxWidth: .infinity, alignment: .trailing)
                .offset(x: layout.valueOffset)
        }
        .frame(height: InspectorMetrics.controlHeight)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                shape.fill(fieldFill)
                valueIndicator
            }
            .clipShape(shape)
            // Negative padding grows the field past its slot while overshooting.
            .padding(.leading, min(stretch, 0))
            .padding(.trailing, -max(stretch, 0))
        }
        .overlay {
            if focusedPart != nil {
                shape
                    .stroke(Color.accentColor.opacity(0.72), lineWidth: 1)
                    .padding(.leading, min(stretch, 0))
                    .padding(.trailing, -max(stretch, 0))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { fieldWidth = $0 }
        .onHover { isHovering = $0 }
        .animation(motion(.snappy(duration: 0.2)), value: layout.valueBesideHandle)
        .animation(motion(.snappy(duration: 0.16)), value: showsHandle)
        .animation(motion(.snappy(duration: 0.16)), value: layout.hidesLabel)
        .onAppear(perform: syncDraftText)
        .onDisappear {
            if focusedPart == .value {
                commitDraftText()
            }
        }
        .onChange(of: value) { _, _ in
            syncDraftText()
        }
        .onChange(of: focusedPart) { oldPart, newPart in
            if newPart == .value {
                beginValueEditing()
            } else if oldPart == .value {
                commitDraftText()
            }
        }
    }

    // MARK: Parts

    /// The full-field hit target for pressing, dragging and keyboard focus.
    /// The value field sits above it, so clicks on the number still edit it.
    private var sliderSurface: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            if focusedPart == .value {
                                commitDraftText()
                            }
                            focusedPart = .slider
                            isDragging = true
                        }
                        drag(to: gesture.location.x)
                    }
                    .onEnded { _ in
                        isDragging = false
                        fineAnchor = nil
                        withAnimation(motion(.spring(response: 0.32, dampingFraction: 0.55))) {
                            stretch = 0
                        }
                    }
            )
            .allowsHitTesting(isEnabled)
            .pointerStyle(isEnabled ? PointerStyle.columnResize : nil)
            .focusable(isEnabled)
            .focusEffectDisabled()
            .focused($focusedPart, equals: .slider)
            .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
                guard isEnabled else { return .ignored }
                let direction: CGFloat = press.key == .rightArrow ? 1 : -1
                adjustValue(by: direction * keyboardStep(large: press.modifiers.contains(.shift)))
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(format.displayString(for: value))
            .accessibilityHint("Drag horizontally to adjust, or edit the value field")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    adjustValue(by: format.step)
                case .decrement:
                    adjustValue(by: -format.step)
                @unknown default:
                    break
                }
            }
    }

    private var valueField: some View {
        TextField(title, text: $draftText, selection: $valueSelection)
            .textFieldStyle(.plain)
            .font(.inspectorNumeric)
            .foregroundStyle(.primary.opacity(0.85))
            .multilineTextAlignment(.trailing)
            .frame(width: Self.valueWidth)
            .padding(.trailing, Self.contentInset)
            .frame(maxHeight: .infinity)
            .focused($focusedPart, equals: .value)
            .onSubmit {
                commitDraftText()
                focusedPart = nil
            }
            .onExitCommand {
                draftText = editingBaselineText
                focusedPart = nil
            }
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                guard isEnabled else { return .ignored }
                commitDraftText()
                let direction: CGFloat = press.key == .upArrow ? 1 : -1
                adjustValue(by: direction * keyboardStep(large: press.modifiers.contains(.shift)))
                return .handled
            }
            .accessibilityLabel("\(title) value")
            .help("Enter an exact value for \(title)")
    }

    /// The fill from the range's origin (zero for signed ranges) to the value.
    /// Display only: input goes through `sliderSurface`.
    private var valueIndicator: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let origin = width * Self.fraction(of: indicatorOrigin, in: range)
            let current = width * Self.fraction(of: value, in: range)

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(indicatorFill)
                    .frame(width: abs(current - origin), height: proxy.size.height)
                    .offset(x: min(origin, current))

                if isSignedRange {
                    Rectangle()
                        .fill(Color.primary.opacity(colorScheme == .dark ? 0.24 : 0.18))
                        .frame(width: 1, height: proxy.size.height * 0.4)
                        .offset(x: origin - 0.5, y: proxy.size.height * 0.3)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Layout

    private struct SliderLayout {
        var handleX: CGFloat
        var valueOffset: CGFloat
        var valueBesideHandle: Bool
        var hidesLabel: Bool
    }

    /// Places the handle on the fill edge and moves the value to the handle's
    /// leading side when the handle would otherwise run into it. If that spot
    /// overlaps the label, the label steps out of the way while it's in use.
    private var currentLayout: SliderLayout {
        let width = fieldWidth
        let stretchedWidth = width + abs(stretch)
        let edge = stretchedWidth * Self.fraction(of: value, in: range) + min(stretch, 0)
        let handleInset = Self.handleSize.width / 2 + 3
        let handleX = min(max(edge, handleInset + min(stretch, 0)), width + max(stretch, 0) - handleInset)

        var layout = SliderLayout(
            handleX: handleX,
            valueOffset: max(stretch, 0),
            valueBesideHandle: false,
            hidesLabel: false
        )
        guard showsHandle, width > 0 else { return layout }

        let valueTextWidth = Self.textWidth(format.displayString(for: value), font: Self.valueFont)
        let valueLeadingEdge = width - Self.contentInset - valueTextWidth
        guard handleX + Self.handleGap > valueLeadingEdge else { return layout }

        // Right-align the value just before the handle instead.
        let besideTrailingEdge = handleX - Self.handleGap
        layout.valueOffset = besideTrailingEdge - (width - Self.contentInset)
        layout.valueBesideHandle = true

        let labelTrailingEdge = Self.contentInset + Self.textWidth(title, font: Self.labelFont)
        layout.hidesLabel = besideTrailingEdge - valueTextWidth < labelTrailingEdge + 4
        return layout
    }

    private var showsHandle: Bool {
        isEnabled
            && focusedPart != .value
            && (isHovering || isDragging || focusedPart == .slider)
    }

    private var isSignedRange: Bool {
        range.lowerBound < 0 && range.upperBound > 0
    }

    private var indicatorOrigin: CGFloat {
        isSignedRange ? 0 : range.lowerBound
    }

    private var indicatorFill: Color {
        let opacity: Double = colorScheme == .dark
            ? (isActive ? 0.13 : 0.09)
            : (isActive ? 0.10 : 0.07)
        return Color.primary.opacity(opacity)
    }

    private var isActive: Bool {
        isEnabled && (isHovering || isDragging || focusedPart != nil)
    }

    private var fieldFill: Color {
        let base = InspectorControlPalette.trackFill(for: colorScheme)
        guard isActive else { return base }
        return colorScheme == .dark ? Color.white.opacity(0.085) : Color.black.opacity(0.06)
    }

    private func motion(_ animation: Animation) -> Animation? {
        accessibilityReduceMotion ? nil : animation
    }

    // MARK: Input

    private func drag(to location: CGFloat) {
        let width = fieldWidth
        let span = range.upperBound - range.lowerBound
        guard width > 0, span.isFinite, span > 0 else { return }

        let proposed: CGFloat
        if NSEvent.modifierFlags.contains(.option) {
            let anchor = fineAnchor ?? (location, value)
            fineAnchor = anchor
            proposed = anchor.value + (location - anchor.location) / width * span * Self.fineDragMultiplier
        } else {
            fineAnchor = nil
            var candidate = range.lowerBound + min(max(location / width, 0), 1) * span
            // Soft detent: pointer drags rest on zero briefly. Typed and
            // keyboard input stay precise and never snap.
            if isSignedRange, abs(candidate) <= span / width * Self.zeroDetentDistance {
                candidate = 0
            }
            proposed = candidate
        }

        let overshoot = location < 0 ? location : max(location - width, 0)
        stretch = Self.rubberBand(overshoot)
        setValue(proposed)
    }

    private func keyboardStep(large: Bool) -> CGFloat {
        guard large else { return format.step }
        let span = range.upperBound - range.lowerBound
        return max(span * Self.largeStepFraction, format.step)
    }

    private func adjustValue(by delta: CGFloat) {
        guard delta.isFinite else { return }
        setValue(value + delta)
    }

    private func setValue(_ proposedValue: CGFloat) {
        guard isEnabled,
              proposedValue.isFinite,
              range.lowerBound.isFinite,
              range.upperBound.isFinite else { return }

        // Pointer dragging stays continuous; `step` is reserved for keyboard
        // and accessibility nudges, so existing preset/document precision is
        // never silently quantized.
        let clampedValue = min(max(proposedValue, range.lowerBound), range.upperBound)
        guard clampedValue != value else { return }
        value = clampedValue
    }

    private func syncDraftText() {
        if focusedPart == .value {
            beginValueEditing()
        } else {
            draftText = format.displayString(for: value)
        }
    }

    private func beginValueEditing() {
        let editingText = format.editingString(for: value)
        editingBaselineText = editingText
        draftText = editingText
        valueSelection = TextSelection(range: editingText.startIndex..<editingText.endIndex)
    }

    private func commitDraftText() {
        guard draftText != editingBaselineText else {
            syncDraftText()
            return
        }

        guard let parsedValue = format.parse(draftText) else {
            syncDraftText()
            return
        }

        setValue(parsedValue)
        editingBaselineText = format.editingString(for: value)
        syncDraftText()
    }

    // MARK: Math

    private static func fraction(of value: CGFloat, in range: ClosedRange<CGFloat>) -> CGFloat {
        let span = range.upperBound - range.lowerBound
        guard span.isFinite, span > 0, value.isFinite else { return 0 }
        return min(max((value - range.lowerBound) / span, 0), 1)
    }

    /// Resistance past an end: grows quickly at first, then approaches
    /// `maxStretch` however far the pointer goes.
    private static func rubberBand(_ overshoot: CGFloat) -> CGFloat {
        guard overshoot != 0 else { return 0 }
        let distance = abs(overshoot)
        let stretched = maxStretch * (1 - 1 / (distance / (maxStretch * 3) + 1))
        return overshoot < 0 ? -stretched : stretched
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

/// Lays two related fields side by side at equal widths, the way Sketch pairs
/// X/Y and W/H.
struct InspectorFieldPair<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: InspectorMetrics.rowSpacing) {
            leading()
                .frame(maxWidth: .infinity)
            trailing()
                .frame(maxWidth: .infinity)
        }
    }
}
