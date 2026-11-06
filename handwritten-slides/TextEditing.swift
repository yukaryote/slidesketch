import SwiftUI
import Combine

struct TextEditorRequest: Identifiable { let id = UUID(); var element: SlideElement? }

extension DeckStore {
    var selectedTextElements: [SlideElement] {
        guard tool == .select || tool == .transform else { return [] }
        return editableElements.filter { selectedIDs.contains($0.id) && $0.kind == .text }
    }
    var pickerColor: String { selectedTextElements.first?.color ?? ink }
    func beginPickerColorEdit() { colorEditIDs = []; colorEditCheckpointed = false }
    func endPickerColorEdit() { colorEditIDs = []; colorEditCheckpointed = false }
    func setPickerColor(_ hex: String) {
        ink = hex
        let texts = selectedTextElements, ids = Set(texts.map(\.id))
        guard texts.contains(where: { $0.color != hex }) else { return }
        if colorEditIDs != ids { colorEditIDs = ids; colorEditCheckpointed = false }
        if !colorEditCheckpointed { checkpoint(); colorEditCheckpointed = true }
        for var text in texts { text.color = hex; update(text) }
        save()
    }
    func requestTextEdit(_ id: UUID) {
        guard selectedIDs == [id], let text = editableElements.first(where: { $0.id == id }), text.kind == .text else { return }
        textEditRequests.send(id)
    }
    func saveText(_ value: String, font: String, size: Double, color: String, editing id: UUID?) {
        let original = id.flatMap { id in editableElements.first { $0.id == id && $0.kind == .text } }
        guard id == nil || original != nil else { return }
        let width = original?.width ?? min(1100, canvasSize.width * 0.75)
        let uiFont = UIFont(name: font, size: size) ?? UIFont.systemFont(ofSize: size)
        let rect = (value as NSString).boundingRect(with: CGSize(width: width, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: uiFont], context: nil)
        var text = original ?? SlideElement.text(value, x: (canvasSize.width - width) / 2, y: canvasSize.height / 2, width: width, size: size)
        text.text = value; text.font = font; text.fontSize = size; text.color = color
        text.height = max(size * 1.2, rect.height + 12)
        if original == nil { text.y = max(0, (canvasSize.height - text.height) / 2) }
        if original != nil { checkpoint(); update(text); save() } else { add(text) }
    }
}

@MainActor
extension SlideElement {
    var fittedTextHeight: Double {
        let uiFont = UIFont(name: font, size: fontSize) ?? UIFont.systemFont(ofSize: fontSize)
        let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: 10000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: uiFont], context: nil)
        return max(fontSize * 1.2, ceil(rect.height) + 12)
    }
}

extension DeckStore {
    var selectedText: SlideElement? { selectedIDs.count == 1 ? selectedTextElements.first : nil }
    func changeTextStyle(_ id: UUID, font: String? = nil, size: Double? = nil) {
        guard var text = editableElements.first(where: { $0.id == id && $0.kind == .text }) else { return }
        let newFont = font ?? text.font, newSize = min(240, max(8, size ?? text.fontSize))
        guard text.font != newFont || text.fontSize != newSize else { return }
        checkpoint(); text.font = newFont; text.fontSize = newSize; text.height = text.fittedTextHeight
        update(text); save()
    }
}

struct TextOptionsBar: View {
    @ObservedObject var store: DeckStore
    let element: SlideElement
    var body: some View {
        HStack(spacing: 24) {
            Image(systemName: "textformat").foregroundStyle(.gray)
            Menu {
                Button("Serif") { store.changeTextStyle(element.id, font: "Georgia") }
                Button("Sans") { store.changeTextStyle(element.id, font: "AvenirNext-Regular") }
                Button("Handwritten") { store.changeTextStyle(element.id, font: "Noteworthy-Light") }
            } label: { Text(element.font == "Georgia" ? "Serif" : element.font == "Noteworthy-Light" ? "Handwritten" : "Sans") }.accessibilityLabel("Text typeface")
            Menu {
                ForEach([8, 12, 16, 20, 24, 32, 40, 48, 56, 64, 72, 96, 120, 144, 180, 240], id: \.self) { size in
                    Button("\(size) pt") { store.changeTextStyle(element.id, size: Double(size)) }
                }
            } label: { Text("\(element.fontSize.formatted(.number.precision(.fractionLength(0...1)))) pt") }.accessibilityLabel("Text font size")
            Button { store.requestTextEdit(element.id) } label: { Label("Edit text", systemImage: "pencil") }
        }.font(.system(size: 12, weight: .medium)).buttonStyle(.plain).padding(.horizontal, 20).frame(height: 46)
            .background(Color(white: 0.09).opacity(0.97), in: RoundedRectangle(cornerRadius: 8))
    }
}
