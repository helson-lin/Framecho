import CoreGraphics
import Foundation

// Compile the annotation engine (its geometry and the editor's pointer state
// machine) without launching the app; see run-checks.sh for the file list.
@main
struct AnnotationEngineChecks {
    static var checks = 0

    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }

    static func near(_ actual: Double, _ expected: Double, _ message: String, tolerance: Double = 1e-6) {
        expect(actual.isFinite && abs(actual - expected) < tolerance, "\(message): expected \(expected), got \(actual)")
    }

    static func near(_ actual: Vec?, _ expected: Vec, _ message: String, tolerance: Double = 1e-6) {
        guard let actual else {
            expect(false, "\(message): expected \(expected), got nil")
            return
        }
        near(actual.x, expected.x, "\(message) (x)", tolerance: tolerance)
        near(actual.y, expected.y, "\(message) (y)", tolerance: tolerance)
    }

    static func main() {
        checkVectors()
        checkBoxes()
        checkMatrices()
        checkIntersections()
        checkMathUtilities()
        checkCamera()
        checkDrawingIsZoomIndependent()
        checkUndoRedo()
        checkSelection()
        checkClickCreatesUsableShape()
        checkArrowBinding()
        checkNumberedCircles()
        checkColorTags()
        checkColorSampler()
        checkMeasureLabels()
        checkRulers()
        checkClickToMeasure()
        checkSizeLabels()
        checkMeasuredBlocks()
        checkMeasureScanner()
        print("Annotation engine checks passed (\(checks) assertions).")
    }

    // MARK: - Geometry

    static func checkVectors() {
        near(Vec.add(Vec(1, 2), Vec(3, 4)), Vec(4, 6), "Add")
        near(Vec.sub(Vec(1, 2), Vec(3, 4)), Vec(-2, -2), "Subtract")
        near(Vec(3, 4).len, 5, "Length")
        near(Vec(3, 4).uni.len, 1, "Unit vector has length 1")
        expect(!Vec(0, 0).uni.isNaN, "The zero vector's unit stays finite")
        near(Vec.rot(Vec(1, 0), .pi / 2), Vec(0, 1), "Quarter turn")
        near(Vec.rotWith(Vec(2, 1), Vec(1, 1), .pi), Vec(0, 1), "Turn about a centre")
        near(Vec.dist(Vec(0, 0), Vec(6, 8)), 10, "Distance")
        near(Vec.lrp(Vec(0, 0), Vec(10, 20), 0.25), Vec(2.5, 5), "Interpolation")
        near(Vec.angle(Vec(0, 0), Vec(0, 1)), .pi / 2, "Angle")
        near(Vec.nearestPointOnLineSegment(Vec(0, 0), Vec(10, 0), Vec(4, 3)), Vec(4, 0), "Nearest point on a segment")
        near(Vec.nearestPointOnLineSegment(Vec(0, 0), Vec(10, 0), Vec(14, 3)), Vec(10, 0), "Clamped to the segment's end")
        near(Vec.average([Vec(0, 0), Vec(4, 0), Vec(4, 4), Vec(0, 4)]), Vec(2, 2), "Average")

        // Vectors are stored in edit documents.
        let data = try! JSONEncoder().encode(Vec(1.5, -2, 0.7))
        expect(try! JSONDecoder().decode(Vec.self, from: data) == Vec(1.5, -2, 0.7), "Vec round-trips through JSON")
    }

    static func checkBoxes() {
        let box = Box.fromPoints([Vec(10, 40), Vec(30, 20), Vec(5, 25)])
        expect(box == Box(5, 20, 25, 20), "Bounds of points: \(box)")
        expect(Box.common([Box(0, 0, 10, 10), Box(20, 5, 5, 20)]) == Box(0, 0, 25, 25),
               "Common bounds")
        expect(box.containsPoint(Vec(10, 30)) && !box.containsPoint(Vec(40, 30)), "Contains a point")
        expect(box.containsPoint(Vec(31, 30), margin: 2), "Contains a point within the margin")
        expect(box.contains(Box(10, 25, 5, 5)), "Contains a box")
        expect(box.collides(Box(25, 35, 20, 20)) && !box.collides(Box(100, 100, 1, 1)),
               "Overlap")
        expect(box.expandBy(5) == Box(0, 15, 35, 30), "Expand")
        expect(box.corners.count == 4 && box.center == Vec(17.5, 30), "Corners and centre")
    }

    static func checkMatrices() {
        let m = Mat.compose(x: 100, y: 50, rotation: .pi / 2)
        near(m.applyToPoint(Vec(10, 0)), Vec(100, 60), "Rotate, then move")
        near(m.applyInverseToPoint(Vec(100, 60)), Vec(10, 0), "Inverse undoes it")
        near(m.rotation, .pi / 2, "Rotation read back")
        let identity = Mat.multiply(m, m.inverse)
        near(identity.applyToPoint(Vec(7, -3)), Vec(7, -3), "A matrix times its inverse is the identity")
        near(Mat.scale(2, 3).applyToPoint(Vec(1, 1)), Vec(2, 3), "Scale")
    }

    static func checkIntersections() {
        near(intersectLineSegmentLineSegment(Vec(0, 0), Vec(2, 2), Vec(0, 2), Vec(2, 0)), Vec(1, 1), "Crossing segments")
        expect(intersectLineSegmentLineSegment(Vec(0, 0), Vec(2, 0), Vec(0, 1), Vec(2, 1)) == nil, "Parallel segments")
        expect(intersectLineSegmentLineSegment(Vec(0, 0), Vec(1, 1), Vec(3, 0), Vec(0, 3)) == nil,
               "Segments whose lines cross beyond their ends")
        let hits = intersectLineSegmentCircle(Vec(-10, 0), Vec(10, 0), Vec(0, 0), 5) ?? []
        expect(hits.count == 2 && hits.allSatisfy { abs(abs($0.x) - 5) < 1e-9 }, "A segment through a circle: \(hits)")
        expect(intersectCircleCircle(Vec(0, 0), 5, Vec(8, 0), 5).count == 2, "Overlapping circles")
        // Always two points: curved arrowheads index both and fall back to
        // the tip when they're not real, as for circles that don't meet.
        let apart = intersectCircleCircle(Vec(0, 0), 1, Vec(8, 0), 1)
        expect(apart.count == 2 && apart.allSatisfy(\.isNaN), "Separate circles give two NaN points")
        let square = [Vec(0, 0), Vec(10, 0), Vec(10, 10), Vec(0, 10)]
        expect(polygonsIntersect(square, [Vec(5, 5), Vec(15, 5), Vec(15, 15)]), "Overlapping polygons")
        expect(!polygonsIntersect(square, [Vec(20, 20), Vec(30, 20), Vec(30, 30)]), "Separate polygons")
    }

    static func checkMathUtilities() {
        let square = [Vec(0, 0), Vec(10, 0), Vec(10, 10), Vec(0, 10)]
        expect(pointInPolygon(Vec(5, 5), square) && !pointInPolygon(Vec(15, 5), square), "Point in polygon")
        near(centerOfCircleFromThreePoints(Vec(0, 5), Vec(5, 0), Vec(-5, 0)), Vec(0, 0), "Circle through three points")
        expect(centerOfCircleFromThreePoints(Vec(0, 0), Vec(1, 1), Vec(2, 2)) == nil, "No circle through a straight line")
        near(clamp(15, 0, 10), 10, "Clamp high")
        near(clamp(-1, 0, 10), 0, "Clamp low")
        near(modulate(5, (0, 10), (100, 200)), 150, "Map between ranges")
        near(canonicalizeRotation(-.pi / 2), 3 * .pi / 2, "Rotation in 0..<2π")
        near(snapAngle(0.4, 4), 0, "Snap to a quarter turn")
        near(snapAngle(1.3, 4), .pi / 2, "Snap up to a quarter turn")
        near(shortAngleDist(0.1, 2 * .pi - 0.1), -0.2, "Shortest way round")
    }

    // MARK: - Editor

    /// A 2000 × 1000 px image shown at half size, 100 pt in and 50 pt down.
    static func makeEditor(scale: Double = 0.5) -> AnnoEditor {
        let editor = AnnoEditor()
        editor.viewport = AnnoViewport(
            imageFrame: CGRect(x: 100, y: 50, width: 2000 * scale, height: 1000 * scale),
            imageSize: CGSize(width: 2000, height: 1000)
        )
        return editor
    }

    static func pointer(_ editor: AnnoEditor, page: Vec, shift: Bool = false) -> PointerInfo {
        PointerInfo(screenPoint: editor.pageToScreen(page), pagePoint: page, shift: shift)
    }

    static func drag(_ editor: AnnoEditor, from start: Vec, to end: Vec, shift: Bool = false) {
        editor.pointerDown(pointer(editor, page: start))
        for step in 1...4 {
            editor.pointerMove(pointer(editor, page: Vec.lrp(start, end, Double(step) / 4), shift: shift))
        }
        editor.pointerUp(pointer(editor, page: end, shift: shift))
    }

    static func click(_ editor: AnnoEditor, at page: Vec) {
        editor.pointerDown(pointer(editor, page: page))
        editor.pointerUp(pointer(editor, page: page))
    }

    static func checkCamera() {
        let editor = makeEditor()
        near(editor.viewport.scale, 0.5, "Points per page pixel")
        near(editor.pageToScreen(Vec(0, 0)), Vec(100, 50), "The image's corner on screen")
        near(editor.pageToScreen(Vec(2000, 1000)), Vec(1100, 550), "The far corner on screen")
        near(editor.screenToPage(Vec(600, 300)), Vec(1000, 500), "A screen point back in page space")
        near(editor.screenToPage(editor.pageToScreen(Vec(123.5, 456.25))), Vec(123.5, 456.25), "Round trip")
        near(editor.pageDistance(forScreen: 10), 20, "Hit margins stay constant on screen")
    }

    /// Annotations live in image pixels: the same drag in image terms gives
    /// the same shape whatever the zoom, so exports land where they were drawn.
    static func checkDrawingIsZoomIndependent() {
        var results: [AnnoShape] = []
        for scale in [0.25, 0.5, 2.0] {
            let editor = makeEditor(scale: scale)
            editor.tool = .rectangle
            drag(editor, from: Vec(300, 200), to: Vec(700, 450))
            expect(editor.shapes.count == 1, "One rectangle at zoom \(scale)")
            results.append(editor.shapes[0])
        }
        for shape in results {
            near(shape.x, 300, "Rectangle x")
            near(shape.y, 200, "Rectangle y")
            near(shape.geoProps?.w ?? 0, 400, "Rectangle width")
            near(shape.geoProps?.h ?? 0, 250, "Rectangle height")
        }

        // Dragging up and left still gives a positive box.
        let editor = makeEditor()
        editor.tool = .ellipse
        drag(editor, from: Vec(700, 450), to: Vec(300, 200))
        let ellipse = editor.shapes[0]
        expect(ellipse.geoProps?.geo == .ellipse, "An ellipse")
        near(ellipse.x, 300, "Reversed drag x")
        near(ellipse.geoProps?.w ?? 0, 400, "Reversed drag width")

        // Shift makes it square.
        let square = makeEditor()
        square.tool = .rectangle
        drag(square, from: Vec(100, 100), to: Vec(400, 200), shift: true)
        near(square.shapes[0].geoProps?.w ?? 0, 300, "Shift square width")
        near(square.shapes[0].geoProps?.h ?? 0, 300, "Shift square height")

        // Drawing hands over to selection with the new shape picked.
        expect(square.tool == .select && square.selectedIds == [square.shapes[0].id],
               "A new shape ends up selected")
    }

    static func checkUndoRedo() {
        let editor = makeEditor()
        editor.tool = .rectangle
        drag(editor, from: Vec(100, 100), to: Vec(300, 300))
        editor.tool = .rectangle
        drag(editor, from: Vec(500, 100), to: Vec(700, 300))
        expect(editor.shapes.count == 2 && editor.canUndo && !editor.canRedo, "Two shapes, undoable")

        editor.undo()
        expect(editor.shapes.count == 1 && editor.canRedo, "Undo removes the last shape")
        editor.undo()
        expect(editor.shapes.isEmpty, "Undo again removes the first")
        editor.redo()
        editor.redo()
        expect(editor.shapes.count == 2 && !editor.canRedo, "Redo brings both back")

        editor.undo()
        editor.tool = .ellipse
        drag(editor, from: Vec(900, 100), to: Vec(1000, 200))
        expect(!editor.canRedo, "A new edit clears what could be redone")

        editor.replaceDocument(shapes: [])
        expect(!editor.canUndo && !editor.canRedo, "Loading a document starts a fresh history")
    }

    static func checkSelection() {
        let editor = makeEditor()
        editor.tool = .filledRectangle
        drag(editor, from: Vec(100, 100), to: Vec(300, 300))
        editor.tool = .filledRectangle
        drag(editor, from: Vec(1000, 500), to: Vec(1200, 700))
        let first = editor.shapes[0].id

        editor.tool = .select
        click(editor, at: Vec(1500, 900))
        expect(editor.selectedIds.isEmpty, "Clicking empty canvas clears the selection")
        click(editor, at: Vec(200, 200))
        expect(editor.selectedIds == [first], "Clicking a filled shape selects it")

        editor.nudgeSelected(dx: 10, dy: -5)
        near(editor.shapes[0].x, 110, "Nudge x")
        near(editor.shapes[0].y, 95, "Nudge y")
        near(editor.shapes[1].x, 1000, "Nudging leaves the other shape alone")
        editor.undo()
        near(editor.shapes[0].x, 100, "A nudge is undoable")

        editor.selectAll()
        expect(editor.selectedIds.count == 2, "Select all")
        expect(editor.shapes(in: Box(0, 0, 400, 400)).map(\.id) == [first], "Box select")

        editor.selectedIds = [first]
        editor.deleteSelected()
        expect(editor.shapes.count == 1 && editor.shapes[0].id != first && editor.selectedIds.isEmpty, "Delete")
        editor.undo()
        expect(editor.shapes.count == 2, "Delete is undoable")
    }

    static func checkClickCreatesUsableShape() {
        let editor = makeEditor()
        editor.tool = .rectangle
        click(editor, at: Vec(500, 500))
        let shape = editor.shapes.first
        expect((shape?.geoProps?.w ?? 0) >= 48 && shape?.geoProps?.w == shape?.geoProps?.h,
               "A click without a drag gives a visible square, not a speck")

        // An arrow too short to see is dropped.
        let arrows = makeEditor()
        arrows.tool = .arrow
        drag(arrows, from: Vec(500, 500), to: Vec(501, 500))
        expect(arrows.shapes.isEmpty, "A one-pixel arrow is discarded")

        // So is a freehand dot.
        let pen = makeEditor()
        pen.tool = .freehand
        click(pen, at: Vec(500, 500))
        expect(pen.shapes.isEmpty, "A freehand click leaves nothing behind")
    }

    static func checkArrowBinding() {
        let editor = makeEditor()
        editor.tool = .filledRectangle
        drag(editor, from: Vec(100, 100), to: Vec(400, 400))
        let box = editor.shapes[0].id
        editor.tool = .arrow
        drag(editor, from: Vec(250, 250), to: Vec(900, 600))
        let arrow = editor.shapes.last!
        expect(arrow.isArrow && editor.selectedIds == [arrow.id], "An arrow, selected")
        let bindings = editor.document.bindings(from: arrow.id)
        expect(bindings.count == 1 && bindings[0].toId == box,
               "An arrow started on a shape is bound to it: \(bindings)")

        // Moving the shape doesn't break the binding, and deleting it drops it.
        editor.selectedIds = [box]
        editor.nudgeSelected(dx: 50, dy: 0)
        expect(editor.document.bindings(to: box).count == 1, "The binding follows the shape")
        editor.deleteSelected()
        expect(editor.document.bindings(from: arrow.id).isEmpty, "Deleting the shape removes the binding")
    }

    static func checkNumberedCircles() {
        let editor = makeEditor()
        editor.tool = .numberedCircle
        for x in [200.0, 400, 600] {
            click(editor, at: Vec(x, 300))
        }
        expect(editor.shapes.compactMap { $0.numberedProps?.value } == [1, 2, 3], "Circles count up")
        let first = editor.shapes[0]
        let diameter = first.numberedProps?.diameter ?? 0
        near(first.x + diameter / 2, 200, "Centred on the click (x)")
        near(first.y + diameter / 2, 300, "Centred on the click (y)")
        expect(diameter >= 24, "Big enough to read")

        // With 1 removed, 2 and 3 remain: the next is 4, not a second 3.
        editor.selectedIds = [editor.shapes[0].id]
        editor.deleteSelected()
        click(editor, at: Vec(800, 300))
        expect(editor.shapes.last?.numberedProps?.value == 4, "Numbering continues from the highest left")
    }

    static func checkColorTags() {
        let editor = makeEditor()
        editor.tool = .colorPicker
        click(editor, at: Vec(300, 300))
        expect(editor.shapes.isEmpty, "No tag without pixels to sample")

        // Red on the left half of the image, blue on the right.
        editor.sampleColor = { point in
            point.x < 1000 ? ColorTagProps(red: 255, green: 0, blue: 0) : ColorTagProps(red: 0, green: 82, blue: 255)
        }
        click(editor, at: Vec(300, 300))
        guard let tag = editor.shapes.first, let props = tag.colorTagProps else {
            expect(false, "A click places a color tag")
            return
        }
        expect(tag.tool == .colorPicker && editor.selectedIds == [tag.id], "A color tag, selected")
        expect(props.hex == "#FF0000" && props.rgbDescription == "R255 G0 B0", "Labels the sampled color")
        near(tag.colorTagAnchor, Vec(300, 300), "Points at the clicked pixel")
        expect(tag.x > 300 && tag.y + Double(ColorTagLayout(props).size.height) < 300, "Label up and to the right")
        expect(editor.hitShape(at: Vec(300, 300))?.id == tag.id, "The marker is clickable")

        // Dragging the label moves it alone: the arrow still points at the same pixel.
        let label = Vec(tag.x + 5, tag.y + 5)
        drag(editor, from: label, to: Vec(label.x + 400, label.y + 200))
        near(editor.shapes[0].x, tag.x + 400, "The label moved")
        near(editor.shapes[0].colorTagAnchor, Vec(300, 300), "The pixel stays put")
        expect(editor.shapes[0].colorTagProps?.hex == "#FF0000", "And so does its color")
        editor.nudgeSelected(dx: 10, dy: 0)
        near(editor.shapes[0].colorTagAnchor, Vec(300, 300), "Nudging moves only the label")

        // Dragging the marker re-targets the pixel, even with the color tool, and leaves the label.
        let labelX = editor.shapes[0].x
        drag(editor, from: Vec(300, 300), to: Vec(1300, 300))
        expect(editor.shapes.count == 1, "Grabbing a marker doesn't place another tag")
        near(editor.shapes[0].colorTagAnchor, Vec(1300, 300), "The marker follows the drag")
        expect(editor.shapes[0].colorTagProps?.hex == "#0052FF", "A re-targeted tag reads its new pixel")
        near(editor.shapes[0].x, labelX, "The label stays put")

        // A press-and-drag pulls a new tag's label out to the release point.
        drag(editor, from: Vec(200, 600), to: Vec(700, 800))
        guard let pulled = editor.shapes.last, let pulledProps = pulled.colorTagProps else {
            expect(false, "A drag places a tag")
            return
        }
        near(pulled.colorTagAnchor, Vec(200, 600), "Sampled where the drag began")
        near(pulled.x, 700, "Its label starts at the release point")
        near(pulled.y + Double(ColorTagLayout(pulledProps).size.height) / 2, 800, "Centred on it")
    }

    static func checkColorSampler() {
        // 2x2, y-down: red, green / blue, white.
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255]
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8, space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else {
            expect(false, "Test image")
            return
        }
        let size = CGSize(width: 2, height: 2)
        func hex(_ point: Vec) -> String? {
            AnnotationColorSampler.color(in: image, pageSize: size, at: point)?.hex
        }
        expect(hex(Vec(0.5, 0.5)) == "#FF0000", "Top left")
        expect(hex(Vec(1.5, 0.5)) == "#00FF00", "Top right")
        expect(hex(Vec(0.5, 1.5)) == "#0000FF", "Bottom left: rows count down from the top")
        expect(hex(Vec(1.9, 1.9)) == "#FFFFFF", "Bottom right")
        expect(hex(Vec(2, 1)) == nil && hex(Vec(-0.1, 1)) == nil, "Nothing outside the image")
        // A half-size preview of a 4x4 page maps page pixels onto its own.
        expect(
            AnnotationColorSampler.color(in: image, pageSize: CGSize(width: 4, height: 4), at: Vec(3.5, 0.5))?.hex == "#00FF00",
            "A scaled preview maps page space onto its pixels"
        )

        // The loupe's 3x3 around the top-left pixel: red in the middle, green to its right,
        // blue below, and nothing beyond the image's edge.
        guard let loupe = AnnotationColorSampler.neighborhood(in: image, pageSize: size, around: Vec(0.5, 0.5), radius: 1) else {
            expect(false, "A neighborhood at the image's corner")
            return
        }
        let grid = CGSize(width: 3, height: 3)
        func loupeHex(_ column: Double, _ row: Double) -> String? {
            AnnotationColorSampler.color(in: loupe.image, pageSize: grid, at: Vec(column + 0.5, row + 0.5))?.hex
        }
        expect(loupe.image.width == 3 && loupe.image.height == 3 && loupe.center.hex == "#FF0000", "Loupe centre")
        expect(loupeHex(1, 1) == "#FF0000" && loupeHex(2, 1) == "#00FF00" && loupeHex(1, 2) == "#0000FF"
               && loupeHex(2, 2) == "#FFFFFF", "Loupe pixels stay upright")
        expect(loupeHex(0, 0) == "#000000", "Off the edge is empty")
    }

    // MARK: - Measurements

    static func checkMeasureLabels() {
        let pixels = MeasureLabel(unit: .pixels, pixelsPerPoint: 2, fontSize: 20)
        expect(pixels.distance(320) == "320 px", "Whole pixels")
        expect(pixels.distance(-320) == "320 px", "A length has no sign")
        expect(pixels.distance(100.004) == "100 px", "Float noise rounds away")
        expect(pixels.distance(Vec(30, 40).len * 3) == "150 px", "A diagonal is its length")
        let points = MeasureLabel(unit: .points, pixelsPerPoint: 2, fontSize: 20)
        expect(points.distance(320) == "160 pt", "Points halve Retina pixels")
        expect(points.distance(321) == "160.5 pt", "Half a point shows")
        expect(points.size(width: 640, height: 480) == "320 × 240 pt", "A size")
        let flat = MeasureLabel(unit: .points, pixelsPerPoint: 0.5, fontSize: 20)
        expect(flat.distance(100) == "100 pt", "Density never goes below one pixel per point")
    }

    static func checkRulers() {
        let editor = makeEditor()
        editor.tool = .measure
        editor.currentSwatch = .blue
        editor.currentPixelsPerPoint = 2

        drag(editor, from: Vec(100.4, 200.6), to: Vec(420.2, 200.3))
        guard let ruler = editor.shapes.first, let props = ruler.measureProps else {
            return expect(false, "A drag makes a ruler")
        }
        expect(ruler.tool == .measure && editor.tool == .measure, "The measure tool stays on")
        expect(editor.selectedIds == [ruler.id], "The new ruler is selected")
        near(Vec(ruler.x, ruler.y), Vec(100, 201), "Its start snaps to a pixel edge")
        near(props.end, Vec(320, -1), "So does its end")
        expect(props.swatch == .blue && props.label.pixelsPerPoint == 2, "It takes the current style and density")
        let size = Double(max(editor.viewport.imageSize.width, editor.viewport.imageSize.height))
        near(props.label.fontSize, ColorTagProps.defaultFontSize(forImageSize: CGSize(width: size, height: size)),
             "Its label matches a color tag's")

        // Shift keeps it level.
        drag(editor, from: Vec(100, 400), to: Vec(500, 412), shift: true)
        near(editor.shapes[1].measureProps?.end, Vec(400, 0), "Shift levels a ruler")

        // The line and the label are what you can grab; the empty space around them isn't.
        let level = editor.shapes[1]
        expect(editor.hitShape(at: Vec(150, 400))?.id == level.id, "The line is clickable")
        let labelRect = MeasureLayout(level.measureProps!).labelRect
        let labelCenter = Vec(level.x + Double(labelRect.midX), level.y + Double(labelRect.midY))
        expect(editor.hitShape(at: labelCenter)?.id == level.id, "So is its label")
        expect(editor.hitShape(at: Vec(150, 460)) == nil, "Beside it isn't")

        // A selected ruler is edited by its ends.
        editor.tool = .select
        editor.selectedIds = [level.id]
        expect(editor.handle(at: editor.pageToScreen(Vec(100, 400))) == .arrowStart, "Its start is a handle")
        expect(editor.handle(at: editor.pageToScreen(Vec(500, 400))) == .arrowEnd, "So is its end")
        drag(editor, from: Vec(500, 400), to: Vec(600.3, 500.2))
        near(editor.shapes[1].measureProps?.end, Vec(500, 100), "Dragging an end moves just that end")
        near(Vec(editor.shapes[1].x, editor.shapes[1].y), Vec(100, 400), "And leaves the other where it was")

        // Arrows never bind to a ruler.
        editor.tool = .arrow
        drag(editor, from: Vec(150, 400), to: Vec(900, 900))
        let arrow = editor.shapes.last!
        expect(arrow.isArrow && editor.document.bindings(from: arrow.id).isEmpty, "An arrow from a ruler stays free")

        // A press with no movement and no image to scan leaves nothing behind, not even an undo step.
        let undoable = editor.canUndo
        let count = editor.shapes.count
        editor.tool = .measure
        click(editor, at: Vec(1500, 800))
        expect(editor.shapes.count == count, "A click with nothing to scan adds nothing")
        expect(editor.canUndo == undoable, "Nor anything to undo")
    }

    static func checkClickToMeasure() {
        let editor = makeEditor()
        editor.tool = .measure
        var scanned: Vec?
        editor.measureTarget = { point in
            scanned = point
            return .spans(MeasureSpans(left: 40, right: 360, top: 100, bottom: 148, x: 200.5, y: 120.5))
        }

        click(editor, at: Vec(200.7, 120.2))
        near(scanned, Vec(200.7, 120.2), "Scans where the click landed")
        expect(editor.shapes.count == 2 && editor.selectedIds.count == 2, "One ruler across, one down, both selected")
        let across = editor.shapes[0]
        let down = editor.shapes[1]
        near(Vec(across.x, across.y), Vec(40, 120.5), "The ruler across starts at the left edge, through the pixel")
        near(across.measureProps?.end, Vec(320, 0), "And spans the run")
        expect(across.measureProps?.label.distance(across.measureProps!.length) == "320 px", "Reading 320 px")
        near(Vec(down.x, down.y), Vec(200.5, 100), "The ruler down starts at the top edge")
        near(down.measureProps?.end, Vec(0, 48), "And spans the column")
        func labelRect(_ shape: AnnoShape) -> CGRect {
            MeasureLayout(shape.measureProps!).labelRect.offsetBy(dx: shape.x, dy: shape.y)
        }
        expect(!labelRect(across).intersects(labelRect(down)), "Crossing rulers keep their labels apart")
        expect(down.measureProps?.labelOffset?.x == 0, "The label down moves along its own ruler")

        // Moving an end puts the label back on its own.
        editor.tool = .select
        editor.selectedIds = [down.id]
        drag(editor, from: Vec(200.5, 148), to: Vec(200.5, 400))
        expect(editor.shapes[1].measureProps?.labelOffset == nil, "A moved end clears the offset")
        editor.undo()
        editor.tool = .measure

        editor.undo()
        expect(editor.shapes.isEmpty, "Both rulers undo as one step")

        // Hovering previews exactly what a click makes, without touching the document.
        var scans = 0
        editor.measureTarget = { _ in
            scans += 1
            return .spans(MeasureSpans(left: 40, right: 360, top: 100, bottom: 148, x: 200.5, y: 120.5))
        }
        editor.updateMeasurePreview(at: Vec(210.2, 125.7))
        expect(editor.measurePreview.count == 2 && editor.shapes.isEmpty, "A hover previews both rulers")
        editor.updateMeasurePreview(at: Vec(210.9, 125.1))
        expect(scans == 1, "Moving within one pixel doesn't rescan")
        click(editor, at: Vec(210.9, 125.1))
        expect(editor.shapes.count == 2, "The click makes the rulers")
        expect(editor.measurePreview.isEmpty, "And the preview steps aside for them")
        editor.updateMeasurePreview(at: Vec(210.5, 125.5))
        expect(editor.measurePreview.isEmpty, "Until the pointer leaves that pixel")
        editor.updateMeasurePreview(at: Vec(260, 130))
        expect(editor.measurePreview.count == 2, "Then it's back")
        editor.updateMeasurePreview(at: nil)
        expect(editor.measurePreview.isEmpty, "Leaving the canvas clears it")
        editor.undo()
        editor.measureTarget = { _ in .spans(MeasureSpans(left: 40, right: 360, top: 100, bottom: 148, x: 200.5, y: 120.5)) }

        // A run only one way still gets its ruler.
        editor.measureTarget = { _ in .spans(MeasureSpans(left: 10, right: 90, top: 50, bottom: 50, x: 50.5, y: 50.5)) }
        click(editor, at: Vec(50, 50))
        expect(editor.shapes.count == 1 && editor.shapes[0].measureProps?.end == Vec(80, 0), "An empty span is skipped")
    }

    static func checkSizeLabels() {
        let editor = makeEditor()
        editor.tool = .rectangle
        editor.currentStrokeWidth = 4
        drag(editor, from: Vec(100, 100), to: Vec(400, 300))
        expect(editor.shapes[0].geoProps?.sizeLabel == nil, "Rectangles show no size by default")

        editor.currentShowsSize = true
        editor.currentMeasureUnit = .points
        editor.currentPixelsPerPoint = 2
        editor.tool = .rectangle
        drag(editor, from: Vec(500, 100), to: Vec(1140, 580))
        guard let geo = editor.shapes[1].geoProps, let label = geo.sizeLabel,
              let placed = geo.sizeLabelLayout() else {
            return expect(false, "A rectangle with its size")
        }
        expect(label.unit == .points && label.size(width: geo.w, height: geo.h) == "320 × 240 pt", "Labelled in points")
        expect(placed.origin.y > CGFloat(geo.h), "The label sits under the shape")
        near(Double(placed.origin.x) + Double(placed.layout.size.width) / 2, geo.w / 2, "Centred on it")

        let before = editor.document.renderElements(editor.shapes[0].id).count
        let after = editor.document.renderElements(editor.shapes[1].id).count
        expect(after == before + 2, "The label draws as a pill and its text")

        // Resizing reads the new size, without stretching the label.
        editor.tool = .select
        editor.selectedIds = [editor.shapes[1].id]
        drag(editor, from: Vec(1140, 580), to: Vec(1300, 580))
        let resized = editor.shapes[1].geoProps!
        expect(resized.sizeLabel?.size(width: resized.w, height: resized.h) == "400 × 240 pt", "Resizing updates the size")
        expect(resized.sizeLabel?.fontSize == label.fontSize, "The label keeps its size")
    }

    static func checkMeasuredBlocks() {
        let editor = makeEditor()
        editor.tool = .measure
        editor.measureTarget = { _ in .block(left: 100, top: 100, right: 700, bottom: 400) }
        click(editor, at: Vec(300, 200))
        guard editor.shapes.count == 1, let box = editor.shapes[0].measureProps else {
            return expect(false, "A click inside a block measures it with one box")
        }
        let shape = editor.shapes[0]
        expect(box.isArea && box.text == "600 × 300 px", "The block's size")
        near(Vec(shape.x, shape.y), Vec(100, 100), "Its outline sits on the block's edges")
        let label = MeasureLayout(box).labelRect.offsetBy(dx: shape.x, dy: shape.y)
        expect(CGRect(x: 100, y: 100, width: 600, height: 300).contains(label), "A roomy block holds its label")
        expect(editor.hitShape(at: Vec(150, 150)) == nil, "The box is hollow: what it measures stays clickable")
        expect(editor.hitShape(at: Vec(100, 250))?.id == shape.id, "Its outline is grabbable")

        // Its corners are its handles; dragging one resizes the box.
        editor.tool = .select
        editor.selectedIds = [shape.id]
        expect(editor.handle(at: editor.pageToScreen(Vec(700, 400))) == .arrowEnd, "A corner is a handle")
        drag(editor, from: Vec(700, 400), to: Vec(800, 450), shift: true)
        expect(editor.shapes[0].measureProps?.text == "700 × 350 px", "Shift doesn't snap a box's corner to an angle")

        // A small block puts its label underneath.
        editor.tool = .measure
        editor.measureTarget = { _ in .block(left: 1000, top: 500, right: 1040, bottom: 520) }
        click(editor, at: Vec(1010, 510))
        let small = editor.shapes.last!
        let smallLabel = MeasureLayout(small.measureProps!).labelRect.offsetBy(dx: small.x, dy: small.y)
        expect(smallLabel.minY > 520, "A small block's label goes under it")

        // Hovering previews the box.
        editor.measureTarget = { _ in .block(left: 10, top: 10, right: 50, bottom: 30) }
        editor.updateMeasurePreview(at: Vec(20, 20))
        expect(editor.measurePreview.count == 1 && editor.measurePreview[0].measureProps?.isArea == true,
               "The preview is the box a click would make")
    }

    /// An RGBA image from rows of pixels, top row first.
    static func makeImage(_ rows: [[[UInt8]]]) -> CGImage? {
        let width = rows[0].count
        let bytes = rows.flatMap { $0.flatMap { $0 } }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: rows.count, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    static func checkMeasureScanner() {
        let white: [UInt8] = [255, 255, 255, 255]
        let dithered: [UInt8] = [253, 254, 255, 255]
        let gray: [UInt8] = [230, 230, 230, 255]
        let ink: [UInt8] = [30, 30, 30, 255]

        // 12 wide, 8 tall, y-down: a gray card at x 2...8, y 1...5, with a little glyph of ink
        // inside it, on a white page with one dithered pixel.
        let rows: [[[UInt8]]] = (0..<8).map { y in
            (0..<12).map { x in
                if [(4, 3), (5, 3), (4, 4)].contains(where: { $0 == (x, y) }) { return ink }
                if (2...8).contains(x) && (1...5).contains(y) { return gray }
                return x == 10 && y == 7 ? dithered : white
            }
        }
        guard let image = makeImage(rows), let scanner = AnnotationMeasureImage(image: image) else {
            return expect(false, "Test image")
        }
        let page = CGSize(width: 12, height: 8)
        let card = MeasureTarget.block(left: 2, top: 1, right: 9, bottom: 6)
        // A hover reads only what earlier fills found; a click fills.
        expect(scanner.cachedTarget(at: Vec(2.5, 1.5), pageSize: page) == nil, "Nothing is known before a fill")
        expect(scanner.target(at: Vec(2.5, 1.5), pageSize: page) == card, "Inside a card: the whole card")
        expect(scanner.cachedTarget(at: Vec(7.5, 5.5), pageSize: page) == card,
               "The rest of the card is known from that fill, text and all")
        expect(scanner.target(at: Vec(7.5, 5.5), pageSize: page) == card, "Text inside it doesn't cut it short")
        expect(scanner.target(at: Vec(4.5, 3.5), pageSize: page) == .block(left: 4, top: 3, right: 6, bottom: 5),
               "On the text itself: the glyph")
        expect(scanner.target(at: Vec(0.5, 0.5), pageSize: page)
            == .spans(MeasureSpans(left: 0, right: 12, top: 0, bottom: 8, x: 0.5, y: 0.5)),
               "The page around it is background, measured as gaps")
        // That fill stopped on its first row, which already spans the image.
        expect(scanner.cachedTarget(at: Vec(11.5, 0.5), pageSize: page)
            == .spans(MeasureSpans(left: 0, right: 12, top: 0, bottom: 8, x: 11.5, y: 0.5)),
               "Background, once found, is known wherever the fill reached")
        expect(scanner.target(at: Vec(10.5, 3.5), pageSize: page)
            == .spans(MeasureSpans(left: 9, right: 12, top: 0, bottom: 8, x: 10.5, y: 3.5)),
               "The gap right of the card, riding out the dithered pixel")
        expect(scanner.target(at: Vec(5.5, 0.5), pageSize: page)
            == .spans(MeasureSpans(left: 0, right: 12, top: 0, bottom: 1, x: 5.5, y: 0.5)),
               "The gap above the card: rows run top down")
        expect(scanner.target(at: Vec(12, 1), pageSize: page) == nil, "Nothing off the image")
        // A half-size preview of a 24x16 page reports page pixels.
        expect(scanner.target(at: Vec(6, 4), pageSize: CGSize(width: 24, height: 16))
            == .block(left: 4, top: 2, right: 18, bottom: 12), "A scaled preview maps back to the page")

        // A white card on a #F5F5F5 page is an edge.
        let pageGray: [UInt8] = [245, 245, 245, 255]
        guard let light = makeImage([[pageGray, pageGray, white, white, pageGray]]),
              let lightScanner = AnnotationMeasureImage(image: light) else { return expect(false, "Light image") }
        expect(lightScanner.run(x: 2, y: 0, horizontal: true) == 2...3, "A light card's edge stops the scan")
        expect(AnnotationMeasureImage(image: light, tolerance: 20)?.run(x: 2, y: 0, horizontal: true) == 0...4,
               "A looser tolerance runs past it")
    }
}
