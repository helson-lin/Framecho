//
//  AnnotationTool.swift
//  Framecho
//

import Foundation

enum AnnotationTool: String, CaseIterable, Identifiable, Codable {
    case select
    case rectangle
    case filledRectangle
    case ellipse
    case line
    case arrow
    case freehand
    case numberedCircle
    case text
    case highlight
    case pixelate
    case blur

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select:
            String(localized: "Select")
        case .rectangle:
            String(localized: "Rectangle")
        case .filledRectangle:
            String(localized: "Solid rectangle")
        case .ellipse:
            String(localized: "Circle")
        case .line:
            String(localized: "Straight line")
        case .arrow:
            String(localized: "Arrow")
        case .freehand:
            String(localized: "Freehand")
        case .numberedCircle:
            String(localized: "Numbered circle")
        case .pixelate:
            String(localized: "Pixelate")
        case .blur:
            String(localized: "Blur")
        case .text:
            String(localized: "Text")
        case .highlight:
            String(localized: "Highlight")
        }
    }

    var systemImage: String {
        switch self {
        case .select:
            "cursorarrow"
        case .rectangle:
            "rectangle"
        case .filledRectangle:
            "rectangle.fill"
        case .ellipse:
            "circle"
        case .line:
            "line.diagonal"
        case .arrow:
            "arrow.up.right"
        case .freehand:
            "scribble"
        case .numberedCircle:
            "1.circle"
        case .pixelate:
            "checkerboard.rectangle"
        case .blur:
            "aqi.medium"
        case .text:
            "textformat"
        case .highlight:
            "rectangle.center.inset.filled"
        }
    }

    /// The single-key shortcut that picks this tool, shown in its tooltip.
    /// The keyboard handler reads this too, so the two cannot disagree.
    var shortcut: AnnotationToolShortcut {
        switch self {
        case .select: AnnotationToolShortcut(key: "h")
        case .rectangle: AnnotationToolShortcut(key: "r")
        case .filledRectangle: AnnotationToolShortcut(key: "r", shift: true)
        case .ellipse: AnnotationToolShortcut(key: "o")
        case .line: AnnotationToolShortcut(key: "l")
        case .arrow: AnnotationToolShortcut(key: "a")
        case .freehand: AnnotationToolShortcut(key: "f")
        case .numberedCircle: AnnotationToolShortcut(key: "n", alternateKey: "1")
        case .text: AnnotationToolShortcut(key: "t")
        case .highlight: AnnotationToolShortcut(key: "s")
        case .pixelate: AnnotationToolShortcut(key: "p")
        case .blur: AnnotationToolShortcut(key: "b")
        }
    }

    var helpText: String {
        if self == .highlight {
            return String(localized: "Draw an area to keep visible; everything outside is dimmed")
        }
        return title
    }

    /// "Rectangle (R)": the tooltip on the tool strip.
    var tooltip: String {
        "\(helpText) (\(shortcut.label))"
    }

    /// The tool a plain key press picks, if any. Command, Option and Control
    /// presses are never tool shortcuts; Shift picks the shifted variant.
    static func forShortcut(key: String, shift: Bool) -> AnnotationTool? {
        let key = key.lowercased()
        return allCases.first { tool in
            let shortcut = tool.shortcut
            return shortcut.shift == shift
                && (shortcut.key == key || (!shift && shortcut.alternateKey == key))
        }
    }

    var isFilledShape: Bool {
        self == .filledRectangle
    }

    var usesEndpoints: Bool {
        self == .line || self == .arrow
    }

    var isRedactionTool: Bool {
        self == .pixelate || self == .blur
    }

    var supportsColorStyle: Bool {
        switch self {
        case .rectangle, .filledRectangle, .ellipse, .line, .arrow, .freehand, .numberedCircle, .text:
            true
        case .select, .pixelate, .blur, .highlight:
            false
        }
    }

    var supportsStrokeStyle: Bool {
        switch self {
        case .rectangle, .ellipse, .line, .arrow, .freehand:
            true
        case .select, .filledRectangle, .numberedCircle, .pixelate, .blur, .text, .highlight:
            false
        }
    }

    var supportsRedactionDensityStyle: Bool {
        isRedactionTool
    }

    var supportsAspectLock: Bool {
        switch self {
        case .rectangle, .filledRectangle, .ellipse, .highlight:
            true
        case .select, .line, .arrow, .freehand, .numberedCircle, .pixelate, .blur, .text:
            false
        }
    }

    var createsAnnotation: Bool {
        self != .select
    }
}

struct AnnotationToolShortcut: Equatable {
    let key: String
    var shift = false
    /// A second unshifted key kept for an older binding (numbered circle's "1").
    var alternateKey: String?

    /// "R", "⇧R".
    var label: String {
        (shift ? "⇧" : "") + key.uppercased()
    }
}
