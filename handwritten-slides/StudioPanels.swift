import SwiftUI
import PencilKit
import UniformTypeIdentifiers

struct BrushLibraryPanel: View {
    @ObservedObject var store: DeckStore
    var isEraser = false
    var onPressure: () -> Void
    @State private var category: BrushCategory = .sketching
    @State private var showingImported = false
    @State private var showBrushImport = false
    @State private var importing = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isEraser ? "Eraser Library" : "Brush Library").font(.system(size: 25, weight: .bold))
                Spacer()
                Button { showBrushImport = true } label: { Image(systemName: "plus").font(.title3) }.accessibilityLabel("Import Procreate brushes")
                Button(action: onPressure) { Image(systemName: "slider.horizontal.3").font(.title3) }.accessibilityLabel("Edit pressure curve")
            }.padding(24)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(BrushCategory.allCases) { item in
                        Button { category = item; showingImported = false } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.icon).frame(width: 20)
                                Text(item.rawValue).font(.system(size: 14))
                            }.padding(.vertical, 17).padding(.horizontal, 15)
                                .foregroundStyle(!showingImported && category == item ? .white : Color(white: 0.55))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(!showingImported && category == item ? .white.opacity(0.06) : .clear)
                        }
                    }
                    Button { showingImported = true } label: { Label("Imported", systemImage: "tray.and.arrow.down").font(.system(size: 14)).padding(15).foregroundStyle(showingImported ? .white : .gray) }
                    Spacer()
                    Text(isEraser ? "Erase on the active layer" : "Tilt Pencil to shade").font(.system(size: 11)).foregroundStyle(.gray).padding(16)
                }.frame(width: 155).background(.white.opacity(0.025))
                ScrollView {
                    VStack(spacing: 6) {
                        if showingImported {
                            if store.importedBrushes.isEmpty { Text("Import .brush or .brushset files using +").font(.callout).foregroundStyle(.secondary).padding() }
                            ForEach(store.importedBrushes) { brush in
                                Button { store.chooseImportedBrush(brush, eraser: isEraser) } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(brush.name).font(.system(size: 14, weight: .semibold))
                                        if let source = brush.source {
                                            Text(source.setName).font(.caption2).foregroundStyle(.secondary)
                                            if let note = source.note { Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                                        }
                                        if let tip = ImportedBrushTip.image(brush, folder: store.importedBrushFolder, color: "FFFFFF") { Image(uiImage: UIImage(cgImage: tip)).resizable().scaledToFit().frame(maxWidth: .infinity).frame(height: 58) }
                                    }.padding(13).frame(maxWidth: .infinity, alignment: .leading).background((isEraser ? store.importedEraserID : store.importedBrushID) == brush.id ? Color(hex: "3478F6") : Color(white: 0.115), in: RoundedRectangle(cornerRadius: 6))
                                }.accessibilityLabel(brush.name)
                            }
                            Text("Imported tips and pressure/tilt settings. Procreate dual-brush and wet mixing are not reproduced exactly.").font(.caption).foregroundStyle(.secondary).padding(8)
                        } else {
                        ForEach(StudioBrush.allCases.filter { $0.category == category }) { brush in
                            Button {
                                if isEraser { store.importedEraserID = nil; store.eraserBrush = brush; store.eraserSize = max(20, brush.defaultSize); store.setTool(.erase) }
                                else { store.importedBrushID = nil; store.brush = brush; store.brushSize = brush.defaultSize; store.setTool(.draw) }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(brush.title).font(.system(size: 14, weight: .semibold))
                                        Spacer()
                                        if brush.supportsTilt { Image(systemName: "pencil.tip.crop.circle").font(.caption) }
                                    }
                                    NativeBrushPreview(brush: brush).frame(height: 58)
                                }.padding(13).background((isEraser ? store.eraserBrush : store.brush) == brush ? Color(hex: "3478F6") : Color(white: 0.115), in: RoundedRectangle(cornerRadius: 6))
                            }.accessibilityLabel(brush.title).accessibilityAddTraits((isEraser ? store.eraserBrush : store.brush) == brush ? .isSelected : [])
                        }
                        }
                    }.padding(10)
                }.frame(width: 325)
            }.frame(height: 360)
            HStack {
                Text("Size \(Int(isEraser ? store.eraserSize : store.brushSize))").font(.caption)
                Slider(value: Binding(get: { isEraser ? store.eraserSize : store.brushSize }, set: { if isEraser { store.eraserSize = $0 } else { store.brushSize = $0 } }), in: 1...100).accessibilityLabel("Brush size in library")
            }.padding(18)
        }.frame(width: 480).background(Color(white: 0.145)).buttonStyle(.plain)
            .onAppear { category = (isEraser ? store.eraserBrush : store.brush).category; showingImported = (isEraser ? store.importedEraserID : store.importedBrushID) != nil }.preferredColorScheme(.dark)
            .overlay { if importing { ProgressView("Importing brushes…").padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)) } }
            .fileImporter(isPresented: $showBrushImport, allowedContentTypes: [UTType(filenameExtension: "brush") ?? .data, UTType(filenameExtension: "brushset") ?? .data]) { result in
                if case .success(let url) = result { importing = true; Task { await store.importBrushes(url); showingImported = true; importing = false } }
                else if case .failure(let error) = result { store.errorMessage = error.localizedDescription }
            }
    }
}

