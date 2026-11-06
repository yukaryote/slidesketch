import SwiftUI
import PencilKit
import Combine
import UIKit.UIGestureRecognizerSubclass

final class StudioCanvasView: PKCanvasView {
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
}

enum ThreeFingerSwipe {
    static func isDownward(_ translations: [CGPoint], scale: Double) -> Bool {
        translations.count == 3 && translations.allSatisfy { $0.y * scale >= 30 && abs($0.x) < $0.y * 0.85 }
    }
}

// Observes the entire touch chord so a three-finger redo cannot also trigger undo.
final class HistoryTapGesture: UIGestureRecognizer {
    var onFirstTouch: (() -> Void)?
    var onMultipleTouches: (() -> Void)?
    var onFinish: ((Int?) -> Void)?
    var onSwipeDown: ((CGPoint) -> Void)?
    var scale = 1.0
    private var positions: [ObjectIdentifier: CGPoint] = [:]
    private var swiped = false
    private var touchesByID: [ObjectIdentifier: CGPoint] = [:]
    private var peak = 0
    private var beganAt: TimeInterval = 0
    private var moved = false
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if touchesByID.isEmpty { beganAt = event.timestamp; onFirstTouch?() }
        for touch in touches { touchesByID[ObjectIdentifier(touch)] = touch.location(in: view); positions[ObjectIdentifier(touch)] = touch.location(in: view) }
        let previous = peak; peak = max(peak, touchesByID.count)
        if previous < 2 && peak >= 2 { onMultipleTouches?() }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            positions[ObjectIdentifier(touch)] = touch.location(in: view)
            if let origin = touchesByID[ObjectIdentifier(touch)], Geometry.distance(origin, touch.location(in: view)) * scale > 12 { moved = true }
        }
        if peak == 3, touchesByID.count == 3, !swiped {
            let translations = touchesByID.map { id, start in CGPoint(x: (positions[id]?.x ?? start.x) - start.x, y: (positions[id]?.y ?? start.y) - start.y) }
            if ThreeFingerSwipe.isDownward(translations, scale: scale) {
                swiped = true; moved = true
                let points = Array(positions.values)
                onSwipeDown?(CGPoint(x: points.map(\.x).reduce(0, +) / 3, y: points.map(\.y).reduce(0, +) / 3))
            }
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches { touchesByID.removeValue(forKey: ObjectIdentifier(touch)); positions.removeValue(forKey: ObjectIdentifier(touch)) }
        if touchesByID.isEmpty {
            let valid = !moved && event.timestamp - beganAt < 0.35 && (peak == 2 || peak == 3)
            onFinish?(valid ? peak : nil); state = valid ? .recognized : .failed
        }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { onFinish?(nil); state = .cancelled }
    func invalidateTap() { moved = true }
    override func reset() { touchesByID = [:]; positions = [:]; peak = 0; moved = false; swiped = false }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}

// Custom curves shape coalesced Pencil input before it reaches the PencilKit renderer,
// so the live stroke and saved stroke use exactly the same pressure response.
final class PressureStrokeGesture: UIGestureRecognizer {
    var onSamples: (([UITouch], UIGestureRecognizer.State) -> Void)?
    private var activeTouch: UITouch?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch; state = .began; onSamples?([touch], .began)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        state = .changed; onSamples?(event.coalescedTouches(for: touch) ?? [touch], .changed)
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        onSamples?(event.coalescedTouches(for: touch) ?? [touch], .ended); state = .ended
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { onSamples?([], .cancelled); state = .cancelled }
    override func reset() { activeTouch = nil }
}

