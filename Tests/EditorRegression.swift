import UIKit
import Combine
import PencilKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

@main
final class EditorRegression: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    var performance: [String: Double] = [:]
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds); window.rootViewController = UIViewController(); window.makeKeyAndVisible(); self.window = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Task { await self.runChecks() } }; return true
    }
    func runChecks() async {
        var passed: [String] = []
        func check(_ value: Bool, _ message: String) {
            if !value { try? message.write(to: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Failure.txt"), atomically: true, encoding: .utf8) }
            precondition(value, message); passed.append(message)
        }
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(UUID().uuidString)
        let store = DeckStore(directory: directory)
        check(store.deck.slides.count == 1 && store.slide.elements.isEmpty && store.slide.paper == "FFFFFF", "A new installation starts on one blank white slide")
        for curve in [PressureCurve.linear, .soft, .firm] {
            let responses = (0...100).map { curve.value(at: Double($0) / 100) }
            check(responses.first == 0 && responses.last == 1, "Pressure curve endpoints are preserved")
            check(zip(responses, responses.dropFirst()).allSatisfy { $0 <= $1 }, "Pressure response stays monotonic")
        }
        check(abs(PressureCurve.linear.value(at: 0.4) - 0.4) < 0.001, "Linear pressure stays linear")
        check(PressureCurve.soft.value(at: 0.3) > 0.3 && PressureCurve.firm.value(at: 0.3) < 0.3, "Soft and firm presets affect pressure in the intended direction")
        let light = PencilResponse(pressure: 0.2, altitude: .pi / 2, brush: .graphite, width: 12, curve: .soft)
        let heavy = PencilResponse(pressure: 0.9, altitude: .pi / 2, brush: .graphite, width: 12, curve: .soft)
        let tilted = PencilResponse(pressure: 0.2, altitude: 0.2, brush: .graphite, width: 12, curve: .soft)
        check(light.size.width < heavy.size.width && light.opacity < heavy.opacity, "Live pressure response changes both width and opacity")
        check(tilted.size.width > light.size.width * 3, "Low Pencil tilt produces a wide shading stroke with a custom curve")
        let a = SlideElement.text("A", x: 100, y: 100, width: 100, size: 40)
        let b = SlideElement.text("B", x: 300, y: 100, width: 100, size: 40)
        let outside = SlideElement.text("Outside", x: 900, y: 700, width: 200, size: 40)
        store.add(a); store.add(b); store.add(outside)
        store.tool = .select
        let polygon = [CGPoint(x: 80, y: 80), CGPoint(x: 430, y: 80), CGPoint(x: 430, y: 180), CGPoint(x: 80, y: 180)]
        store.selectLasso(polygon)
        check(store.selectedIDs == Set([a.id, b.id]), "Freehand lasso selects only enclosed objects")
        store.selectionShape = .rectangle; store.selectLasso([polygon[0], polygon[2]])
        check(store.selectedIDs == Set([a.id, b.id]), "Rectangle selects the intended objects")
        store.selectionShape = .ellipse; store.selectLasso([CGPoint(x: 80, y: 80), CGPoint(x: 220, y: 180)])
        check(store.selectedIDs == Set([a.id]), "Ellipse selects the intended object")
        store.selectedIDs = [a.id, b.id]; store.tool = .transform
        let editor = CanvasEditingSession()
        editor.begin(at: CGPoint(x: 250, y: 125), store: store, scale: 1)
        let revisionBeforeMove = store.deckRevision
        editor.change(to: CGPoint(x: 300, y: 175), store: store, scale: 1)
        check(store.deckRevision == revisionBeforeMove && store.transformPreview.elements[a.id]?.x == 150, "Live movement updates only the raster preview, without rewriting the deck")
        editor.end(at: CGPoint(x: 300, y: 175), store: store, scale: 1)
        check(store.slide.elements[0].x == 150 && store.slide.elements[1].y == 150 && store.slide.elements[2].x == 900, "Group move preserves relative positions and unrelated objects")
        store.undo()
        check(store.slide.elements[0].x == 100 && store.slide.elements[1].x == 300, "One undo restores the entire group transform")
        store.redo()
        check(store.slide.elements[0].x == 150, "Redo reapplies the group transform")
        store.selectedIDs = [a.id, b.id]
        let beforeResize = store.slide.elements
        let bounds = store.selectionBounds!
        editor.begin(at: CGPoint(x: bounds.maxX, y: bounds.maxY), store: store, scale: 1)
        editor.end(at: CGPoint(x: bounds.maxX + bounds.width, y: bounds.maxY + bounds.height), store: store, scale: 1)
        check(abs(store.slide.elements[0].width - beforeResize[0].width * 2) < 0.01 && abs(store.slide.elements[1].fontSize - 80) < 0.01, "Uniform transform scales objects and type together")
        store.undo(); store.selectedIDs = [a.id, b.id]
        store.flipSelection(horizontal: true)
        check(store.slide.elements[0].flipX == true && store.slide.elements[1].flipX == true, "Flip affects the selected group")
        store.undo(); store.selectedIDs = [a.id]
        store.rotateSelection(); check(store.slide.elements[0].rotation == 90, "Rotation changes selected object")
        store.undo()
        let points = (0...20).map { i in PKStrokePoint(location: CGPoint(x: 500 + i * 5, y: 400), timeOffset: Double(i) / 20, size: CGSize(width: 8, height: 8), opacity: 0.6, force: 0.4, azimuth: 0.7, altitude: 0.3) }
        let drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pencil, color: .black), path: PKStrokePath(controlPoints: points, creationDate: .distantPast))])
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent { store.addDrawing(drawing) }
        let ink = store.slide.elements.last!
        let restored = try! PKDrawing(data: ink.drawing!)
        check(abs(restored.strokes[0].path[0].altitude - 0.3) < 0.01 && abs(restored.strokes[0].path[0].force - 0.4) < 0.01, "Saved Pencil strokes retain tilt and pressure data")
        store.selectionShape = .rectangle
        store.selectLasso([CGPoint(x: 490, y: 380), CGPoint(x: 550, y: 420)])
        while store.isSelectingPixels { try? await Task.sleep(for: .milliseconds(10)) }
        check(store.selectedIDs.count == 1 && store.selectedElement?.drawing == nil && store.selectedElement?.lineworkAsset != nil, "Lasso extracts only enclosed drawing pixels with separate linework")
        store.undo()
        store.tool = .erase
        editor.begin(at: CGPoint(x: 540, y: 400), store: store, scale: 1)
        editor.end(at: CGPoint(x: 550, y: 400), store: store, scale: 1)
        check(store.slide.elements.contains { $0.id == ink.id } && store.slide.elements.last?.kind == .erase, "Brush eraser masks part of a stroke without deleting its vector data")
        store.undo(); check(store.slide.elements.last?.id == ink.id, "Undo removes the eraser mark")
        let count = store.slide.elements.count
        store.startBlankDeck()
        check(store.slide.elements.isEmpty && store.deck.slides.count == 1, "New presentation opens a blank page")
        check(store.savedDecks.count == 1, "Previous deck is archived in Gallery")
        store.openSavedDeck(store.savedDecks[0])
        check(store.slide.elements.count == count, "Gallery restores the original deck")
        store.saveNow()
        let reloaded = DeckStore(directory: directory)
        check(reloaded.slide.elements.count == count, "Saved deck reloads with original content")
        let image = CanvasSnapshot.render(store: reloaded)!
        check(CanvasSnapshot.color(in: image, at: CGPoint(x: 1500, y: 850)) == "FFFFFF", "Eyedropper samples the visible white canvas")
        check(store.layers.count == 1 && store.slide.elements.allSatisfy { $0.layerID == store.activeLayer.id }, "Multiple strokes and objects remain on one user-created layer")
        check(restored.strokes[0].randomSeed == drawing.strokes[0].randomSeed, "Saving and normalizing a stroke preserves its texture seed")
        layerChecks(check)
        colorDropChecks(check)
        refinementChecks(check)
        gifChecks(check)
        textAndClipboardChecks(check)
        freeformAndVideoChecks(check)
        var stabilizer = StrokeStabilizer()
        var filtered: [Double] = []
        for i in 0..<60 {
            if let sample = stabilizer.sample(CGPoint(x: Double(i), y: i % 2 == 0 ? 1 : -1), pressure: i % 2 == 0 ? 0.4 : 0.6, time: Double(i) / 120, amount: 0.8) { filtered.append(abs(sample.0.y)) }
        }
        check(filtered.dropFirst(5).reduce(0, +) / 55 < 0.6, "Stabilization reduces alternating input jitter")
        check(stabilizer.sample(.zero, pressure: 0.5, time: 59.0 / 120, amount: 0.8) == nil, "Duplicate coalesced samples are ignored")
        let originalCurve = store.pressureCurve
        store.pressureCurve = .soft; store.tool = .draw; store.brush = .monoline
        let coordinator = DrawingCanvas(store: store, scale: 1).makeCoordinator()
        let canvas = StudioCanvasView(); coordinator.attach(canvas); coordinator.updateInput()
        check(canvas.drawingGestureRecognizer.isEnabled && canvas.drawingGestureRecognizer.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.direct.rawValue)), "A custom Pencil curve preserves native mouse and finger brush dynamics")
        check(!canvas.drawingGestureRecognizer.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.pencil.rawValue)), "Pencil input uses the custom pressure path without a second native stroke")
        store.pressureCurve = originalCurve
        let pencilGesture = canvas.interactions.compactMap { $0 as? UIPencilInteraction }.first
        check(pencilGesture?.delegate === coordinator, "Canvas registers Apple's hardware Pencil double-tap interaction")
        let brushSize = store.brushSize, eraserSize = store.eraserSize, brush = store.brush, eraser = store.eraserBrush
        coordinator.handlePencilDoubleTap(action: .switchEraser)
        check(store.tool == .erase && !canvas.drawingGestureRecognizer.isEnabled, "Pencil double-tap switches from brush to eraser and updates the input routing")
        coordinator.handlePencilDoubleTap(action: .switchEraser)
        check(store.tool == .draw && store.brush == brush && store.eraserBrush == eraser && store.brushSize == brushSize && store.eraserSize == eraserSize, "Pencil double-tap returns to the brush while preserving separate brush and eraser settings")
        coordinator.handlePencilDoubleTap(action: .ignore)
        check(store.tool == .draw, "Pencil double-tap respects the system Off setting")
        store.isFilling = true; coordinator.handlePencilDoubleTap(action: .switchEraser); store.isFilling = false
        check(store.tool == .draw, "Pencil double-tap cannot interrupt an active canvas fill")
        coordinator.detach()
        check(!canvas.interactions.contains { $0 is UIPencilInteraction }, "Pencil interaction is removed when its canvas is dismantled")
        await dimensionChecks(check)
        graphiteChecks(check)
        await rasterDisplayChecks(check)
        await latencyChecks(check)
        await importAndExportChecks(check)
        let report = ["passed": passed.count, "checks": passed, "performance": performance] as [String : Any]
        let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("results.json")
        try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination)
        print("PASS: \(passed.count) editor regression checks")
    }

    func dimensionChecks(_ check: (Bool, String) -> Void) async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let store = DeckStore(directory: documents.appendingPathComponent("DimensionsChecks"))
        check(store.dimensions == .standard, "Legacy and new decks default to 1600 by 900 pixels")
        store.add(.text("Resize me", x:100,y:200,width:400,size:64))
        store.duplicateSlide()
        let before = store.deck
        store.resizePresentation(to:.init(width:900,height:1600))
        let text=store.slide.elements[0]
        check(store.dimensions.width == 900 && store.deck.slides.allSatisfy { abs($0.elements[0].x - 56.25) < 0.01 && abs($0.elements[0].y - 659.375) < 0.01 }, "Presentation resize uniformly fits and centers elements on every slide")
        check(text.width == 225 && text.fontSize == 36 && text.id == before.slides[1].elements[0].id, "Resizing scales text and preserves element identities")
        store.undo(); check(store.deck.dimensions == before.dimensions && store.deck.slides.map(\.elements) == before.slides.map(\.elements), "Undo restores presentation dimensions and every slide's geometry together")
        store.redo(); check(store.dimensions == .init(width:900,height:1600), "Redo reapplies presentation dimensions")
        store.saveNow(); check(DeckStore(directory:store.documents).dimensions == store.dimensions, "Custom presentation dimensions survive saving and relaunch")
        let encoded = try! JSONEncoder().encode(store.deck)
        check(try! JSONDecoder().decode(StudioDeck.self, from:encoded).dimensions == store.dimensions, "Editable deck serialization retains dimensions")
        store.resizePresentation(to:.init(width:4000,height:4000))
        check(store.dimensions.width == 900, "Oversized custom canvases are rejected without changing the deck")
        let size = CGSize(width:640,height:480)
        store.resizePresentation(to:.init(width:640,height:480))
        let format=UIGraphicsImageRendererFormat();format.scale=1
        let solid=UIGraphicsImageRenderer(size:CGSize(width:20,height:20),format:format).image { c in UIColor.red.setFill();c.fill(CGRect(x:0,y:0,width:20,height:20)) }
        let atom=RasterAtom(image:solid.cgImage!,rect:CGRect(x:600,y:440,width:20,height:20),rotation:0,flipX:false,flipY:false,mode:.normal)
        let image=DrawingRasterizer.render([atom],size:size,canvasSize:size)!
        let pixels=FillPixels(image:image)!
        check(image.width == 640 && image.height == 480 && pixels.alpha(at:CGPoint(x:610,y:450)) == 255 && pixels.alpha(at:CGPoint(x:400,y:300)) == 0, "Raster drawings use custom pixel dimensions without coordinate distortion")
        let cut=PixelSelectionEngine.cut(art:[atom],linework:[atom],points:[CGPoint(x:590,y:430),CGPoint(x:630,y:430),CGPoint(x:630,y:470),CGPoint(x:590,y:470)],canvasSize:size)!
        check(cut.bounds == CGRect(x:590,y:430,width:40,height:40) && UIImage(data:cut.remaining)!.size == size, "Pixel lasso selection works near the bottom-right of a custom canvas")
        let point=CanvasViewportGeometry.canvasPoint(CGPoint(x:330,y:250),in:CGRect(x:10,y:10,width:320,height:240),canvasSize:size)
        check(point == CGPoint(x:640,y:480), "Zoomed canvas hit testing maps to custom presentation pixels")
        let preview=SlidePreviewRenderer.render([],paper:"FFFFFF",canvasSize:CGSize(width:900,height:1600))!
        check(abs(Double(preview.width)/Double(preview.height)-900.0/1600) < 0.01 && SlidePreviewKey(slide:store.slide,canvasSize:size) != SlidePreviewKey(slide:store.slide), "Slide previews preserve custom aspect ratios and invalidate old-size cache entries")
        let xml=try! BrushArchive.files(await store.exportKeynote())["ppt/presentation.xml"]!
        let textXML=String(decoding:xml,as:UTF8.self)
        check(textXML.contains("cx=\"4876800\" cy=\"3657600\""), "PPTX exports the chosen custom slide dimensions")
        store.storeImage(solid.pngData()!)
        check(store.canvasBounds.contains(store.slide.elements.last!.center) && store.slide.elements.last!.width <= 640, "New images fit and center on smaller canvases")
    }

    func graphiteChecks(_ check: (Bool, String) -> Void) {
        let point = CGPoint(x: 350, y: 200)
        func contact(_ width: Double, tilt: Double = .pi / 2, angle: Double = 0, at point: CGPoint = CGPoint(x: 350, y: 200)) -> GraphiteContact {
            GraphiteContact(point: point, width: width, pressure: 0.8, altitude: tilt, azimuth: angle)
        }
        func raster(_ width: Double, tilt: Double = .pi / 2, angle: Double = 0) -> GraphiteStrokeRaster {
            let raster = GraphiteStrokeRaster(brush: .graphite, color: "24483E", seed: 42)
            raster.add(contact(width, tilt: tilt, angle: angle)); return raster
        }
        func alpha(_ result: (CGImage, CGRect), _ point: CGPoint) -> Int {
            let pixels = FillPixels(image: result.0)!
            return Int(pixels.alpha(at: CGPoint(x: point.x-result.1.minX, y: point.y-result.1.minY)))
        }
        let tiny = GraphiteStrokeRaster(brush: .pencil, color: "000000", seed: 42)
        tiny.add(GraphiteContact(point: point, width: 1, pressure: 0.1, altitude: .pi/2, azimuth: 0))
        check(FillPixels(image: tiny.snapshot()!.0)!.rgba.contains { $0 > 0 }, "A light one-pixel pencil tap stays visible between pixel centers")
        let upright = contact(20), tilted = contact(20, tilt: .pi/6)
        check(tilted.size.width > upright.size.width * 6 && tilted.size.width > tilted.size.height * 3 && tilted.opacity < upright.opacity, "Pencil tilt changes from a fine point to a broad elliptical shading contact with lighter coverage")
        let small = raster(30).snapshot()!, large = raster(100).snapshot()!
        var differences = 0, variance = 0, adjacentDifference = 0, distantDifference = 0
        let smallPixels = FillPixels(image: small.0)!, largePixels = FillPixels(image: large.0)!
        for y in 196..<204 { for x in 346..<354 {
            let a = Int(smallPixels.alpha(at: CGPoint(x: Double(x)-small.1.minX,y: Double(y)-small.1.minY)))
            let b = Int(largePixels.alpha(at: CGPoint(x: Double(x)-large.1.minX,y: Double(y)-large.1.minY)))
            differences += abs(a-b); variance += abs(b-100)
        } }
        for y in 185..<215 { for x in 335..<355 {
            let center = alpha(large, CGPoint(x:x,y:y))
            adjacentDifference += abs(center-alpha(large,CGPoint(x:x+1,y:y)))
            distantDifference += abs(center-alpha(large,CGPoint(x:x+8,y:y)))
        } }
        check(differences < 64 * 10 && variance > 64 * 10, "Increasing pencil size preserves the same local paper grain rather than enlarging a texture stamp")
        check(adjacentDifference < distantDifference, "Pencil grain has spatially correlated fibers instead of independent pixel noise")
        let shaded = raster(30, tilt: .pi/6).snapshot()!
        let center = (195..<205).reduce(0) { $0 + alpha(shaded, CGPoint(x:350,y:$1)) }
        let edge = (222..<232).reduce(0) { $0 + alpha(shaded, CGPoint(x:350,y:$1)) }
        check(center > edge * 2, "Tilted graphite has a gradual falloff toward its outer edge")
        let horizontal = raster(20, tilt: .pi/6).snapshot()!, vertical = raster(20, tilt: .pi/6, angle: .pi/2).snapshot()!
        check(horizontal.1.width > horizontal.1.height * 2.5 && vertical.1.height > vertical.1.width * 2.5, "Tilted shading follows Apple Pencil azimuth rather than the direction of the stroke")
        check(alpha(horizontal, point) < alpha(raster(20).snapshot()!, point), "Tilt changes graphite deposition and grain response as well as stroke width")
        let stable = GraphiteStrokeRaster(brush: .graphite, color: "24483E", seed: 42)
        stable.add(contact(60, at: CGPoint(x: 100,y:200))); stable.add(contact(60, at: CGPoint(x:300,y:200)))
        let before = stable.snapshot()!, beforeData = FillPixels(image: before.0)!.rgba
        stable.add(contact(60, at: CGPoint(x:600,y:200)))
        let after = stable.snapshot()!
        let region = CGRect(x: before.1.minX-after.1.minX, y: before.1.minY-after.1.minY, width: 150, height: before.1.height)
        check(FillPixels(image: before.0.cropping(to: CGRect(x:0,y:0,width:150,height:before.1.height))!)!.rgba == FillPixels(image: after.0.cropping(to: region)!)!.rgba && FillPixels(image: before.0)!.rgba == beforeData, "New stroke samples leave earlier grain and previously captured images unchanged")
        let coarse = GraphiteStrokeRaster(brush: .graphite, color: "24483E", seed: 42)
        coarse.add(contact(60, at: CGPoint(x:100,y:200))); coarse.add(contact(60, at: CGPoint(x:600,y:200))); coarse.finish()
        let dense = GraphiteStrokeRaster(brush: .graphite, color: "24483E", seed: 42)
        for x in stride(from:100,through:600,by:5) { dense.add(contact(60,at:CGPoint(x:x,y:200))) }; dense.finish()
        let a = FillPixels(image: coarse.snapshot()!.0)!.rgba, b = FillPixels(image: dense.snapshot()!.0)!.rgba
        check(a.count == b.count && zip(a,b).allSatisfy { abs(Int($0)-Int($1)) <= 1 }, "Coalesced and sparse input samples produce the same shading without darkening or jitter")
        var slow = FingerPencilDynamics(), fast = FingerPencilDynamics(), slowForce = 0.0, fastForce = 0.0
        for i in 0..<60 { slowForce=slow.sample(CGPoint(x:i,y:0),time:Double(i)/120); fastForce=fast.sample(CGPoint(x:i*30,y:0),time:Double(i)/120) }
        check(slowForce > fastForce + 0.3, "Mouse and finger retain smooth speed-dependent pencil thickness")
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let store = DeckStore(directory: directory.appendingPathComponent("GraphiteChecks")); store.brush = .graphite
        let coordinator = DrawingCanvas(store:store,scale:1).makeCoordinator(), input=StudioCanvasView()
        coordinator.attach(input); coordinator.updateInput()
        check(!input.drawingGestureRecognizer.isEnabled, "Both sketch brushes use the sharp-grain renderer without a second PencilKit stroke")
        store.tool = .erase; store.eraserBrush = .pencil; coordinator.updateInput()
        check(!input.drawingGestureRecognizer.isEnabled, "Pencil erasers use the same grain and tilt rendering as pencil brushes")
        let png = DrawingRasterizer.png(after.0)!, restored=UIImage(data:png)!.cgImage!
        check(FillPixels(image:restored)!.rgba == FillPixels(image:after.0)!.rgba, "Saved pencil strokes preserve their live grain and transparency exactly")
        let benchmark = GraphiteStrokeRaster(brush:.graphite,color:"24483E",seed:42)
        let start=CFAbsoluteTimeGetCurrent()
        for i in 0..<100 { benchmark.add(contact(100,tilt:.pi/6,angle:.pi/2,at:CGPoint(x:100+i*10,y:450))) }
        performance["wideTiltedPencilMsPer100Samples"]=(CFAbsoluteTimeGetCurrent()-start)*1000
        let format=UIGraphicsImageRendererFormat();format.scale=1
        let comparison=UIGraphicsImageRenderer(size:CGSize(width:1200,height:1150),format:format).image { context in
            UIColor.white.setFill();context.fill(CGRect(x:0,y:0,width:1200,height:1150))
            for (row, width) in [8.0,30.0,100.0].enumerated() {
                for (col, tilt) in [Double.pi/2,Double.pi/4,Double.pi/6].enumerated() {
                    let stroke=GraphiteStrokeRaster(brush:.graphite,color:"24483E",seed:42)
                    for i in 0...50 { stroke.add(contact(width,tilt:tilt,angle:.pi/2,at:CGPoint(x:75+i*4,y:450))) }
                    stroke.finish()
                    if let (image,bounds)=stroke.snapshot() {
                        var destination = bounds
                        destination.origin.x += CGFloat(col * 400)
                        destination.origin.y += CGFloat([100, 300, 800][row] - 450)
                        UIImage(cgImage:image).draw(in:destination)
                    }
                    ("Size \(Int(width)) · \(Int((tilt*180 / .pi).rounded()))°" as NSString).draw(at:CGPoint(x:col*400+25,y:[10, 190, 470][row]),withAttributes:[.font:UIFont.systemFont(ofSize:16),.foregroundColor:UIColor.black])
                }
            }
        }
        try! comparison.pngData()!.write(to:directory.appendingPathComponent("Graphite-quality-check.png"))
    }

    // Exercise the mounted editor surface: bitmap generation alone cannot catch
    // an empty SwiftUI view whose rendering task never enters its lifecycle.
    func rasterDisplayChecks(_ check: (Bool, String) -> Void) async {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("RasterDisplayTest")
        let store = DeckStore(directory: directory)
        let viewport = CanvasViewportState()
        let host = UIHostingController(rootView: RasterDisplayHarness(store: store, viewport: viewport))
        let previous = window!.rootViewController
        window!.rootViewController = host
        defer { window!.rootViewController = previous }
        func sample(_ point: CGPoint) -> String? {
            host.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
                host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            let rect = viewport.canvasRect
            let location = CGPoint(x: (rect.minX + point.x / 1600 * rect.width) / host.view.bounds.width * 1600,
                                   y: (rect.minY + point.y / 900 * rect.height) / host.view.bounds.height * 900)
            return CanvasSnapshot.color(in: image, at: location)
        }
        func awaitColor(_ expected: String, at point: CGPoint) async -> Bool {
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(50))
                if sample(point) == expected { return true }
            }
            return false
        }
        func stroke(_ color: UIColor, y: CGFloat) -> PKDrawing {
            let points = (0...20).map { i in PKStrokePoint(location: CGPoint(x: CGFloat(400 + i * 10), y: y), timeOffset: Double(i) / 20, size: CGSize(width: 35, height: 35), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2) }
            return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: points, creationDate: .distantPast))])
        }
        check(await awaitColor("FFFFFF", at: CGPoint(x: 500, y: 400)), "Mounted zoomable editor begins with a visible blank canvas")
        store.addDrawing(stroke(.red, y: 400))
        check(await awaitColor("FF0000", at: CGPoint(x: 500, y: 400)), "First committed stroke appears on the mounted raster canvas")
        store.addDrawing(stroke(.blue, y: 500))
        check(await awaitColor("0000FF", at: CGPoint(x: 500, y: 500)) && sample(CGPoint(x: 500, y: 400)) == "FF0000", "Subsequent strokes refresh the raster while preserving earlier strokes")
        store.undo()
        check(await awaitColor("FFFFFF", at: CGPoint(x: 500, y: 500)) && sample(CGPoint(x: 500, y: 400)) == "FF0000", "Undo refreshes visible raster pixels")
        store.redo()
        check(await awaitColor("0000FF", at: CGPoint(x: 500, y: 500)), "Redo restores visible raster pixels")
        store.addLayer()
        check(await awaitColor("FF0000", at: CGPoint(x: 500, y: 400)), "A new empty layer is transparent and shows the drawing below")
        store.addDrawing(stroke(.green, y: 600))
        check(await awaitColor("00FF00", at: CGPoint(x: 500, y: 600)) && sample(CGPoint(x: 500, y: 400)) == "FF0000", "Rasterized strokes leave empty areas transparent to lower layers")
        store.setBackground("FFFF00", scope: .currentSlide)
        check(await awaitColor("FFFF00", at: CGPoint(x: 500, y: 700)) && sample(CGPoint(x: 500, y: 600)) == "00FF00", "Slide background remains separate beneath transparent drawing layers")
        let selected = store.slide.elements.last!
        store.selectedIDs = [selected.id]; store.tool = .transform
        check(await awaitColor("00FF00", at: CGPoint(x: 500, y: 600)), "Selecting drawing pixels preserves their visible position")
        let editing = CanvasEditingSession()
        editing.begin(at: CGPoint(x: 500, y: 600), store: store, scale: 1)
        let revision = store.deckRevision
        editing.change(to: CGPoint(x: 800, y: 650), store: store, scale: 1)
        let nativeMoved = await awaitColor("00FF00", at: CGPoint(x: 800, y: 650)) && sample(CGPoint(x: 500, y: 600)) == "FFFF00" && store.deckRevision == revision
        let current = store.transformPreview.elements[selected.id] ?? selected
        check(nativeMoved, "Native drag preview moves pixels immediately without rewriting the deck" + (nativeMoved ? "" : " old=\(sample(CGPoint(x: 500, y: 600)) ?? "nil") new=\(sample(CGPoint(x: 800, y: 650)) ?? "nil") delta=\(current.x-selected.x),\(current.y-selected.y) originalSize=\(selected.width),\(selected.height) newSize=\(current.width),\(current.height)"))
        editing.end(at: CGPoint(x: 800, y: 650), store: store, scale: 1)
        check(await awaitColor("00FF00", at: CGPoint(x: 800, y: 650)), "Releasing a drag preserves the displayed position")
        store.undo()
        check(await awaitColor("00FF00", at: CGPoint(x: 500, y: 600)) && sample(CGPoint(x: 800, y: 650)) == "FFFF00", "One undo restores the visible position after a native drag")
    }

    func latencyChecks(_ check: (Bool, String) -> Void) async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = DeckStore(directory: directory)
        let fixture = Bundle.main.bundleURL.appendingPathComponent("PerformanceDeck")
        var benchmarkStore = store
        if FileManager.default.fileExists(atPath: fixture.path) {
            let copied = directory.appendingPathComponent("Fixture")
            try! FileManager.default.copyItem(at: fixture, to: copied)
            benchmarkStore = DeckStore(directory: copied)
        }
        let slides = benchmarkStore.deck.slides
        var legacySeconds = 0.0, preparationSeconds = 0.0, workerSeconds = 0.0
        for slide in slides {
            let before = CFAbsoluteTimeGetCurrent()
            let old = ImageRenderer(content: StaticSlide(slide: slide, store: benchmarkStore).environment(\.colorScheme, .light)); old.scale = 212.0 / 1600
            _ = old.uiImage
            legacySeconds += CFAbsoluteTimeGetCurrent() - before
            let preparing = CFAbsoluteTimeGetCurrent()
            let layers = SlidePreviewRenderer.layers(slide, store: benchmarkStore)
            preparationSeconds += CFAbsoluteTimeGetCurrent() - preparing
            let start = CFAbsoluteTimeGetCurrent()
            _ = await Task.detached { SlidePreviewRenderer.render(layers, paper: slide.paper) }.value
            workerSeconds += CFAbsoluteTimeGetCurrent() - start
        }
        performance["legacyThumbnailMainThreadMs"] = legacySeconds * 1000
        performance["cachedThumbnailPreparationMainThreadMs"] = preparationSeconds * 1000
        performance["thumbnailWorkerMs"] = workerSeconds * 1000
        let element = SlideElement.text("Move me", x: 100, y: 100, width: 300, size: 40)
        let controller = TransformElementController(element: element, store: store, animateImages: false)
        let initialUpdates = controller.contentUpdates
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<1000 {
            var moved = element; moved.x += Double(i); moved.y += Double(i) / 2
            store.transformPreview.elements = [element.id: moved]
        }
        performance["nativeGeometryUpdatesMsPer1000"] = (CFAbsoluteTimeGetCurrent() - start) * 1000
        check(controller.contentUpdates == initialUpdates && controller.view.subviews.first!.center == CGPoint(x: 1249, y: 623.5), "A thousand drag samples reuse content and update native geometry without re-layout")
        store.transformPreview.elements = [:]
        let persistence = DeckPersistence(url: directory.appendingPathComponent("SaveOrdering.json"))
        var older = benchmarkStore.deck; older.title = "Earlier save"
        var newer = older; newer.title = "Latest save"
        persistence.save(older) { _ in }
        try! persistence.flush(newer)
        let saved = try! JSONDecoder().decode(StudioDeck.self, from: Data(contentsOf: directory.appendingPathComponent("SaveOrdering.json")))
        check(saved.title == "Latest save", "A synchronous final save cannot be overwritten by an older background save")
        let background = await withCheckedContinuation { continuation in
            persistence.save(newer) { error in continuation.resume(returning: error == nil && !Thread.isMainThread) }
        }
        check(background, "Deck encoding and disk writes run away from the main UI thread")
        let thumbnailStore = DeckStore(directory: directory.appendingPathComponent("Thumbnail"))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let red = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100), format: format).image { c in UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 100, height: 100)) }
        thumbnailStore.storeImage(red.pngData()!)
        var image = thumbnailStore.slide.elements.last!; image.x = 100; image.y = 100; image.width = 300; image.height = 300; thumbnailStore.update(image)
        let layers = SlidePreviewRenderer.layers(thumbnailStore.slide, store: thumbnailStore)
        let thumbnail = SlidePreviewRenderer.render(layers, paper: "FFFF00", width: 400)!
        check(CanvasSnapshot.color(in: UIImage(cgImage: thumbnail), at: CGPoint(x: 200, y: 200)) == "FF0000" && CanvasSnapshot.color(in: UIImage(cgImage: thumbnail), at: CGPoint(x: 800, y: 700)) == "FFFF00", "Small cached previews preserve image placement and slide background")
        let previousKey = SlidePreviewKey(slide: thumbnailStore.slide)
        thumbnailStore.deck.slides.append(StudioSlide(name: "Unrelated slide"))
        check(SlidePreviewKey(slide: thumbnailStore.slide) == previousKey, "Editing another slide does not invalidate this slide's preview")
        let atom = DrawingRasterizer.atoms([image], store: thumbnailStore)[0]
        let base = DrawingRasterizer.render([atom])!
        var shifted = image; shifted.x = 700
        let second = DrawingRasterizer.atoms([shifted], store: thumbnailStore)
        let appended = DrawingRasterizer.render(second, base: base)!
        let rebuilt = DrawingRasterizer.render([atom] + second)!
        check(FillPixels(image: appended)!.rgba == FillPixels(image: rebuilt)!.rgba, "Incremental raster append matches rebuilding all strokes pixel for pixel")
    }

    func importAndExportChecks(_ check: (Bool, String) -> Void) async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let store = DeckStore(directory: documents.appendingPathComponent("ImportedBrushTest"))
        await store.importBrushes(Bundle.main.url(forResource: "Rake_Brushpack", withExtension: "brushset")!)
        check(store.importedBrushes.count == 28, "All 28 supplied Procreate rake brushes import with their names and tips")
        let brush = store.importedBrushes[0]
        let tip = ImportedBrushTip.image(brush, folder: store.importedBrushFolder, color: "FF0000")!
        let canvas = StampStrokeView(frame: CGRect(x: 0, y: 0, width: 1600, height: 900))
        canvas.begin(brush: brush, tip: tip, width: 60, opacity: 1)
        canvas.add(CGPoint(x: 100, y: 100), pressure: 1, tilt: .pi / 2)
        canvas.add(CGPoint(x: 600, y: 100), pressure: 1, tilt: .pi / 2)
        let stroke = canvas.result()!
        check(stroke.1.width > 500 && FillPixels(image: stroke.0)!.rgba.contains(where: { $0 != 0 }), "Imported rake tips produce a continuous raster stroke")
        store.chooseImportedBrush(brush, eraser: false)
        let coordinator = DrawingCanvas(store: store, scale: 1).makeCoordinator()
        let input = StudioCanvasView(); coordinator.attach(input); coordinator.updateInput()
        check(!input.drawingGestureRecognizer.isEnabled, "Imported brushes bypass PencilKit's built-in tip renderer")
        let restored = DeckStore(directory: store.documents)
        check(restored.importedBrushes.map(\.name) == store.importedBrushes.map(\.name), "Imported brush libraries survive app relaunch")
        var bookmarks = BrushSizeBookmarks()
        bookmarks.toggle(42, brush: .round, erasing: false, customID: brush.id)
        check(bookmarks.sizes(for: .round, erasing: false, customID: brush.id) == [42] && bookmarks.sizes(for: .round, erasing: false).isEmpty, "Imported brush size bookmarks are independent from built-in brushes")
        let fm = FileManager.default
        let legacyBrushes = store.documents.appendingPathComponent("Brushes", isDirectory:true)
        try! fm.moveItem(at:store.importedBrushFolder, to:legacyBrushes)
        try! fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: legacyBrushes.path)
        let repaired = DeckStore(directory: store.documents)
        check(fm.isWritableFile(atPath: repaired.importedBrushFolder.path) && repaired.importedBrushes.map(\.id) == store.importedBrushes.map(\.id), "Read-only transferred brush folders are repaired without changing brush identities (writable: \(fm.isWritableFile(atPath: repaired.importedBrushFolder.path)), brushes: \(repaired.importedBrushes.count), error: \(repaired.errorMessage ?? "none"))")
        check(fm.fileExists(atPath:legacyBrushes.appendingPathComponent("Library.json").path), "Brush permission repair retains the complete original folder as a backup")
        check(ImportedBrushTip.image(repaired.importedBrushes[0], folder:repaired.importedBrushFolder, color:"336699") != nil, "Existing brush tips remain readable after storage permission repair")
        await store.importBrushes(Bundle.main.url(forResource: "COFEPencils", withExtension: "brushset")!)
        let pencils = Array(store.importedBrushes.dropFirst(28))
        check(pencils.count == 6 && pencils.filter { $0.source?.secondaryArchive != nil }.count == 4, "COFE imports six presets with four attached dual components, excluding Reset and Sub01 copies")
        check(pencils.filter { !($0.source?.missingAssets.isEmpty ?? true) }.count == 5, "Five COFE presets explicitly identify unavailable built-in Procreate textures")
        check(pencils.contains { $0.name == "COFE Pencil - B Soft" } && pencils.contains { $0.name == "Finger Smudge" }, "Procreate archived names are resolved from UID references")
        let soft = pencils.first { $0.name == "COFE Pencil - B Soft" }!
        check(abs(soft.source!.tilt.size - 0.66) < 0.001 && soft.source!.tilt.compression == 1 && soft.source!.azimuth, "Imported pencil tilt size, compression and azimuth settings are retained")
        check(pencils.first { $0.name == "Finger Smudge" }!.source!.note!.contains("smudging is not supported"), "Imported smudge tip is labeled with its unsupported behavior")
        let softTip = ImportedBrushTip.image(soft, folder: store.importedBrushFolder, color: "FF0000")!
        canvas.begin(brush:soft,tip:softTip,width:30,opacity:1,color:"FF0000")
        canvas.add(CGPoint(x:200,y:200),pressure:0.8,tilt:.pi/6,azimuth:.pi/2)
        let shadedPencil=canvas.result()!
        check(shadedPencil.1.height > shadedPencil.1.width * 2 && FillPixels(image:shadedPencil.0)!.rgba.contains { $0 != 0 }, "Imported pencil approximation renders broad shading in the Pencil azimuth direction")
        await store.importBundledBrushesIfNeeded()
        check(store.importedBrushes.count == 34, "Bundled pencil import is idempotent and preserves the existing rake library")
        let library = DeckStore(directory:store.documents)
        check(library.importedBrushes.count == 34 && library.importedBrushes.last!.source != nil, "Source metadata and imported presets survive relaunch")
        store.add(.text("Editable media", x: 80, y: 32, width: 1100, size: 64))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 400), format: format).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
            UIColor.systemYellow.setFill(); context.cgContext.fillEllipse(in: CGRect(x: 400, y: 35, width: 160, height: 160))
            UIColor.systemIndigo.setFill(); context.fill(CGRect(x: 0, y: 270, width: 640, height: 130))
        }
        store.storeImage(photo.pngData()!, name: "Photo & \"sun\" <PNG>")
        var firstPhoto = store.slide.elements.last!
        firstPhoto.x = 120; firstPhoto.y = 170; firstPhoto.width = 400; firstPhoto.height = 250
        firstPhoto.rotation = 15; firstPhoto.flipX = true; store.update(firstPhoto)
        let originalPNG = try! Data(contentsOf: store.assetURL(firstPhoto.asset!)!)
        store.add(.art("Underline", x: 100, y: 440, width: 450, height: 25))
        store.addLayer()
        store.changeLayer(store.activeLayer) { $0.opacity = 0.65 }
        let jpeg = photo.jpegData(compressionQuality: 0.9)!
        try! jpeg.write(to: store.mediaFolder.appendingPathComponent("Original.jpg"))
        store.add(SlideElement(kind: .image, x: 160, y: 510, width: 400, height: 250, asset: "Original.jpg", name: "Original JPEG", flipY: true))
        store.addLayer()
        store.importMedia(Bundle.main.url(forResource: "MotionStudy", withExtension: "mp4")!, kind: .video)
        var movie = store.slide.elements.last!
        movie.x = 850; movie.y = 160; movie.width = 560; movie.height = 315; store.update(movie)
        store.storeImage(try! Data(contentsOf: documents.appendingPathComponent("Playback-check.gif")), name: "Animated GIF")
        var animation = store.slide.elements.last!
        animation.x = 850; animation.y = 530; animation.width = 320; animation.height = 200; store.update(animation)
        store.add(.text("PNG · JPEG · Video · Animated GIF", x: 80, y: 820, width: 1400, size: 32))
        store.addLayer()
        store.storeImage(photo.pngData()!, name: "Hidden photo")
        store.add(.text("Hidden text", x: 10, y: 10, width: 500, size: 40))
        store.changeLayer(store.activeLayer) { $0.visible = false }
        store.deck.slides.append(StudioSlide(name: "Blank slide"))
        let textLayer = StudioLayer(opacity: 0.42)
        var styled = SlideElement.text("  Café & <notes> \"quoted\"  \r\n\r\nSecond line ✨\n", x: 120, y: 140, width: 600, size: 50, font: "Georgia-BoldItalic", color: "C43A64")
        styled.height = 320; styled.rotation = 23; styled.flipX = true; styled.flipY = true; styled.layerID = textLayer.id
        var empty = SlideElement.text("", x: 50, y: 600, width: 300, size: 32, font: "AvenirNext-Regular")
        empty.layerID = textLayer.id
        var handwriting = SlideElement.text("Handwritten text", x: 400, y: 650, width: 800, size: 60, font: "Noteworthy-Light")
        handwriting.layerID = textLayer.id
        store.deck.slides.append(StudioSlide(name: "Text formats", elements: [styled, empty, handwriting], layers: [textLayer]))
        let package = try! await store.exportKeynote()
        let files = try! BrushArchive.files(package)
        let video = files.first { $0.key.hasSuffix(".mp4") }!.value
        let gif = files.first { $0.key.hasSuffix(".gif") }!.value
        check(video == (try! Data(contentsOf: Bundle.main.url(forResource: "MotionStudy", withExtension: "mp4")!)), "PowerPoint export embeds the original video bytes")
        check(gif == (try! Data(contentsOf: documents.appendingPathComponent("Playback-check.gif"))), "PowerPoint export embeds all original GIF frames")
        let xml = String(data: files["ppt/slides/slide1.xml"]!, encoding: .utf8)!
        check(xml.contains("videoFile") && xml.contains("p14:media") && xml.contains("Animated GIF"), "Exported slide links its playable video and animated GIF")
        let pictures = xml.components(separatedBy: "<p:pic>").dropFirst().map { $0.components(separatedBy: "</p:pic>")[0] }
        check(pictures.count == 5 && !xml.contains("<p:grpSp>"), "Export keeps two photos, a GIF and a video ungrouped, interleaved with a drawing and two native text boxes")
        check(pictures[0].contains("Photo &amp; &quot;sun&quot; &lt;PNG&gt;") && pictures[2].contains("Original JPEG") && pictures[3].contains("Video") && pictures[4].contains("Animated GIF"), "Native media names are XML escaped and retain their stacking order around drawings and text")
        check(files["ppt/media/s1p1.png"] == originalPNG && files["ppt/media/s1p3.jpg"] == jpeg, "Static PNG and JPEG photos keep their original pixels and full resolution for native picture editing")
        check(pictures[0].contains("rot=\"900000\" flipH=\"1\" flipV=\"0\"") && pictures[0].contains("<a:off x=\"914400\" y=\"1295400\"/>") && pictures[0].contains("<a:ext cx=\"3048000\" cy=\"1905000\"/>"), "Native image position, independent dimensions, rotation and horizontal flip are preserved")
        check(pictures[2].contains("flipV=\"1\"") && pictures[2].contains("<a:alphaModFix amt=\"65000\"/>"), "Native pictures preserve vertical flipping and layer transparency")
        check(!xml.contains("Hidden photo") && !xml.contains("Hidden text") && !String(data: files["ppt/slides/slide2.xml"]!, encoding: .utf8)!.contains("<p:pic>"), "Hidden layers are excluded and blank slides contain no full-slide picture")
        check(String(data: files["[Content_Types].xml"]!, encoding: .utf8)!.contains("Extension=\"jpg\" ContentType=\"image/jpeg\""), "Native JPEG parts advertise the correct Office media type")
        let cropImage = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 900), format: format).image { c in
            UIColor.red.setFill(); c.fill(CGRect(x: 34, y: 57, width: 100, height: 80))
        }.cgImage!
        let cropped = try! KeynoteExporter.artworkPart(cropImage)!
        let croppedImage = UIImage(data: cropped.data)!
        check(cropped.rect == CGRect(x: 34, y: 57, width: 100, height: 80) && croppedImage.size == CGSize(width: 100, height: 80), "Artwork exports tightly cropped with its original canvas placement, avoiding invisible full-slide selection boxes")
        let transparent = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10), format: format).image { _ in }.cgImage!
        check((try! KeynoteExporter.artworkPart(transparent)) == nil, "Fully transparent artwork does not obstruct native media selection")
        let textBoxes = xml.components(separatedBy: "<p:sp>").dropFirst().map { $0.components(separatedBy: "</p:sp>")[0] }
        check(textBoxes.count == 2 && textBoxes[0].contains("txBox=\"1\"") && textBoxes[0].contains(">Editable media</a:t>") && textBoxes[1].contains(">PNG · JPEG · Video · Animated GIF</a:t>"), "Export writes text content into native editable PowerPoint text boxes")
        check(files["ppt/media/s1p0.png"] == nil && files["ppt/media/s1p6.png"] == nil, "Text export creates no raster copies or invisible picture overlays")
        check(textBoxes[0].contains("sz=\"3840\"") && textBoxes[0].contains("typeface=\"Georgia\"") && textBoxes[0].contains("val=\"24483E\""), "Native text keeps its font and color with the point size scaled to the exported slide")
        check(textBoxes[0].contains("wrap=\"square\" lIns=\"0\" tIns=\"0\" rIns=\"0\" bIns=\"0\" anchor=\"t\"") && textBoxes[0].contains("<a:noAutofit/>") && textBoxes[0].contains("<a:ext cx=\"8382000\" cy=\"585216\"/>"), "Native text wraps at the original width with no extra padding or automatic font shrinking")
        let textXML = String(data: files["ppt/slides/slide3.xml"]!, encoding: .utf8)!
        let formattedBoxes = textXML.components(separatedBy: "<p:sp>").dropFirst().map { $0.components(separatedBy: "</p:sp>")[0] }
        check(formattedBoxes.count == 3 && !textXML.contains("<p:pic>"), "A text-only slide exports entirely as native text, including empty editable boxes")
        check(formattedBoxes[0].contains("  Café &amp; &lt;notes&gt; &quot;quoted&quot;  ") && formattedBoxes[0].contains("Second line ✨") && formattedBoxes[0].components(separatedBy: "<a:p>").count == 5, "Native text preserves Unicode, spaces, blank lines and trailing newlines while escaping XML")
        check(formattedBoxes[0].contains("sz=\"3000\" b=\"1\" i=\"1\"") && formattedBoxes[0].contains("val=\"C43A64\"") && formattedBoxes[0].contains("<a:alpha val=\"42000\"/>"), "Native text retains bold, italic, text color and layer opacity")
        check(formattedBoxes[0].contains("rot=\"1380000\" flipH=\"1\" flipV=\"1\"") && formattedBoxes[0].contains("<a:off x=\"914400\" y=\"1066800\"/>") && formattedBoxes[0].contains("<a:ext cx=\"4572000\" cy=\"2438400\"/>"), "Native text boxes retain position, independent dimensions, rotation and flips")
        check(formattedBoxes[1].contains("typeface=\"Avenir Next\"") && formattedBoxes[2].contains("typeface=\"Noteworthy\""), "Apple font identifiers are translated into font family names that presentation editors understand")
        try! package.write(to: documents.appendingPathComponent("Media-export-check.pptx"))
    }

    func textAndClipboardChecks(_ check: (Bool, String) -> Void) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let store = DeckStore(directory: documents.appendingPathComponent(UUID().uuidString))
        store.saveText("This text wraps onto several lines when the box becomes narrower.", font: "Georgia", size: 64, color: "111111", editing: nil)
        let original = store.slide.elements[0], base = store.activeLayer
        check(store.layers.count == 1 && original.layerID == base.id, "Creating text keeps it on the current layer")
        store.beginPickerColorEdit(); store.setPickerColor("FF0000"); store.setPickerColor("00FF00"); store.setPickerColor("0000FF"); store.endPickerColorEdit()
        check(store.slide.elements[0].color == "0000FF" && store.layers.count == 1, "The canvas color picker recolors selected text without creating a layer")
        store.undo()
        check(store.slide.elements[0].color == "111111", "One undo restores the color before a continuous picker session")
        store.selected = original.id; store.tool = .transform
        var edits = 0
        let observation = store.textEditRequests.sink { if $0 == original.id { edits += 1 } }
        let editor = CanvasEditingSession()
        editor.begin(at: original.center, store: store, scale: 1); editor.end(at: original.center, store: store, scale: 1)
        check(edits == 1, "Tapping an already-selected text box requests text editing")
        store.selected = nil
        editor.begin(at: original.center, store: store, scale: 1); editor.end(at: original.center, store: store, scale: 1)
        check(store.selected == original.id && edits == 1, "The first tap selects text without opening its editor")
        editor.begin(at: original.center, store: store, scale: 1); editor.end(at: CGPoint(x: original.center.x + 20, y: original.center.y), store: store, scale: 1)
        check(edits == 1 && store.slide.elements[0].x == original.x + 20, "Dragging selected text moves it without opening the editor")
        store.undo(); store.selected = original.id
        let handle = Geometry.handles(store.selectionBounds!)[3]
        editor.begin(at: handle, store: store, scale: 1); editor.end(at: CGPoint(x: handle.x - 700, y: handle.y), store: store, scale: 1)
        let wrapped = store.slide.elements[0]
        check(wrapped.width == 400 && wrapped.fontSize == 64 && wrapped.height > original.height, "Text width handles reflow lines and grow the box without scaling the font")
        store.undo(); store.selected = original.id
        store.changeTextStyle(original.id, font: "AvenirNext-Regular", size: 96)
        check(store.slide.elements[0].fontSize == 96 && store.slide.elements[0].font == "AvenirNext-Regular" && store.slide.elements[0].width == original.width, "Existing text can change font and size while retaining its width")
        store.saveText("Edited after creation", font: "Georgia", size: 48, color: "334455", editing: original.id)
        check(store.slide.elements.count == 1 && store.slide.elements[0].id == original.id && store.slide.elements[0].text == "Edited after creation" && store.slide.elements[0].layerID == base.id, "Editing text updates the existing object on its original layer")
        observation.cancel()
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        store.add(.text("Unselected", x: 40, y: 600, width: 300, size: 40))
        let otherID = store.slide.elements.last!.id
        store.addLayer(); let upper = store.activeLayer; store.selectLayer(base); store.selected = original.id
        store.performClipboard(.copy, pasteboard: board)
        check(store.layers.count == 2 && store.slide.elements.count == 2 && board.contains(pasteboardTypes: [SlideClipboard.type, UTType.png.identifier]), "Copy leaves artwork intact and offers editable data plus a PNG")
        store.performClipboard(.paste, pasteboard: board)
        let pasted = store.slide.elements.last!
        check(store.layers.count == 3 && store.layers[1].id == pasted.layerID && store.layers[2].id == upper.id && pasted.kind == .text && pasted.id != original.id && pasted.text == "Edited after creation", "Paste creates an editable text copy on a new layer immediately above the active one")
        store.undo()
        check(store.layers.count == 2 && store.slide.elements.count == 2, "One undo removes both a pasted object and its new layer")
        store.selectLayer(base); store.selected = original.id
        store.performClipboard(.cutPaste, pasteboard: board)
        check(store.layers.count == 3 && store.slide.elements.count == 2 && !store.slide.elements.contains(where: { $0.id == original.id }) && store.slide.elements.first(where: { $0.id == otherID })?.layerID == base.id, "Cut & Paste moves only selected content to a new layer")
        store.undo(); store.selectLayer(base); store.selected = original.id
        check(store.slide.elements.contains(where: { $0.id == original.id }) && store.layers.count == 2, "One undo restores the source and removes a Cut & Paste layer")
        store.performClipboard(.duplicate, pasteboard: board)
        check(store.layers.count == 3 && store.slide.elements.count == 3 && store.slide.elements.contains(where: { $0.id == original.id }), "Duplicate keeps the source and puts a copy on a new layer")
        store.undo(); store.selectLayer(base); store.selected = original.id
        store.performClipboard(.cut, pasteboard: board)
        check(store.slide.elements.count == 1 && store.layers.count == 2 && board.contains(pasteboardTypes: [SlideClipboard.type]), "Cut removes only the selection and keeps its editable clipboard data")
        store.undo(); store.selectLayer(base); store.selected = nil
        store.performClipboard(.copyAll, pasteboard: board)
        let all = try! JSONDecoder().decode(SlideClipboard.self, from: board.data(forPasteboardType: SlideClipboard.type)!)
        check(all.elements.count == 1 && all.elements[0].kind == .image && all.elements[0].width == 1600 && all.assets["canvas.png"] != nil, "Copy All flattens visible layers into a single canvas image")
        store.changeLayer(base) { $0.locked = true }
        check(!store.canPerformClipboard(.cut, pasteboard: board) && store.canPerformClipboard(.copy, pasteboard: board), "Locked layers can be copied but cannot be cut")
        store.changeLayer(store.activeLayer) { $0.locked = false }
        store.importMedia(documents.appendingPathComponent("Playback-check.gif"), kind: .image)
        store.performClipboard(.copy, pasteboard: board); store.performClipboard(.paste, pasteboard: board)
        let gif = store.slide.elements.last!
        check(gif.asset?.hasSuffix(".gif") == true && GIFAnimation(url: store.assetURL(gif.asset!)!)?.frameCount == 3, "Clipboard copies preserve GIF animation")
        check(ThreeFingerSwipe.isDownward([CGPoint(x: 2, y: 65), CGPoint(x: -4, y: 70), CGPoint(x: 0, y: 66)], scale: 0.5), "Three fingers moving down open the clipboard gesture at any canvas scale")
        check(!ThreeFingerSwipe.isDownward([.zero, .zero, .zero], scale: 1) && !ThreeFingerSwipe.isDownward([CGPoint(x: 80, y: 30), CGPoint(x: 80, y: 30), CGPoint(x: 80, y: 30)], scale: 1) && !ThreeFingerSwipe.isDownward([CGPoint(x: 0, y: 80), CGPoint(x: 0, y: 80)], scale: 1), "Taps, sideways motion, and two fingers do not trigger the swipe menu")
    }

    func freeformAndVideoChecks(_ check: (Bool, String) -> Void) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let store = DeckStore(directory: documents.appendingPathComponent(UUID().uuidString))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 80), format: format).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
        }
        store.storeImage(image.pngData()!)
        var element = store.slide.elements[0]; element.x = 100; element.y = 100; element.width = 200; element.height = 400; store.update(element)
        store.uniformTransform = false
        let editor = CanvasEditingSession()
        var handle = Geometry.handles(store.selectionBounds!)[3]
        editor.begin(at: handle, store: store, scale: 1); editor.end(at: CGPoint(x: handle.x + 200, y: handle.y), store: store, scale: 1)
        check(store.slide.elements[0].width == 400 && store.slide.elements[0].height == 400, "Freeform can stretch width independently of height")
        handle = Geometry.handles(store.selectionBounds!)[5]
        editor.begin(at: handle, store: store, scale: 1); editor.end(at: CGPoint(x: handle.x, y: handle.y + 100), store: store, scale: 1)
        check(store.slide.elements[0].width == 400 && store.slide.elements[0].height == 500, "Freeform can stretch height independently of width")
        let rendered = CanvasSnapshot.render(store: store)!
        check(CanvasSnapshot.color(in: rendered, at: CGPoint(x: 110, y: 110)) == "0000FF" && CanvasSnapshot.color(in: rendered, at: CGPoint(x: 490, y: 590)) == "0000FF", "Freeform stretches actual image pixels to the bounds instead of letterboxing")
        store.uniformTransform = true
        handle = Geometry.handles(store.selectionBounds!)[3]
        editor.begin(at: handle, store: store, scale: 1); editor.end(at: CGPoint(x: handle.x + 400, y: handle.y), store: store, scale: 1)
        check(store.slide.elements[0].width == 800 && store.slide.elements[0].height == 1000, "Uniform transform still preserves the element's proportions")
        let video = Bundle.main.url(forResource: "MotionStudy", withExtension: "mp4")!
        store.importMedia(video, kind: .video)
        let id = store.slide.elements.last!.id
        store.toggleVideoPlayback(id)
        check(store.editorVideoID == id && !store.editorVideoPaused, "A selected video can start directly on the editing canvas")
        store.toggleVideoPlayback(id)
        check(store.editorVideoPaused, "The editor video button pauses playback")
        store.tappedSelectedElement(id)
        check(!store.editorVideoPaused, "Tapping an already-selected video resumes canvas playback")
        store.selected = nil
        check(store.editorVideoID == nil, "Deselecting the video stops editor playback")
        store.selected = id
        check(store.slide.elements.last!.videoOptions == nil && !VideoOptions().autoplay, "Existing videos default to click-to-play at normal speed")
        store.changeVideoOptions(id) { $0.speed = 1.5; $0.autoplay = true; $0.loop = true; $0.muted = true }
        check(store.slide.elements.last!.videoOptions == VideoOptions(speed: 1.5, autoplay: true, loop: true, muted: true), "Video settings store speed, slide autostart, loop, and audio")
        store.undo(); check(store.slide.elements.last!.videoOptions == nil, "Video setting changes can be undone")
        store.redo(); store.saveNow()
        let loaded = DeckStore(directory: store.documents)
        check(loaded.slide.elements.last!.videoOptions?.speed == 1.5 && loaded.slide.elements.last!.videoOptions?.loop == true, "Video playback settings survive reopening the deck")
        let board = UIPasteboard.withUniqueName(); defer { UIPasteboard.remove(withName: board.name) }
        store.selected = id; store.performClipboard(.copy, pasteboard: board); store.performClipboard(.paste, pasteboard: board)
        check(store.slide.elements.last!.kind == .video && store.slide.elements.last!.videoOptions?.autoplay == true && store.slide.elements.last!.asset?.hasSuffix(".mp4") == true, "Copy and paste keep videos playable with their playback settings")
    }

    func gifChecks(_ check: (Bool, String) -> Void) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fixture = documents.appendingPathComponent("Playback-check.gif")
        let data = NSMutableData()
        let writer = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 3, nil)!
        CGImageDestinationSetProperties(writer, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        for (color, delay) in [(UIColor.red, 0.6), (UIColor.green, 1.0), (UIColor.blue, 0.8)] {
            let frame = UIGraphicsImageRenderer(size: CGSize(width: 128, height: 96), format: format).image { context in
                color.setFill(); context.fill(CGRect(x: 16, y: 16, width: 96, height: 64))
            }
            CGImageDestinationAddImage(writer, frame.cgImage!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        check(CGImageDestinationFinalize(writer), "A multi-frame GIF fixture is encoded successfully")
        try! (data as Data).write(to: fixture)
        let store = DeckStore(directory: documents.appendingPathComponent(UUID().uuidString))
        store.importMedia(fixture, kind: .image)
        let element = store.slide.elements.last!, url = store.assetURL(element.asset!)!
        check(url.pathExtension == "gif" && (try! Data(contentsOf: url)) == data as Data, "Import preserves the complete GIF file instead of flattening it to PNG")
        let animation = GIFAnimation(url: url)!
        check(animation.frameCount == 3 && abs(animation.duration - 2.4) < 0.01, "GIF playback retains each frame's original duration")
        check(animation.frameIndex(at: 0.2) == 0 && animation.frameIndex(at: 0.7) == 1 && animation.frameIndex(at: 1.7) == 2 && animation.frameIndex(at: 2.5) == 0, "GIF playback advances through frames and loops at the correct time")
        let first = animation.frame(at: 0)!, second = animation.frame(at: 1)!
        check(CanvasSnapshot.color(in: first, at: CGPoint(x: 800, y: 450)) == "FF0000" && CanvasSnapshot.color(in: second, at: CGPoint(x: 800, y: 450)) == "00FF00", "The GIF renderer decodes visually distinct frames")
        check(FillPixels(image: first.cgImage!)!.alpha(at: .zero) == 0, "GIF transparency survives frame decoding")
        check(CanvasSnapshot.color(in: CanvasSnapshot.render(store: store)!, at: CGPoint(x: 800, y: 450)) == "FF0000", "Static thumbnails and canvas snapshots retain a visible GIF poster")
        store.undo(); check(store.slide.elements.isEmpty, "Adding a GIF is one undo step")
        store.redo(); check(store.slide.elements.count == 1 && (try! Data(contentsOf: url)) == data as Data, "Redo restores the animated GIF without changing its data")
        store.saveNow()
        let loaded = DeckStore(directory: store.documents)
        check(GIFAnimation(url: loaded.assetURL(loaded.slide.elements.last!.asset!)!)?.frameCount == 3, "GIF animations survive saving and reopening a deck")
        let packageURL = documents.appendingPathComponent("GIF-roundtrip.json")
        try! store.exportDeck().write(to: packageURL)
        let imported = DeckStore(directory: documents.appendingPathComponent(UUID().uuidString))
        imported.importDeck(packageURL)
        let importedURL = imported.assetURL(imported.slide.elements.last!.asset!)!
        check((try! Data(contentsOf: importedURL)) == data as Data && GIFAnimation(url: importedURL)?.frameCount == 3, "Editable deck export and import preserve every GIF frame")
    }

    func colorDropChecks(_ check: (Bool, String) -> Void) {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let linework = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 900), format: format).image { context in
            UIColor.black.setStroke(); context.cgContext.setLineWidth(8)
            context.cgContext.stroke(CGRect(x: 100, y: 100, width: 300, height: 200))
            context.cgContext.stroke(CGRect(x: 600, y: 500, width: 200, height: 100))
        }
        let pixels = FillPixels(image: linework.cgImage!)!
        let seed = CGPoint(x: 200, y: 180)
        let region = ColorFillEngine.fill(pixels, at: seed, hex: "00FF00", threshold: 0.2, expandEdges: true)!
        check(region.bounds.minX > 95 && region.bounds.minY > 95 && region.bounds.maxX < 405 && region.bounds.maxY < 305, "ColorDrop stays inside the selected outline with correct canvas coordinates")
        check(ColorFillEngine.fill(pixels, at: CGPoint(x: -1, y: 100), hex: "00FF00", threshold: 0.2, expandEdges: true) == nil, "Dropping outside the canvas produces no fill")
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(UUID().uuidString)
        let store = DeckStore(directory: folder)
        store.storeImage(linework.pngData()!)
        var outline = store.slide.elements.last!; outline.x = 0; outline.y = 0; outline.width = 1600; outline.height = 900; store.update(outline)
        let reference = store.activeLayer
        store.toggleReference(reference); store.addLayer()
        let fillLayerID = store.activeLayer.id
        let renderedReference = store.layerPixels(store.referenceLayer!)!
        let referenceFill = ColorFillEngine.fill(renderedReference, at: seed, hex: "00FF00", threshold: 0.2, expandEdges: true)!
        try! store.commitColorFill(referenceFill, layerID: fillLayerID, behind: true)
        let image = CanvasSnapshot.render(store: store)!
        check(CanvasSnapshot.color(in: image, at: seed) == "00FF00" && CanvasSnapshot.color(in: image, at: CGPoint(x: 700, y: 550)) == "FFFFFF", "Reference-layer fill colors the chosen region without filling another closed region")
        check(store.slide.elements.first?.id == outline.id && store.slide.elements.last?.layerID == fillLayerID && store.slide.elements.last?.kind == .fill, "Reference linework stays untouched while the fill is placed on the active layer")
        check(CanvasSnapshot.color(in: image, at: CGPoint(x: 100, y: 180)) == "000000", "ColorDrop preserves the reference outline")
        store.undo()
        check(store.slide.elements.count == 1 && store.referenceLayer?.id == reference.id, "One undo removes the fill and retains the reference layer")
        store.redo()
        check(CanvasSnapshot.color(in: CanvasSnapshot.render(store: store)!, at: seed) == "00FF00", "Redo restores a color fill")
        let recolor = ColorFillEngine.fill(renderedReference, at: seed, hex: "0000FF", threshold: 0.2, expandEdges: false)!
        let fillID = store.slide.elements.last!.id
        try! store.commitColorFill(recolor, layerID: fillLayerID, behind: false)
        check(store.slide.elements.filter { $0.kind == .fill }.count == 1 && store.slide.elements.last!.id == fillID, "Recoloring one bounded region updates the existing fill instead of stacking objects")
        check(CanvasSnapshot.color(in: CanvasSnapshot.render(store: store)!, at: seed) == "0000FF", "An existing filled region can be recolored")
        store.saveNow()
        let loaded = DeckStore(directory: folder)
        check(loaded.slide.referenceLayerID == reference.id && CanvasSnapshot.color(in: CanvasSnapshot.render(store: loaded)!, at: seed) == "0000FF", "Reference settings and color fills survive reopening the deck")
        store.changeLayer(store.activeLayer) { $0.locked = true }
        let count = store.slide.elements.count
        try! store.commitColorFill(recolor, layerID: fillLayerID, behind: false)
        check(store.slide.elements.count == count, "Locked layers reject color fills")
        store.toggleReference(reference); store.addLayer()
        let empty = store.layerPixels(store.activeLayer)!
        let wholeLayer = ColorFillEngine.fill(empty, at: seed, hex: "FF0000", threshold: 0.2, expandEdges: true)!
        check(wholeLayer.bounds == CGRect(x: 0, y: 0, width: 1600, height: 900), "An empty layer fills completely when no reference is selected")
        let tones = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 10), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
            UIColor(white: 0.8, alpha: 1).setFill(); context.fill(CGRect(x: 10, y: 0, width: 10, height: 10))
        }
        let tonePixels = FillPixels(image: tones.cgImage!)!
        let low = ColorFillEngine.fill(tonePixels, at: CGPoint(x: 2, y: 2), hex: "FF0000", threshold: 0.1, expandEdges: false)!
        let high = ColorFillEngine.fill(tonePixels, at: CGPoint(x: 2, y: 2), hex: "FF0000", threshold: 0.3, expandEdges: false)!
        check(low.bounds.width == 10 && high.bounds.width == 20, "ColorDrop threshold controls how far a fill crosses similar colors")
    }

    func refinementChecks(_ check: (Bool, String) -> Void) {
        let store = DeckStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let first = store.slide.id; store.addSlide(); let second = store.slide.id; store.addSlide(); let third = store.slide.id
        store.selectSlide(1); store.reorderSlide(third, relativeTo: first, after: false)
        check(store.deck.slides.map(\.id) == [third, first, second] && store.slide.id == second, "Dragging a slide changes order while preserving the selected slide")
        store.undo(); check(store.deck.slides.map(\.id) == [first, second, third] && store.slide.id == second, "Undo restores slide order and keeps the same slide active")
        let rect = CGRect(x: -400, y: -100, width: 3200, height: 1800)
        let point = CanvasViewportGeometry.canvasPoint(CGPoint(x: 0, y: 800), in: rect)
        check(point == CGPoint(x: 200, y: 450), "ColorDrop coordinates remain correct after zooming and panning")
        check(CanvasViewportGeometry.fit(CGSize(width: 1132, height: 960)) == 0.625, "Canvas fit leaves room for drawing controls")
        let a = SlideElement.text("A", x: 100, y: 100, width: 100, size: 40)
        let b = SlideElement.text("B", x: 100, y: 100, width: 100, size: 40)
        let c = SlideElement.text("C", x: 100, y: 100, width: 100, size: 40)
        store.add(a); store.add(b); store.add(c); store.selectedIDs = [a.id, b.id]
        store.orderSelection(.front); check(store.slide.elements.map(\.id) == [c.id, a.id, b.id], "Bring to front preserves the selected group's internal order")
        store.orderSelection(.back); check(store.slide.elements.map(\.id) == [a.id, b.id, c.id], "Send to back moves the group together")
        store.orderSelection(.forward); check(store.slide.elements.map(\.id) == [c.id, a.id, b.id], "Bring forward crosses one neighboring object")
        store.orderSelection(.backward); check(store.slide.elements.map(\.id) == [a.id, b.id, c.id], "Send backward crosses one neighboring object")
        check(store.boundaryElements(in: store.activeLayer).isEmpty, "Text is excluded from fill boundaries")
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1600, height: 900), format: format).image { c in
            UIColor.red.setFill(); c.fill(CGRect(x: 100, y: 100, width: 200, height: 100))
            UIColor.blue.setFill(); c.fill(CGRect(x: 600, y: 600, width: 100, height: 100))
        }
        let atom = RasterAtom(image: image.cgImage!, rect: CGRect(x: 0, y: 0, width: 1600, height: 900), rotation: 0, flipX: false, flipY: false, mode: .normal)
        let rendered = DrawingRasterizer.render([atom])!
        check(CanvasSnapshot.color(in: UIImage(cgImage: rendered), at: CGPoint(x: 150, y: 120)) == "FF0000" && CanvasSnapshot.color(in: UIImage(cgImage: rendered), at: CGPoint(x: 650, y: 650)) == "0000FF", "Raster flattening preserves top/bottom orientation and exact colors")
        let cut = PixelSelectionEngine.cut(art: [atom], linework: [atom], points: [CGPoint(x: 80, y: 80), CGPoint(x: 200, y: 80), CGPoint(x: 200, y: 220), CGPoint(x: 80, y: 220)])!
        let remaining = FillPixels(image: UIImage(data: cut.remaining)!.cgImage!)!
        let selected = FillPixels(image: UIImage(data: cut.selected)!.cgImage!)!
        check(remaining.alpha(at: CGPoint(x: 150, y: 120)) == 0 && remaining.alpha(at: CGPoint(x: 250, y: 120)) == 255 && selected.alpha(at: CGPoint(x: 70, y: 40)) == 255, "Pixel lasso cuts only the enclosed part of a continuous drawing")
        let reference = store.activeLayer
        store.storeImage(image.pngData()!); store.toggleReference(reference)
        check(store.boundaryElements(in: reference).count == 1, "Imported reference linework remains eligible while text is ignored")
        let source = FillPixels(image: rendered)!
        let start = CFAbsoluteTimeGetCurrent()
        _ = ColorFillEngine.fill(source, at: CGPoint(x: 1000, y: 450), hex: "00FF00", threshold: 0.2, expandEdges: true)
        print("Color fill worker seconds: \(CFAbsoluteTimeGetCurrent() - start)")
    }

    func layerChecks(_ check: (Bool, String) -> Void) {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(UUID().uuidString)
        let store = DeckStore(directory: folder)
        func paint(_ color: UIColor) {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200)).image { context in color.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 200)) }
            store.storeImage(image.pngData()!)
            var element = store.slide.elements.last!; element.x = 100; element.y = 100; element.width = 200; element.height = 200; store.update(element)
        }
        func color(_ x: Double = 200, _ y: Double = 200) -> String? { CanvasSnapshot.color(in: CanvasSnapshot.render(store: store)!, at: CGPoint(x: x, y: y)) }
        paint(.red)
        let lower = store.activeLayer
        store.addLayer(); paint(.blue)
        check(store.layers.count == 2 && store.slide.elements.map(\.layerID) == [lower.id, store.activeLayer.id], "Only Add layer creates a new layer")
        check(color() == "0000FF", "Normal layers render in their stacking order")
        store.changeLayer(store.activeLayer) { $0.blendMode = .multiply }
        check(color() == "000000", "Multiply blends the upper layer with the lower layer")
        store.changeLayer(store.activeLayer) { $0.blendMode = .screen }
        check(color() == "FF00FF", "Screen blends the upper layer with the lower layer")
        store.changeLayer(store.activeLayer) { $0.blendMode = .normal; $0.visible = false }
        check(color() == "FF0000", "Hiding a layer reveals the lower layer")
        store.changeLayer(store.activeLayer) { $0.visible = true; $0.locked = true }
        let before = store.slide.elements.count
        store.add(.text("Locked", x: 0, y: 0, width: 100, size: 20))
        check(store.slide.elements.count == before && store.editableElements.isEmpty, "Locked layers reject edits and selections")
        store.changeLayer(store.activeLayer) { $0.locked = false }
        store.commitEraser(EraserMark(points: [MarkPoint(CGPoint(x: 200, y: 200))], brush: .round, width: 60, opacity: 1))
        check(color() == "FF0000" && color(260, 200) == "0000FF", "Round eraser cuts only its footprint from the active layer")
        let originalErase = store.slide.elements.last!
        var resizedErase = originalErase
        resizedErase.width *= 2; resizedErase.height *= 2
        store.update(resizedErase)
        check(color(260, 260) == "FF0000", "Transforming an eraser mark scales its footprint with the layer content")
        store.update(originalErase)
        paint(.green)
        check(color() == "00FF00", "New paint can cover an erased area on the same layer")
        store.undo()
        check(color() == "FF0000", "Undoing new paint preserves the earlier erasure")
        store.undo()
        check(color() == "0000FF", "Undoing erasure restores the original pixels")
        store.commitEraser(EraserMark(points: [MarkPoint(CGPoint(x: 200, y: 200))], brush: .flat, width: 80, opacity: 1))
        check(color() == "FF0000" && color(200, 225) == "0000FF" && color(225, 185) == "FF0000", "Flat eraser has a wide, angled nib distinct from Round")
        store.undo()
        store.changeLayer(store.activeLayer) { $0.opacity = 0.5 }
        check(color() == "800080" || color() == "7F0080", "Layer opacity blends the entire layer once")
        store.saveNow()
        let loaded = DeckStore(directory: folder)
        check(loaded.layers.count == 2 && loaded.layers.last?.opacity == 0.5, "Layer settings survive saving and reloading")
        store.duplicateDrawingLayer(store.activeLayer)
        check(store.layers.count == 3 && store.slide.elements.count == 3, "Duplicating a layer copies its content")
        store.undo()
        check(store.layers.count == 2 && store.slide.elements.count == 2, "Undo restores the layer structure")
        store.moveDrawingLayer(lower, by: 1)
        check(color() == "FF0000", "Layer reordering changes the composite")
        var legacy = StudioDeck.blank; legacy.version = 1; legacy.slides[0].layers = nil
        legacy.slides[0].elements = [.text("Legacy", x: 0, y: 0, width: 100, size: 20)]
        let migrated = DeckStore.withLayers(legacy)
        check(migrated.slides[0].layers?.count == 1 && migrated.slides[0].elements[0].layerID == migrated.slides[0].layers?[0].id, "Older decks migrate all content into one layer")
    }
}

private struct RasterDisplayHarness: View {
    @ObservedObject var store: DeckStore
    @ObservedObject var viewport: CanvasViewportState
    var body: some View {
        CanvasViewport(state: viewport, content:
            ZStack(alignment: .topLeading) {
                Color(hex: store.slide.paper)
                ForEach(store.layers) { layer in
                    if layer.visible {
                        EditableLayerElements(slide: store.slide, layer: layer, store: store, animateImages: false)
                            .compositingGroup().opacity(layer.opacity).blendMode(layer.blendMode.blend)
                    }
                }
            }.frame(width: 1600, height: 900)
        ).ignoresSafeArea()
    }
}
