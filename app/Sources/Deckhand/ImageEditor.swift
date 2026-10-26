// ImageEditor.swift — crop / resize / rotate before a graphic is written to a key.
//
// The square viewport is the crop: the image is aspect-filled into it, then scaled (resize) and
// dragged (reposition). Preview and final render share one pipeline, so what the sheet shows is
// exactly the 85×85 (or 80×80) JPEG that goes to the panel.
import SwiftUI
import AppKit

struct ImageEdit: Equatable {
    var quarterTurns: Int = 0        // clockwise quarter turns, 0...3
    var zoom: CGFloat = 1.0          // 1 = aspect fill
    var offset: CGSize = .zero       // in final-pixel space
}

enum ImageRenderer {
    /// Rotate by quarter turns clockwise; the canvas expands like PIL's `rotate(-90, expand=True)`.
    static func rotated(_ image: CGImage, quarterTurns: Int) -> CGImage {
        var result = image
        let turns = ((quarterTurns % 4) + 4) % 4
        for _ in 0..<turns { result = rotate90CW(result) }
        return result
    }

    static func rotate90CW(_ image: CGImage) -> CGImage {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: h, height: w,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(w))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    /// Aspect-fill the (already rotated) image into a square, applying zoom and offset.
    static func compose(_ image: CGImage, edit: ImageEdit, side: Int) -> CGImage? {
        let rotated = rotated(image, quarterTurns: edit.quarterTurns)
        let w = CGFloat(rotated.width), h = CGFloat(rotated.height)
        guard w > 0, h > 0 else { return nil }
        let sideF = CGFloat(side)
        let base = max(sideF / w, sideF / h)              // fill, never letterbox
        let scale = base * max(0.2, edit.zoom)

        guard let ctx = CGContext(data: nil, width: side, height: side,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: sideF / 2 + edit.offset.width, y: sideF / 2 - edit.offset.height)
        ctx.scaleBy(x: scale, y: scale)
        ctx.draw(rotated, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return ctx.makeImage()
    }
}

struct ImageEditorSheet: View {
    let source: CGImage
    let slot: Int
    let onCancel: () -> Void
    let onApply: (CGImage) -> Void

    @State private var edit = ImageEdit()
    @State private var dragStart: CGSize = .zero

    private let preview: CGFloat = 260

    private var targetSide: Int { ImagePrep.size(for: slot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Adjust Graphic").font(.headline)
                Text("Drag to reposition · the square is the crop · \(targetSide)×\(targetSide) on the key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 20) {
                previewPane
                controls
                    .frame(width: 190, alignment: .leading)
            }

            Divider()
            HStack {
                Button("Reset") { edit = ImageEdit() }
                    .disabled(edit == ImageEdit())
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Use Image") {
                    if let composed = ImageRenderer.compose(source, edit: scaledEdit, side: targetSide) {
                        onApply(composed)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    // offsets are stored in final-pixel space; the preview is a different size, so scale them
    private var scaledEdit: ImageEdit {
        var e = edit
        let factor = CGFloat(targetSide) / preview
        e.offset = CGSize(width: edit.offset.width * factor, height: edit.offset.height * factor)
        return e
    }

    private var previewPane: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))

            if let composed = ImageRenderer.compose(source, edit: edit, side: Int(preview)) {
                Image(decorative: composed, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: preview, height: preview)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            // rule-of-thirds guides, only while interacting
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 1)
                .frame(width: preview, height: preview)
        }
        .frame(width: preview, height: preview)
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    edit.offset = CGSize(width: dragStart.width + value.translation.width,
                                         height: dragStart.height + value.translation.height)
                }
                .onEnded { _ in dragStart = edit.offset }
        )
        .accessibilityLabel("Graphic preview, drag to reposition")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Rotate") {
                HStack(spacing: 6) {
                    Button {
                        edit.quarterTurns = (edit.quarterTurns + 3) % 4
                        edit.offset = .zero
                    } label: {
                        Label("Left", systemImage: "rotate.left")
                    }
                    .help("Rotate 90° left")

                    Button {
                        edit.quarterTurns = (edit.quarterTurns + 1) % 4
                        edit.offset = .zero
                    } label: {
                        Label("Right", systemImage: "rotate.right")
                    }
                    .help("Rotate 90° right")
                }
                .buttonStyle(.bordered)
            }

            GroupBox("Resize") {
                VStack(alignment: .leading, spacing: 6) {
                    Slider(value: $edit.zoom, in: 1.0...3.0) {
                        Text("Zoom")
                    } minimumValueLabel: {
                        Image(systemName: "minus.magnifyingglass")
                    } maximumValueLabel: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .onChange(of: edit.zoom) { _, _ in }
                    Text(String(format: "%.0f%%", edit.zoom * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("Reset to fill") { edit.zoom = 1.0; edit.offset = .zero }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Back to 100% zoom, centred")
                }
            }

            GroupBox("Position") {
                VStack(spacing: 4) {
                    Button { nudge(dx: 0, dy: 10) } label: { Image(systemName: "arrow.up") }
                    HStack(spacing: 4) {
                        Button { nudge(dx: 10, dy: 0) } label: { Image(systemName: "arrow.left") }
                        Button { nudge(dx: -10, dy: 0) } label: { Image(systemName: "arrow.right") }
                    }
                    Button { nudge(dx: 0, dy: -10) } label: { Image(systemName: "arrow.down") }
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        edit.offset = CGSize(width: edit.offset.width + dx, height: edit.offset.height + dy)
        dragStart = edit.offset
    }
}
