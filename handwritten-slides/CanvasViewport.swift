import SwiftUI
import UIKit
import Combine

@MainActor
final class CanvasViewportState: ObservableObject {
    @Published var scale: CGFloat = 0.5
    @Published var canvasRect: CGRect = .zero
    @Published var command: Command?
    enum Command { case fit, zoomIn, zoomOut }
}

enum CanvasViewportGeometry {
    static func fit(_ size: CGSize, canvasSize: CGSize = PresentationDimensions.standard.size) -> CGFloat { max(0.01, min((size.width - 132) / canvasSize.width, (size.height - 60) / canvasSize.height)) }
    static func canvasPoint(_ point: CGPoint, in rect: CGRect, canvasSize: CGSize = PresentationDimensions.standard.size) -> CGPoint {
        CGPoint(x: (point.x - rect.minX) / max(0.001, rect.width) * canvasSize.width, y: (point.y - rect.minY) / max(0.001, rect.height) * canvasSize.height)
    }
}

final class CanvasScrollView: UIScrollView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
}

struct CanvasViewport<Content: View>: UIViewRepresentable {
    @ObservedObject var state: CanvasViewportState
    var content: Content
    var canvasSize: CGSize = PresentationDimensions.standard.size
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> CanvasScrollView {
        let scroll = CanvasScrollView()
        scroll.backgroundColor = .clear; scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.panGestureRecognizer.minimumNumberOfTouches = 2
        scroll.panGestureRecognizer.maximumNumberOfTouches = 2
        scroll.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scroll.pinchGestureRecognizer?.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scroll.delaysContentTouches = false; scroll.bouncesZoom = false
        scroll.delegate = context.coordinator
        let host = context.coordinator.host
        host.view.backgroundColor = .clear
        host.view.frame = CGRect(origin: .zero, size: canvasSize)
        scroll.addSubview(host.view); scroll.contentSize = host.view.bounds.size
        scroll.onLayout = { [weak coordinator = context.coordinator, weak scroll] in if let scroll { coordinator?.layout(scroll) } }
        return scroll
    }
    func updateUIView(_ scroll: CanvasScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.host.rootView = content
        if let command = state.command {
            DispatchQueue.main.async { state.command = nil }
            let fit = CanvasViewportGeometry.fit(scroll.bounds.size, canvasSize: canvasSize)
            let zoom: CGFloat = command == .fit ? fit : min(scroll.maximumZoomScale, max(scroll.minimumZoomScale, scroll.zoomScale * (command == .zoomIn ? 1.4 : 1 / 1.4)))
            let center = CGPoint(x: (scroll.bounds.midX - context.coordinator.host.view.frame.minX) / scroll.zoomScale, y: (scroll.bounds.midY - context.coordinator.host.view.frame.minY) / scroll.zoomScale)
            scroll.zoom(to: CGRect(x: center.x - scroll.bounds.width / zoom / 2, y: center.y - scroll.bounds.height / zoom / 2, width: scroll.bounds.width / zoom, height: scroll.bounds.height / zoom), animated: true)
        }
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: CanvasViewport
        let host: UIHostingController<Content>
        var lastSize = CGSize.zero
        var layingOut = false
        init(_ parent: CanvasViewport) { self.parent = parent; host = UIHostingController(rootView: parent.content) }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { host.view }
        func layout(_ scroll: UIScrollView) {
            guard !layingOut, scroll.bounds.width > 0, scroll.bounds.height > 0 else { return }
            layingOut = true; defer { layingOut = false }
            if lastSize != scroll.bounds.size {
                let oldFit = CanvasViewportGeometry.fit(lastSize, canvasSize: parent.canvasSize), newFit = CanvasViewportGeometry.fit(scroll.bounds.size, canvasSize: parent.canvasSize)
                let relative = lastSize == .zero ? 1 : scroll.zoomScale / oldFit
                lastSize = scroll.bounds.size
                scroll.minimumZoomScale = newFit * 0.4; scroll.maximumZoomScale = newFit * 8
                scroll.zoomScale = min(scroll.maximumZoomScale, max(scroll.minimumZoomScale, relative * newFit))
            }
            let horizontal = max(0, (scroll.bounds.width - parent.canvasSize.width * scroll.zoomScale) / 2)
            let vertical = max(0, (scroll.bounds.height - parent.canvasSize.height * scroll.zoomScale) / 2)
            let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
            if scroll.contentInset != inset { scroll.contentInset = inset }
            publish(scroll)
        }
        func publish(_ scroll: UIScrollView) {
            let rect = host.view.convert(host.view.bounds, to: scroll).offsetBy(dx: -scroll.bounds.minX, dy: -scroll.bounds.minY)
            let scale = scroll.zoomScale
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.parent.state.scale != scale { self.parent.state.scale = scale }
                if self.parent.state.canvasRect != rect { self.parent.state.canvasRect = rect }
            }
        }
        func invalidateHistory(_ view: UIView) {
            view.gestureRecognizers?.compactMap { $0 as? HistoryTapGesture }.forEach { $0.invalidateTap() }
            view.subviews.forEach(invalidateHistory)
        }
        func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { invalidateHistory(host.view) }
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { invalidateHistory(host.view) }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { layout(scrollView) }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { publish(scrollView) }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { layout(scrollView) }
    }
}

extension DeckStore {
    func reorderSlide(_ id: UUID, relativeTo target: UUID, after: Bool) {
        guard id != target, let sourceIndex = deck.slides.firstIndex(where: { $0.id == id }), deck.slides.contains(where: { $0.id == target }) else { return }
        let selectedID = slide.id
        var ordered = deck.slides
        let item = ordered.remove(at: sourceIndex)
        let destination = ordered.firstIndex { $0.id == target }! + (after ? 1 : 0)
        ordered.insert(item, at: destination)
        guard ordered.map(\.id) != deck.slides.map(\.id) else { return }
        checkpoint(); deck.slides = ordered
        active = ordered.firstIndex { $0.id == selectedID }!; save()
    }
}

struct SlideReorderDrop: DropDelegate {
    let store: DeckStore
    let target: UUID
    @Binding var dragged: UUID?
    @Binding var highlighted: UUID?
    func validateDrop(info: DropInfo) -> Bool { dragged != nil && dragged != target }
    func dropEntered(info: DropInfo) { highlighted = target }
    func dropExited(info: DropInfo) { if highlighted == target { highlighted = nil } }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard let id = dragged else { return false }
        withAnimation(.easeInOut(duration: 0.18)) { store.reorderSlide(id, relativeTo: target, after: info.location.x > 53) }
        dragged = nil; highlighted = nil; return true
    }
}