struct DrawingCanvas: UIViewRepresentable {
    @ObservedObject var store: DeckStore
    var scale: Double
    func makeUIView(context: Context) -> StudioCanvasView {
        let canvas = StudioCanvasView()
        canvas.backgroundColor = .clear; canvas.isOpaque = false
        canvas.isScrollEnabled = false; canvas.bounces = false
        canvas.contentSize = store.canvasSize
        canvas.overrideUserInterfaceStyle = SlideInkRendering.appearance
        canvas.accessibilityLabel = "Slide canvas. Two-finger tap to undo. Three-finger swipe down for Copy and Paste. Hold to pick a color. Double-tap the side of Apple Pencil to switch brush and eraser."
        context.coordinator.attach(canvas)
        return canvas
    }
    func updateUIView(_ canvas: StudioCanvasView, context: Context) {
        context.coordinator.parent = self
        let desired = PKInkingTool(store.brush.inkType, color: UIColor(Color(hex: store.ink)).withAlphaComponent(store.opacity), width: store.brushSize)
        if let existing = canvas.tool as? PKInkingTool, existing.inkType == desired.inkType, existing.color == desired.color, existing.width == desired.width { }
        else { canvas.tool = desired }
        canvas.drawingPolicy = store.pencilOnly ? .pencilOnly : .anyInput
        context.coordinator.updateInput()
    }
    static func dismantleUIView(_ canvas: StudioCanvasView, coordinator: Coordinator) { coordinator.detach() }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
        var parent: DrawingCanvas
        weak var canvas: StudioCanvasView?
        var commit: DispatchWorkItem?
        private var usingTool = false
        private var suppressed = false
        private var subscription: AnyCancellable?
        private let editing = CanvasEditingSession()
        private var snapshot: UIImage?
        private var returnTool: EditorTool = .draw
        private let slideID: UUID
        private var pressurePoints: [PKStrokePoint] = []
        private var strokeStart: TimeInterval = 0
        private var strokeBrush: StudioBrush = .graphite
        private var strokeLayerID: UUID?
        private var strokeDate = Date()
        private var liveStroke: PKStroke?
        private var stabilizer = StrokeStabilizer()
        private let editingGesture = PressureStrokeGesture()
        private lazy var hold = UILongPressGestureRecognizer(target: self, action: #selector(held))
        private let history = HistoryTapGesture()
        private let pressure = PressureStrokeGesture()
        private let pencilInteraction = UIPencilInteraction()
        private let stamps = StampStrokeView()
        private let graphite = GraphiteStrokeView()
        private var fingerPencil = FingerPencilDynamics()
        private var graphiteErasing = false
        private var graphiteWidth = 8.0
        private var graphiteOpacity = 1.0
        private var stampErasing = false
        init(_ parent: DrawingCanvas) { self.parent = parent; slideID = parent.store.slide.id }
        func attach(_ canvas: StudioCanvasView) {
            self.canvas = canvas; canvas.delegate = self
            pencilInteraction.delegate = self
            canvas.addInteraction(pencilInteraction)
            GraphiteStrokeRaster.prepareTexture()
            stamps.frame = store.canvasBounds; stamps.backgroundColor = .clear; stamps.isOpaque = false; stamps.isUserInteractionEnabled = false; stamps.isHidden = true
            canvas.addSubview(stamps)
            graphite.frame = stamps.frame; graphite.backgroundColor = .clear; graphite.isOpaque = false; graphite.isUserInteractionEnabled = false; graphite.isHidden = true
            canvas.addSubview(graphite)
            editingGesture.delegate = self
            editingGesture.onSamples = { [weak self] touches, state in self?.editSamples(touches, state: state) }
            hold.minimumPressDuration = 0.45; hold.allowableMovement = 0.75 / parent.scale; hold.delegate = self
            hold.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            history.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            history.onFirstTouch = { [weak self] in if self?.commit != nil { self?.finishStroke() } }
            history.onSwipeDown = { [weak self] point in self?.store.showClipboard(at: point) }
            history.onMultipleTouches = { [weak self] in self?.suppressStroke() }
            history.onFinish = { [weak self] count in
                guard let self else { return }
                if count == 2 { self.perform(.undo) } else if count == 3 { self.perform(.redo) }
                if self.store.eyedropperPoint == nil { self.suppressed = false; self.updateInput() }
            }
            pressure.delegate = self
            pressure.onSamples = { [weak self] samples, state in self?.drawPressureSamples(samples, state: state) }
            [editingGesture, hold, history, pressure].forEach { canvas.addGestureRecognizer($0) }
            subscription = store.canvasCommands.sink { [weak self] command in self?.perform(command) }
        }
        func detach() {
            finishStroke(); commit?.cancel(); subscription?.cancel()
            pencilInteraction.delegate = nil
            canvas?.removeInteraction(pencilInteraction)
        }
        func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
            handlePencilDoubleTap(action: UIPencilInteraction.preferredTapAction)
        }
        func handlePencilDoubleTap(action: UIPencilPreferredAction) {
            // Respect the system's Off/accessibility setting. Avoid interrupting
            // a contact in progress or changing tools during a canvas operation.
            guard action != .ignore, !usingTool, !suppressed,
                  !store.isFilling, !store.isSelectingPixels,
                  store.eyedropperPoint == nil, store.clipboardMenuPoint == nil else { return }
            finishStroke()
            store.setTool(store.tool == .draw ? .erase : .draw)
            updateInput()
            UISelectionFeedbackGenerator().selectionChanged()
            store.notify(store.tool == .erase ? "Eraser" : "Brush")
        }
        private var store: DeckStore { parent.store }
        func updateInput() {
            guard let canvas else { return }
            // Once a stroke moves beyond tiny touch jitter, the hold fails for
            // the rest of that touch instead of interrupting slow drawing.
            hold.allowableMovement = 0.75 / parent.scale
            history.scale = parent.scale
            let menuClosed = store.clipboardMenuPoint == nil
            setEnabled(hold, !store.isFilling && !store.isSelectingPixels && menuClosed)
            let drawing = menuClosed && store.tool == .draw && !suppressed && !store.isFilling && !store.isSelectingPixels && store.canEditActiveLayer
            if (store.activeImportedBrush != nil || usesGraphite) && (store.tool == .draw || store.tool == .erase) {
                setEnabled(canvas.drawingGestureRecognizer, false); setEnabled(editingGesture, false)
                pressure.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)] + (store.pencilOnly ? [] : [NSNumber(value: UITouch.TouchType.direct.rawValue)])
                setEnabled(pressure, menuClosed && !suppressed && !store.isFilling && !store.isSelectingPixels && store.canEditActiveLayer)
                return
            }
            let customPencil = !store.pressureCurve.isLinear || store.stabilization > 0 || store.brush == .flat
            let customFinger = store.brush == .flat && !store.pencilOnly
            let direct = NSNumber(value: UITouch.TouchType.direct.rawValue)
            let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
            // Mouse/finger input retains PencilKit's native velocity and brush dynamics.
            // A saved Pencil pressure curve must not replace those with fixed-force strokes.
            let nativeTypes = (store.pencilOnly || customFinger ? [] : [direct]) + (customPencil ? [] : [pencil])
            canvas.drawingGestureRecognizer.allowedTouchTypes = nativeTypes
            setEnabled(canvas.drawingGestureRecognizer, drawing && !nativeTypes.isEmpty)
            pressure.allowedTouchTypes = (customPencil ? [pencil] : []) + (customFinger ? [direct] : [])
            setEnabled(pressure, drawing && (customPencil || customFinger))
            setEnabled(editingGesture, menuClosed && store.tool != .draw && !suppressed && !store.isFilling && !store.isSelectingPixels)
        }
        private var usesGraphite: Bool { (store.tool == .erase ? store.eraserBrush : store.brush).usesGraphiteRenderer }
        private func setEnabled(_ recognizer: UIGestureRecognizer, _ enabled: Bool) {
            if recognizer.isEnabled != enabled { recognizer.isEnabled = enabled }
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer !== hold || (!suppressed && gestureRecognizer.numberOfTouches == 1)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            gestureRecognizer === hold || other === hold || gestureRecognizer === history || other === history
        }
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) { store.canvasInteraction.send(); usingTool = true; strokeBrush = store.brush; strokeLayerID = store.activeLayer.id; commit?.cancel(); commit = nil }
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) { usingTool = false; scheduleCommit() }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            if !usingTool && !suppressed && !canvasView.drawing.strokes.isEmpty { scheduleCommit() }
        }
        private func scheduleCommit() {
            guard !suppressed else { return }; commit?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.finishStroke() }
            commit = item; DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
        }
        func finishStroke() {
            commit?.cancel(); commit = nil
            if stamps.brush != nil && !suppressed { finishImportedStroke() }
            if graphite.raster != nil && !suppressed { finishGraphiteStroke() }
            guard let canvas, !suppressed, !canvas.drawing.strokes.isEmpty else { return }
            let drawing = canvas.drawing; canvas.drawing = PKDrawing()
            store.addDrawing(drawing, on: slideID, in: strokeLayerID, named: strokeBrush.title)
        }
        private func suppressStroke() {
            suppressed = true; commit?.cancel(); commit = nil; usingTool = false
            canvas?.drawingGestureRecognizer.isEnabled = false; pressure.isEnabled = false
            editingGesture.isEnabled = false
            editing.end(at: .zero, store: store, scale: parent.scale, cancelled: true)
            canvas?.drawing = PKDrawing(); pressurePoints = []; stamps.clear(); graphite.clear()
        }
        private func perform(_ command: CanvasCommand) {
            if !suppressed { finishStroke() }
            if command == .finishStroke { return }
            store.lassoPoints = []
            if command == .undo { store.undo() } else { store.redo() }
        }
        private func editSamples(_ touches: [UITouch], state: UIGestureRecognizer.State) {
            guard let canvas, !suppressed else { return }
            let point = touches.last?.location(in: canvas) ?? .zero
            if state == .began { store.canvasInteraction.send() }
            if store.tool == .eyedropper { pick(point, state: state); return }
            switch state {
            case .began: editing.begin(at: point, store: store, scale: parent.scale)
            case .changed:
                if store.tool == .transform { editing.change(to: point, store: store, scale: parent.scale) }
                else { for touch in touches { editing.change(to: touch.location(in: canvas), store: store, scale: parent.scale) } }
            case .ended, .cancelled: editing.end(at: point, store: store, scale: parent.scale, cancelled: state == .cancelled)
            default: break
            }
        }
        @objc private func held(_ gesture: UILongPressGestureRecognizer) {
            let point = gesture.location(in: canvas)
            if gesture.state == .began {
                returnTool = store.tool == .eyedropper ? .draw : store.tool
                // Cancel any provisional ink under the held finger before sampling.
                suppressStroke()
            }
            pick(point, state: gesture.state)
        }
        private func pick(_ point: CGPoint, state: UIGestureRecognizer.State) {
            if state == .began { snapshot = CanvasSnapshot.render(store: store); UISelectionFeedbackGenerator().selectionChanged() }
            if let snapshot, let color = CanvasSnapshot.color(in: snapshot, at: point, canvasSize: store.canvasSize) {
                store.sampledColor = color; store.eyedropperPoint = point
            }
            if state == .ended || state == .cancelled {
                if state == .ended { store.chooseColor(store.sampledColor); store.notify("Color picked") }
                store.eyedropperPoint = nil; snapshot = nil; suppressed = false
                if store.tool == .eyedropper { store.setTool(returnTool) }
                updateInput()
            }
        }
        private func drawImportedSamples(_ touches: [UITouch], state: UIGestureRecognizer.State) {
            guard let canvas else { return }
            if state == .cancelled { stamps.clear(); usingTool = false; return }
            if state == .began {
                finishStroke(); store.canvasInteraction.send(); usingTool = true; strokeLayerID = store.activeLayer.id; stabilizer.reset()
                guard let brush = store.activeImportedBrush, let image = ImportedBrushTip.image(brush, folder: store.importedBrushFolder, color: store.tool == .erase ? "FFFFFF" : store.ink) else { return }
                stampErasing = store.tool == .erase
                stamps.begin(brush: brush, tip: image, width: stampErasing ? store.eraserSize : store.brushSize, opacity: stampErasing ? store.eraserOpacity : store.opacity, color: stampErasing ? "FFFFFF" : store.ink, canvasSize: store.canvasSize)
                canvas.bringSubviewToFront(stamps)
            }
            for touch in touches {
                let pencil = touch.type == .pencil
                let force = pencil ? Double(touch.force / max(0.001, touch.maximumPossibleForce)) : 1
                guard let (point, pressure) = stabilizer.sample(touch.location(in: canvas), pressure: force, time: touch.timestamp, amount: pencil ? store.stabilization : 0) else { continue }
                stamps.add(point, pressure: store.pressureCurve.value(at: pressure), tilt: pencil ? touch.altitudeAngle : .pi / 2, azimuth: pencil ? touch.azimuthAngle(in: canvas) : 0)
            }
            if state == .ended { finishImportedStroke(); usingTool = false }
        }
        private func finishImportedStroke() {
            defer { stamps.clear() }
            guard let brush = stamps.brush, let (image, bounds) = stamps.result(), let layerID = strokeLayerID,
                  let index = store.deck.slides.firstIndex(where: { $0.id == slideID }),
                  let layer = store.deck.slides[index].layers?.first(where: { $0.id == layerID }), layer.visible, !layer.locked else { return }
            do {
                let filename = UUID().uuidString + ".png"
                guard let png = DrawingRasterizer.png(image) else { return }
                try png.write(to: store.mediaFolder.appendingPathComponent(filename), options: .atomic)
                store.checkpoint()
                store.deck.slides[index].elements.append(SlideElement(kind: stampErasing ? .erase : .ink, x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height, asset: filename, name: brush.name, layerID: layerID))
                store.save()
            } catch { store.errorMessage = error.localizedDescription }
        }
        private func drawGraphiteSamples(_ touches: [UITouch], state: UIGestureRecognizer.State) {
            guard let canvas else { return }
            if state == .cancelled { graphite.clear(); usingTool = false; return }
            if state == .began {
                finishStroke(); store.canvasInteraction.send(); usingTool = true; strokeLayerID = store.activeLayer.id
                graphiteErasing = store.tool == .erase
                strokeBrush = graphiteErasing ? store.eraserBrush : store.brush
                graphiteWidth = graphiteErasing ? store.eraserSize : store.brushSize
                graphiteOpacity = graphiteErasing ? store.eraserOpacity : store.opacity
                stabilizer.reset(); fingerPencil = FingerPencilDynamics()
                graphite.begin(brush: strokeBrush, color: graphiteErasing ? "FFFFFF" : store.ink, canvasSize: store.canvasSize)
                canvas.bringSubviewToFront(graphite)
            }
            for touch in touches {
                let pencil = touch.type == .pencil, location = touch.location(in: canvas)
                let force = pencil ? Double(touch.force / max(0.001, touch.maximumPossibleForce)) : fingerPencil.sample(location, time: touch.timestamp)
                guard let (point, filtered) = stabilizer.sample(location, pressure: force, time: touch.timestamp, amount: pencil ? store.stabilization : 0) else { continue }
                let pressure = pencil ? store.pressureCurve.value(at: filtered) : filtered
                graphite.add(GraphiteContact(point: point, width: graphiteWidth, pressure: pressure, altitude: pencil ? touch.altitudeAngle : .pi / 2, azimuth: pencil ? touch.azimuthAngle(in: canvas) : 0, opacity: graphiteOpacity))
            }
            if state == .ended { finishGraphiteStroke(); usingTool = false }
        }
        private func finishGraphiteStroke() {
            defer { graphite.clear() }
            graphite.raster?.finish()
            guard let (image, bounds) = graphite.raster?.snapshot(), let layerID = strokeLayerID,
                  let index = store.deck.slides.firstIndex(where: { $0.id == slideID }),
                  let layer = store.deck.slides[index].layers?.first(where: { $0.id == layerID }), layer.visible, !layer.locked else { return }
            do {
                let filename = UUID().uuidString + ".png"
                guard let png = DrawingRasterizer.png(image) else { return }
                try png.write(to: store.mediaFolder.appendingPathComponent(filename), options: .atomic)
                store.checkpoint()
                store.deck.slides[index].elements.append(SlideElement(kind: graphiteErasing ? .erase : .ink, x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height, asset: filename, name: strokeBrush.title + " stroke", layerID: layerID))
                store.save()
            } catch { store.errorMessage = error.localizedDescription }
        }
        private func drawPressureSamples(_ touches: [UITouch], state: UIGestureRecognizer.State) {
            guard let canvas, !suppressed else { return }
            if store.activeImportedBrush != nil || stamps.brush != nil { drawImportedSamples(touches, state: state); return }
            if usesGraphite || graphite.raster != nil { drawGraphiteSamples(touches, state: state); return }
            if state == .cancelled { canvas.drawing = PKDrawing(); pressurePoints = []; usingTool = false; return }
            if state == .began {
                store.canvasInteraction.send()
                finishStroke(); usingTool = true; pressurePoints = []; strokeStart = touches.first?.timestamp ?? 0; strokeBrush = store.brush
                strokeLayerID = store.activeLayer.id; strokeDate = Date(); liveStroke = nil; stabilizer.reset()
            }
            for touch in touches {
                let pencil = touch.type == .pencil
                let force = pencil ? Double(touch.force / max(0.001, touch.maximumPossibleForce)) : 1
                let altitude = pencil ? touch.altitudeAngle : .pi / 2
                guard let (location, filteredForce) = stabilizer.sample(touch.location(in: canvas), pressure: force, time: touch.timestamp, amount: pencil ? store.stabilization : 0) else { continue }
                let response = PencilResponse(pressure: filteredForce, altitude: altitude, brush: strokeBrush, width: store.brushSize, curve: store.pressureCurve)
                pressurePoints.append(PKStrokePoint(location: location, timeOffset: touch.timestamp - strokeStart, size: response.size, opacity: response.opacity, force: response.force, azimuth: pencil ? touch.azimuthAngle(in: canvas) : (strokeBrush == .flat ? -.pi / 6 : 0), altitude: altitude))
            }
            let ink = PKInk(strokeBrush.inkType, color: UIColor(Color(hex: store.ink)).withAlphaComponent(store.opacity))
            guard !pressurePoints.isEmpty else { return }
            let path = PKStrokePath(controlPoints: pressurePoints, creationDate: strokeDate)
            if liveStroke == nil { liveStroke = PKStroke(ink: ink, path: path, randomSeed: .random(in: 0...UInt32.max)) }
            else { liveStroke?.path = path }
            // Preserve the stroke's texture seed and creation date as it grows.
            // Generating a new stroke every frame makes textured brushes shimmer.
            UIView.performWithoutAnimation { canvas.drawing = PKDrawing(strokes: [liveStroke!]) }
            if state == .ended { usingTool = false; scheduleCommit() }
        }
    }
}
