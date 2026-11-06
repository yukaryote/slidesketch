import SwiftUI
import AVKit
import PhotosUI
import UniformTypeIdentifiers

nonisolated struct VideoOptions: Codable, Equatable, Sendable {
    var speed: Double = 1
    var autoplay = false
    var loop = false
    var muted = false
}

struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: url)
            return PickedMovie(url: url)
        }
    }
}

extension DeckStore {
    func toggleVideoPlayback(_ id: UUID) {
        guard selectedIDs == [id], editableElements.contains(where: { $0.id == id && $0.kind == .video }) else { return }
        if editorVideoID == id { editorVideoPaused.toggle() }
        else { editorVideoID = id; editorVideoPaused = false }
    }
    func tappedSelectedElement(_ id: UUID) {
        guard let element = editableElements.first(where: { $0.id == id }), selectedIDs == [id] else { return }
        if element.kind == .text { requestTextEdit(id) }
        else if element.kind == .video { toggleVideoPlayback(id) }
    }
    func changeVideoOptions(_ id: UUID, _ change: (inout VideoOptions) -> Void) {
        guard var element = editableElements.first(where: { $0.id == id && $0.kind == .video }) else { return }
        let original = element.videoOptions ?? VideoOptions()
        var options = original; change(&options)
        options.speed = min(2, max(0.25, options.speed))
        guard options != original else { return }
        checkpoint(); element.videoOptions = options; update(element); save()
    }
}

struct VideoOptionsBar: View {
    @ObservedObject var store: DeckStore
    let element: SlideElement
    private var options: VideoOptions { element.videoOptions ?? VideoOptions() }
    var body: some View {
        HStack(spacing: 22) {
            Button { store.toggleVideoPlayback(element.id) } label: {
                let playing = store.editorVideoID == element.id && !store.editorVideoPaused
                Label(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill")
            }.accessibilityLabel(store.editorVideoID == element.id && !store.editorVideoPaused ? "Pause video on canvas" : "Play video on canvas")
            Menu {
                ForEach([0.25, 0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { rate in
                    Button { store.changeVideoOptions(element.id) { $0.speed = rate } } label: {
                        Label("\(rate.formatted())×", systemImage: rate == options.speed ? "checkmark" : "speedometer")
                    }
                }
            } label: { Label("\(options.speed.formatted())×", systemImage: "speedometer") }.accessibilityLabel("Video playback speed")
            Menu {
                Button("Start on click", systemImage: options.autoplay ? "cursorarrow.click" : "checkmark") { store.changeVideoOptions(element.id) { $0.autoplay = false } }
                Button("Start with slide", systemImage: options.autoplay ? "checkmark" : "play.rectangle") { store.changeVideoOptions(element.id) { $0.autoplay = true } }
            } label: { Label(options.autoplay ? "With slide" : "On click", systemImage: options.autoplay ? "play.rectangle" : "cursorarrow.click") }.accessibilityLabel("Video start: \(options.autoplay ? "With slide" : "On click")")
            Button { store.changeVideoOptions(element.id) { $0.loop.toggle() } } label: {
                Label("Loop", systemImage: "repeat").foregroundStyle(options.loop ? Color(hex: "3C82F6") : Color(white: 0.78))
            }.accessibilityLabel("Loop video").accessibilityValue(options.loop ? "On" : "Off")
            Button { store.changeVideoOptions(element.id) { $0.muted.toggle() } } label: {
                Label(options.muted ? "Muted" : "Sound", systemImage: options.muted ? "speaker.slash" : "speaker.wave.2")
            }.accessibilityLabel("Video audio").accessibilityValue(options.muted ? "Muted" : "On")
        }.font(.system(size: 12, weight: .medium)).buttonStyle(.plain).padding(.horizontal, 20).frame(height: 46)
            .background(Color(white: 0.09).opacity(0.97), in: RoundedRectangle(cornerRadius: 8))
    }
}
