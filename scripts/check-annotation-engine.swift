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
}