struct NativeBrushPreview: View {
    let brush: StudioBrush
    var body: some View {
        Image(uiImage: preview).resizable().scaledToFit().accessibilityHidden(true)
    }
    private var preview: UIImage {
        if brush.usesGraphiteRenderer {
            let raster = GraphiteStrokeRaster(brush: brush, color: "FFFFFF", seed: 42, size: CGSize(width: 340, height: 84))
            for i in 0...60 {
                let t = Double(i) / 60
                raster.add(GraphiteContact(point: CGPoint(x: 20 + t * 300, y: 42 + sin(t * .pi * 2) * 13), width: brush.defaultSize, pressure: 0.35 + 0.65 * sin(t * .pi), altitude: .pi / 2, azimuth: 0))
            }
            raster.finish()
            let format = UIGraphicsImageRendererFormat(); format.scale = 2
            return UIGraphicsImageRenderer(size: CGSize(width: 340, height: 84), format: format).image { _ in
                if let (image, bounds) = raster.snapshot() { UIImage(cgImage: image).draw(in: bounds) }
            }
        }
        let points = (0...60).map { i in
            let t = Double(i) / 60
            let width = brush.defaultSize * (0.35 + 0.65 * sin(t * .pi))
            return PKStrokePoint(location: CGPoint(x: 20 + t * 300, y: 42 + sin(t * .pi * 2) * 13), timeOffset: t, size: CGSize(width: width, height: brush == .flat ? width * 0.25 : width), opacity: 1, force: 0.8, azimuth: brush == .flat ? -.pi / 6 : 0, altitude: .pi / 2)
        }
        let drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(brush.inkType, color: .white), path: PKStrokePath(controlPoints: points, creationDate: .distantPast), randomSeed: 42)])
        var image = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent { image = drawing.image(from: CGRect(x: 0, y: 0, width: 340, height: 84), scale: 1) }
        return image
    }
}

struct ColorsPanel: View {
    @ObservedObject var store: DeckStore
    var body: some View {
        StudioColorPicker(colorHex: Binding(get: { store.pickerColor }, set: store.setPickerColor), recentColors: store.recentColors, onChoose: store.chooseColor)
            .onAppear { store.beginPickerColorEdit() }
            .onDisappear { store.chooseColor(store.pickerColor); store.endPickerColorEdit() }
    }
}

