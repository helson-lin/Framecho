import CoreGraphics
import Foundation

// Reads edit documents (the `.framecho` sidecars) the way the app does,
// including ones written by older builds; see run-checks.sh for the files.
//
// scripts/fixtures/annotation-document-v2.json was written by the current
// format and is kept as is: a change that can no longer read it would open
// every existing annotated screenshot as a flat image.
@main
struct AnnotationDocumentChecks {
    static var checks = 0

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }

    static func main() {
        let fixture = try! Data(contentsOf: URL(fileURLWithPath: "scripts/fixtures/annotation-document-v2.json"))
        checkFixture(fixture)
        checkRoundTrip(fixture)
        checkOlderDocuments(fixture)
        checkTolerance(fixture)
        print("Annotation document checks passed (\(checks) assertions).")
    }

    static func decode(_ data: Data) throws -> AnnotationDocument {
        try JSONDecoder().decode(AnnotationDocument.self, from: data)
    }

    static func json(_ data: Data) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    static func data(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    static func shape(_ document: AnnotationDocument, _ id: String) -> AnnoShape {
        document.shapes.first { $0.id == AnnoShapeID(id) }!
    }

    // MARK: -

    static func checkFixture(_ fixture: Data) {
        let document = try! decode(fixture)
        expect(document.version == 2, "Version")
        expect(document.baseImageFileName == "Framecho_2026-10-05-12-00-00.base.png", "Base image name")
        expect(document.shapes.map(\.id.raw) == ["rect", "ellipse", "arrow", "pen", "text", "blur", "spot", "one"],
               "Every shape, in stacking order")

        let rect = shape(document, "rect")
        expect(rect.x == 120 && rect.y == 80 && rect.tool == .rectangle, "Rectangle position and kind")
        expect(rect.geoProps?.w == 400 && rect.geoProps?.h == 240 && rect.geoProps?.cornerRadius == 12, "Rectangle size")
        expect(rect.swatch == .red && rect.strokeWidth == 8, "Rectangle style")

        let ellipse = shape(document, "ellipse")
        expect(ellipse.tool == .ellipse && ellipse.rotation == 0.25 && ellipse.opacity == 0.8, "Ellipse transform")
        expect(ellipse.geoProps?.fill == .solid && ellipse.geoProps?.dash == .dashed && ellipse.swatch == .blue,
               "Ellipse style")

        let arrow = shape(document, "arrow").arrowProps!
        expect(arrow.end == Vec(300, 150) && arrow.bend == 20, "Arrow geometry")
        expect(arrow.arrowheadStart == .none && arrow.arrowheadEnd == .arrow, "Arrowheads")

        let pen = shape(document, "pen").drawProps!
        expect(pen.points.count == 3 && pen.points[1] == Vec(10, 5, 0.6) && pen.isComplete, "Freehand points and pressure")

        guard case let .text(text) = shape(document, "text").kind else { return expect(false, "Text kind") }
        expect(text.text == "Hello 你好" && text.align == .middle && !text.autoSize && text.w == 220, "Text")

        guard case let .redaction(redaction) = shape(document, "blur").kind else { return expect(false, "Redaction kind") }
        expect(redaction.kind == .pixelate && redaction.density == 0.7, "Redaction")
        expect(shape(document, "spot").tool == .highlight, "Highlight")
        expect(shape(document, "one").numberedProps?.value == 3, "Numbered circle")

        expect(document.bindings == [ArrowBinding(
            arrowId: AnnoShapeID("arrow"), toId: AnnoShapeID("rect"), terminal: .start,
            normalizedAnchor: Vec(0.5, 0.5), isPrecise: false, isExact: false
        )], "Arrow binding")

        let background = document.backgroundSettings
        expect(background.style == .gradient(AnnotationBackgroundGradient.presets[0]), "Gradient background")
        expect(abs(background.padding - 0.1) < 1e-9, "Background padding")
    }

    static func checkRoundTrip(_ fixture: Data) {
        let document = try! decode(fixture)
        let encoded = try! JSONEncoder().encode(document)
        expect(try! decode(encoded) == document, "Saving and reopening changes nothing")

        // A new document keeps its background settings through a save.
        var settings = AnnotationBackgroundSettings()
        settings.style = .solid(AnnotationBackgroundColor("ink", title: "Ink", red: 0.1, green: 0.2, blue: 0.3))
        settings.padding = 0.12
        settings.cornerRadius = 0.03
        settings.shadow = 0.5
        settings.aspectRatio = .auto
        let saved = AnnotationDocument(shapes: [], background: settings)
        let reopened = try! decode(try! JSONEncoder().encode(saved))
        expect(reopened.version == AnnotationDocument.currentVersion, "New documents use the current version")
        expect(reopened.backgroundSettings == settings, "Background settings survive a save")
    }

    static func checkOlderDocuments(_ fixture: Data) {
        // A v2 document from before cameras, scene blur, borders, watermarks,
        // shadow styles and arrow bindings.
        var old = json(fixture)
        var background = old["background"] as! [String: Any]
        for key in ["camera", "progressiveBlur", "border", "watermark", "shadowStyle", "customWallpaperPath"] {
            background[key] = nil
        }
        old["background"] = background
        old["bindings"] = nil
        old["baseImageFileName"] = nil
        let reopened = try! decode(data(old))
        expect(reopened.shapes.count == 8, "Shapes from before bindings")
        expect(reopened.bindings.isEmpty && reopened.baseImageFileName.isEmpty, "Missing optional fields default")
        let defaults = AnnotationBackgroundSettings()
        expect(reopened.backgroundSettings.camera == defaults.camera, "Missing camera is no camera")
        expect(reopened.backgroundSettings.border == defaults.border, "Missing border is the default border")
        expect(reopened.backgroundSettings.watermark == defaults.watermark, "Missing watermark is none")
        expect(reopened.backgroundSettings.style == .gradient(AnnotationBackgroundGradient.presets[0]),
               "Its background still applies")

        // Version 1 stored a different kind of annotation that can't be
        // converted: its background is kept and its annotations are dropped,
        // rather than the whole document failing.
        var v1 = json(fixture)
        v1["version"] = nil
        v1["shapes"] = nil
        v1["bindings"] = nil
        v1["items"] = [["id": "x", "kind": "rectangle", "rect": [0.1, 0.1, 0.2, 0.2]]]
        let legacy = try! decode(data(v1))
        expect(legacy.version == 1 && legacy.shapes.isEmpty && legacy.bindings.isEmpty, "A v1 document opens without shapes")
        expect(abs(legacy.backgroundSettings.padding - 0.1) < 1e-9, "A v1 document keeps its background")

        var explicitV1 = json(fixture)
        explicitV1["version"] = 1
        expect(try! decode(data(explicitV1)).shapes.isEmpty, "Shapes in a v1 document are never misread as v2")
    }

    static func checkTolerance(_ fixture: Data) {
        // A newer build may add fields; this one must still open the file.
        var newer = json(fixture)
        newer["version"] = 3
        newer["futureSetting"] = ["anything": true]
        var shapes = newer["shapes"] as! [[String: Any]]
        shapes[0]["glow"] = 0.5
        newer["shapes"] = shapes
        let reopened = try! decode(data(newer))
        expect(reopened.shapes.count == 8 && reopened.version == 3, "Unknown fields from a newer build are ignored")

        // Colours are identified by their values, not their localized titles.
        var localized = json(fixture)
        var shapes2 = localized["shapes"] as! [[String: Any]]
        var kind = shapes2[0]["kind"] as! [String: Any]
        var geo = kind["geo"] as! [String: Any]
        var props = geo["_0"] as! [String: Any]
        var swatch = props["swatch"] as! [String: Any]
        swatch["title"] = "红色"
        props["swatch"] = swatch
        geo["_0"] = props
        kind["geo"] = geo
        shapes2[0]["kind"] = kind
        localized["shapes"] = shapes2
        expect(shape(try! decode(data(localized)), "rect").swatch == .red,
               "A swatch saved under another language is still the same colour")

        // A swatch saved without alpha is opaque.
        swatch["alpha"] = nil
        props["swatch"] = swatch
        geo["_0"] = props
        kind["geo"] = geo
        shapes2[0]["kind"] = kind
        localized["shapes"] = shapes2
        expect(shape(try! decode(data(localized)), "rect").swatch?.alpha == 1, "Missing alpha means opaque")
    }
}
