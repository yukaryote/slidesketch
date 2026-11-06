import SwiftUI

struct LayerSwipeActions: ViewModifier {
    let store: DeckStore
    let layer: StudioLayer
    @Binding var openLayer: UUID?
    @GestureState private var translation: CGFloat = 0
    private var offset: CGFloat { max(-228, min(0, (openLayer == layer.id ? -228 : 0) + translation)) }
    func body(content: Content) -> some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 0) {
                action(layer.locked ? "Unlock" : "Lock", icon: layer.locked ? "lock.open" : "lock", color: Color(white: 0.28)) { store.changeLayer(layer) { $0.locked.toggle() } }
                action("Duplicate", icon: "plus.square.on.square", color: Color(white: 0.38)) { store.duplicateDrawingLayer(layer) }
                action("Delete", icon: "trash", color: .red) { store.deleteDrawingLayer(layer) }.disabled(store.layers.count == 1)
            }.frame(width: 228)
            content.offset(x: offset)
        }.clipShape(RoundedRectangle(cornerRadius: 7))
            .simultaneousGesture(DragGesture(minimumDistance: 22)
                .updating($translation) { value, state, _ in
                    guard value.startLocation.y < 66, abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                    state = value.translation.width
                }
                .onEnded { value in
                    guard value.startLocation.y < 66, abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                    withAnimation(.easeOut(duration: 0.18)) { openLayer = value.translation.width < -35 ? layer.id : nil }
                })
            .accessibilityAction(named: layer.locked ? "Unlock layer" : "Lock layer") { store.changeLayer(layer) { $0.locked.toggle() } }
            .accessibilityAction(named: "Duplicate layer") { store.duplicateDrawingLayer(layer) }
            .accessibilityAction(named: "Delete layer") { store.deleteDrawingLayer(layer) }
    }
    private func action(_ title: String, icon: String, color: Color, perform: @escaping () -> Void) -> some View {
        Button { withAnimation(.easeOut(duration: 0.18)) { openLayer = nil }; perform() } label: {
            VStack(spacing: 6) { Image(systemName: icon); Text(title).font(.system(size: 10, weight: .medium)) }
                .foregroundStyle(.white).frame(width: 76).frame(maxHeight: .infinity).background(color)
        }.accessibilityLabel("\(title) \(layer.name)")
    }
}

struct LayerReorderDrop: DropDelegate {
    let store: DeckStore
    let target: UUID
    @Binding var dragged: UUID?
    func validateDrop(info: DropInfo) -> Bool { dragged != nil && dragged != target }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool {
        guard let id = dragged, let source = store.layers.firstIndex(where: { $0.id == id }), let destination = store.layers.firstIndex(where: { $0.id == target }) else { return false }
        store.checkpoint()
        var layers = store.layers
        let item = layers.remove(at: source); layers.insert(item, at: destination)
        store.deck.slides[store.active].layers = layers; store.save(); dragged = nil
        return true
    }
}