struct StudioColorPicker: View {
    @Binding var colorHex: String
    var title = "Colors"
    var showsQuickPalette = true
    var recentColors: [String]? = nil
    var onChoose: ((String) -> Void)? = nil
    @State private var tab = "Disc"
    @State private var hue = 0.0
    @State private var saturation = 0.0
    @State private var brightness = 0.0
    @State private var hex = ""
    private let colors = (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) }
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text(title).font(.system(size: 25, weight: .bold)); Spacer()
                RoundedRectangle(cornerRadius: 6).fill(Color(hex: colorHex)).frame(width: 58, height: 30).overlay(RoundedRectangle(cornerRadius: 6).stroke(.white.opacity(0.2)))
            }
            if tab == "Disc" {
                ZStack {
                    Circle().strokeBorder(AngularGradient(colors: colors, center: .center, startAngle: .degrees(0), endAngle: .degrees(360)), lineWidth: 28)
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            var angle = atan2(value.location.y - 142, value.location.x - 142) / (.pi * 2)
                            if angle < 0 { angle += 1 }; hue = angle; updateColor()
                        }).accessibilityLabel("Hue ring")
                        .accessibilityAdjustableAction { hue = (hue + ($0 == .increment ? 0.03 : 0.97)).truncatingRemainder(dividingBy: 1); updateColor() }
                    Circle().stroke(.white, lineWidth: 2).frame(width: 25, height: 25)
                        .position(x: 142 + cos(hue * .pi * 2) * 128, y: 142 + sin(hue * .pi * 2) * 128).allowsHitTesting(false)
                    saturationSquare(side: 170)
                }.frame(width: 284, height: 284)
            } else if tab == "Classic" {
                saturationSquare(side: 280)
                Slider(value: $hue, in: 0...1).tint(Color(hue: hue, saturation: 1, brightness: 1)).onChange(of: hue) { updateColor() }.accessibilityLabel("Hue")
            } else {
                palette("Essentials", colors: ["111111", "555555", "AAAAAA", "FFFFFF", "E63E37", "EC8451", "F1C34A", "6DB665", "4A9DCA", "545ECC", "986AB6", "C36D98"])
                palette("Earth", colors: StudioPalette.colors + ["453B35", "A7856A", "D4C4AC", "778979", "C8D4CD", "FAF4EA"])
            }
            if tab != "Palettes" {
                HStack {
                    Text("Hexadecimal").font(.caption).foregroundStyle(.gray); Spacer()
                    TextField("RGB", text: Binding(get: { hex }, set: { value in
                        hex = value
                        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                        if normalized.count == 6 && normalized.allSatisfy({ $0.isASCII && $0.isHexDigit }) { chooseColor(normalized.uppercased()); readColor() }
                    })).textInputAutocapitalization(.characters).autocorrectionDisabled().font(.system(.caption, design: .monospaced)).frame(width: 78).onSubmit {
                        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                        if value.count == 6 && UInt64(value, radix: 16) != nil { chooseColor(value.uppercased()); readColor() }
                    }.accessibilityLabel("Hex color")
                }
                if let recentColors { palette("History", colors: recentColors.isEmpty ? [colorHex, "FFFFFF"] : recentColors) }
                if showsQuickPalette { palette("Palette", colors: StudioPalette.colors + ["111111", "FFFFFF", "C74646", "547ECB", "A785BA", "C9BEA8"]) }
            }
            HStack {
                ForEach(["Disc", "Classic", "Palettes"], id: \.self) { name in
                    Button { tab = name } label: {
                        VStack(spacing: 6) { Image(systemName: name == "Disc" ? "circle" : name == "Classic" ? "slider.horizontal.3" : "square.grid.3x3.fill"); Text(name).font(.system(size: 10)) }
                            .foregroundStyle(tab == name ? Color(hex: "3C82F6") : .gray).frame(maxWidth: .infinity)
                    }.accessibilityLabel("\(name) colors")
                }
            }.padding(.top, 5)
        }.padding(22).frame(width: 330).background(Color(white: 0.145)).buttonStyle(.plain).onAppear { readColor() }.preferredColorScheme(.dark)
    }
    private func saturationSquare(side: Double) -> some View {
        ZStack {
            Rectangle().fill(Color(hue: hue, saturation: 1, brightness: 1))
            Rectangle().fill(LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing))
            Rectangle().fill(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
            Circle().stroke(.white, lineWidth: 2).background(Circle().stroke(.black.opacity(0.5), lineWidth: 4)).frame(width: 16, height: 16)
                .position(x: saturation * side, y: (1 - brightness) * side)
        }.frame(width: side, height: side).clipShape(RoundedRectangle(cornerRadius: 8))
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                saturation = min(1, max(0, value.location.x / side)); brightness = min(1, max(0, 1 - value.location.y / side)); updateColor()
            }).accessibilityLabel("Saturation and brightness")
    }
    private func palette(_ name: String, colors: [String]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.gray)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 6), spacing: 3) {
                ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                    Button { chooseColor(color); readColor() } label: { RoundedRectangle(cornerRadius: 3).fill(Color(hex: color)).frame(height: 28) }.accessibilityLabel("Color \(color)")
                }
            }
        }
    }
    private func chooseColor(_ value: String) { colorHex = value; onChoose?(value) }
    private func readColor() {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(Color(hex: colorHex)).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        hue = h; saturation = s; brightness = b; hex = colorHex
    }
    private func updateColor() { hex = Color(hue: hue, saturation: saturation, brightness: brightness).rgbHex; colorHex = hex }
}

struct StudioVerticalSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var label: String
    var bookmarks: [Double] = []
    var onInteraction: (() -> Void)? = nil
    @State private var latchedBookmark: Double?
    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let travel = height - 14
            let progress = min(1, max(0, (value - range.lowerBound) / (range.upperBound - range.lowerBound)))
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 5).fill(Color(white: 0.16)).overlay(RoundedRectangle(cornerRadius: 5).stroke(.black.opacity(0.35)))
                ForEach(bookmarks, id: \.self) { bookmark in
                    let fraction = (bookmark - range.lowerBound) / (range.upperBound - range.lowerBound)
                    Rectangle().fill(.white.opacity(0.8)).frame(height: 2).offset(y: (1 - fraction) * travel + 6)
                }
                RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.65)).frame(height: 14).offset(y: (1 - progress) * travel)
            }.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { event in
                onInteraction?()
                let ratio = min(1, max(0, 1 - (event.location.y - 7) / travel))
                let raw = range.lowerBound + ratio * (range.upperBound - range.lowerBound)
                func distanceToMark(_ mark: Double) -> Double { abs(mark - raw) / (range.upperBound - range.lowerBound) * travel }
                if let mark = latchedBookmark, bookmarks.contains(mark), distanceToMark(mark) <= 7 {
                    value = mark
                    return
                }
                latchedBookmark = nil
                if let nearest = bookmarks.min(by: { abs($0 - raw) < abs($1 - raw) }), distanceToMark(nearest) <= 5 {
                    if value != nearest { UISelectionFeedbackGenerator().selectionChanged() }
                    latchedBookmark = nearest
                    value = nearest
                } else if abs(event.translation.height) > 2 || abs(event.startLocation.y - ((1 - progress) * travel + 7)) > 9 {
                    // Tapping the thumb opens the preview without nudging its exact size.
                    value = onInteraction == nil ? raw : (raw * 10).rounded() / 10
                }
            }.onEnded { _ in latchedBookmark = nil })
        }.frame(width: 28, height: 132).accessibilityLabel(label).accessibilityValue(onInteraction == nil ? "\(Int(value))" : BrushSizeBookmarks.label(value))
            .accessibilityAdjustableAction {
                onInteraction?()
                value = min(range.upperBound, max(range.lowerBound, value + ($0 == .increment ? 1 : -1) * (range.upperBound - range.lowerBound) / 20))
            }
    }
}

struct SelectionOverlay: View {
    @ObservedObject var store: DeckStore
    @ObservedObject var preview: CanvasTransformPreview
    var scale: Double
    init(store: DeckStore, scale: Double) { self.store = store; self.scale = scale; self.preview = store.transformPreview }
    var body: some View {
        Canvas { context, _ in
            let blue = Color(hex: "3C82F6")
            if !store.lassoPoints.isEmpty {
                let points = Geometry.selectionPoints(store.lassoPoints, shape: store.selectionShape)
                let path = Geometry.path(points)
                context.fill(path, with: .color(blue.opacity(0.08)))
                context.stroke(path, with: .color(.white), lineWidth: 2 / scale)
                context.stroke(path, with: .color(.black), style: StrokeStyle(lineWidth: 1 / scale, dash: [5 / scale, 5 / scale]))
            }
            if let bounds = store.selectionBounds, store.tool == .select || store.tool == .transform {
                context.stroke(Path(bounds), with: .color(blue), style: StrokeStyle(lineWidth: 1 / scale, dash: [4 / scale, 3 / scale]))
                if store.tool == .transform {
                    var stem = Path(); stem.move(to: CGPoint(x: bounds.midX, y: bounds.minY)); stem.addLine(to: CGPoint(x: bounds.midX, y: bounds.minY - 35 / scale))
                    context.stroke(stem, with: .color(blue), lineWidth: 1 / scale)
                    for p in (store.selectedText == nil ? Geometry.handles(bounds) : [Geometry.handles(bounds)[3], Geometry.handles(bounds)[7]]) + [CGPoint(x: bounds.midX, y: bounds.minY - 35 / scale)] {
                        let circle = Path(ellipseIn: CGRect(x: p.x - 5 / scale, y: p.y - 5 / scale, width: 10 / scale, height: 10 / scale))
                        context.fill(circle, with: .color(.white)); context.stroke(circle, with: .color(blue), lineWidth: 1.5 / scale)
                    }
                }
            }
            if let point = store.eyedropperPoint {
                let ring = Path(ellipseIn: CGRect(x: point.x - 38 / scale, y: point.y - 90 / scale, width: 76 / scale, height: 76 / scale))
                context.fill(ring, with: .color(Color(hex: store.sampledColor)))
                context.stroke(ring, with: .color(.white), lineWidth: 4 / scale)
                context.stroke(Path(ellipseIn: CGRect(x: point.x - 5 / scale, y: point.y - 5 / scale, width: 10 / scale, height: 10 / scale)), with: .color(.black), lineWidth: 1 / scale)
            }
        }.allowsHitTesting(false)
    }
}
