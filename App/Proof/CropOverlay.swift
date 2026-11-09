import ProofKit
import SwiftUI

/// The crop rectangle drawn over the photo while the crop tool is open: the area outside it
/// faded toward the canvas, a border with handles, and a grid while something is being dragged.
/// It lays out the same way `RAWRenderer.draw` does: the turned photo fitted to the view as if
/// upright, then tilted around its center by the straighten angle.
struct CropOverlay: View {
    let library: Library
    let frame: CropFrame
    let aspect: AspectRatio?
    let backdropGray: Double

    /// The rectangle when the current drag started; `nil` between drags.
    @State private var dragStart: CropFrame?

    var body: some View {
        GeometryReader { proxy in
            let layout = Layout(frame: frame, viewSize: proxy.size)
            ZStack {
                Canvas { context, size in
                    draw(in: &context, size: size, box: layout.box)
                }
                .allowsHitTesting(false)
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: max(layout.box.width - 2 * Self.handleReach, 0),
                           height: max(layout.box.height - 2 * Self.handleReach, 0))
                    .position(x: layout.box.midX, y: layout.box.midY)
                    .pointerStyle(dragStart == nil ? .grabIdle : .grabActive)
                    .gesture(drag(layout: layout) { start, delta in start.moved(by: delta) })
                    .accessibilityHidden(true)
                ForEach(CropHandle.allCases, id: \.self) { handle in
                    let area = layout.hitArea(of: handle, reach: Self.handleReach)
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: area.width, height: area.height)
                        .position(x: area.midX, y: area.midY)
                        .pointerStyle(.frameResize(position: handle.resizePosition))
                        .gesture(drag(layout: layout) { start, delta in start.dragging(handle, by: delta, aspect: aspect) })
                        .accessibilityHidden(true)
                }
            }
        }
    }

    /// How far from the border a drag still takes a handle, in points.
    private static let handleReach = 12.0

    private func drag(layout: Layout, change: @escaping (CropFrame, CGVector) -> CropFrame) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? frame
                if dragStart == nil {
                    dragStart = start
                    library.isAdjusting = true
                }
                // The rectangle stays upright on screen, so a drag is already along its edges.
                let delta = CGVector(dx: value.translation.width / layout.scale, dy: value.translation.height / layout.scale)
                library.setCropFrame(change(start, delta))
            }
            .onEnded { _ in
                dragStart = nil
                library.isAdjusting = false
            }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, box: CGRect) {
        // Fades the photo outside the rectangle toward the canvas, in either appearance.
        var outside = Path(CGRect(origin: .zero, size: size))
        outside.addRect(box)
        context.fill(outside, with: .color(Color(white: backdropGray).opacity(0.7)), style: FillStyle(eoFill: true))

        let line = Color.white
        var shadowed = context
        shadowed.addFilter(.shadow(color: .black.opacity(0.45), radius: 1))

        let divisions = library.isStraightening ? 8 : dragStart != nil ? 3 : 0
        if divisions > 0 {
            var grid = Path()
            for index in 1..<divisions {
                let x = box.minX + box.width * Double(index) / Double(divisions)
                let y = box.minY + box.height * Double(index) / Double(divisions)
                grid.move(to: CGPoint(x: x, y: box.minY)); grid.addLine(to: CGPoint(x: x, y: box.maxY))
                grid.move(to: CGPoint(x: box.minX, y: y)); grid.addLine(to: CGPoint(x: box.maxX, y: y))
            }
            shadowed.stroke(grid, with: .color(line.opacity(0.6)), lineWidth: 0.5)
        }

        shadowed.stroke(Path(box), with: .color(line), lineWidth: 1)

        // Corner brackets and short bars at the middle of each edge.
        let length = min(20, box.width / 3, box.height / 3)
        var handles = Path()
        let inset = 1.5
        let (left, right, top, bottom) = (box.minX + inset, box.maxX - inset, box.minY + inset, box.maxY - inset)
        for (x, y, dx, dy) in [(left, top, 1.0, 1.0), (right, top, -1.0, 1.0), (right, bottom, -1.0, -1.0), (left, bottom, 1.0, -1.0)] {
            handles.move(to: CGPoint(x: x + dx * length, y: y))
            handles.addLine(to: CGPoint(x: x, y: y))
            handles.addLine(to: CGPoint(x: x, y: y + dy * length))
        }
        handles.move(to: CGPoint(x: box.midX - length / 2, y: top)); handles.addLine(to: CGPoint(x: box.midX + length / 2, y: top))
        handles.move(to: CGPoint(x: box.midX - length / 2, y: bottom)); handles.addLine(to: CGPoint(x: box.midX + length / 2, y: bottom))
        handles.move(to: CGPoint(x: left, y: box.midY - length / 2)); handles.addLine(to: CGPoint(x: left, y: box.midY + length / 2))
        handles.move(to: CGPoint(x: right, y: box.midY - length / 2)); handles.addLine(to: CGPoint(x: right, y: box.midY + length / 2))
        shadowed.stroke(handles, with: .color(line), style: StrokeStyle(lineWidth: 3, lineCap: .square))
    }

    /// Where the rectangle sits in the view.
    struct Layout {
        let scale: Double
        let box: CGRect

        init(frame: CropFrame, viewSize: CGSize) {
            let image = frame.imageSize
            scale = image.width > 0 && image.height > 0
                ? min(viewSize.width / image.width, viewSize.height / image.height) : 1
            // The photo turns around its own center; the rectangle's center turns with it.
            let radians = frame.angle * .pi / 180
            let dx = frame.center.x - image.width / 2, dy = frame.center.y - image.height / 2
            let center = CGPoint(x: viewSize.width / 2 + scale * (dx * cos(radians) - dy * sin(radians)),
                                 y: viewSize.height / 2 + scale * (dx * sin(radians) + dy * cos(radians)))
            let size = CGSize(width: frame.size.width * scale, height: frame.size.height * scale)
            box = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        }

        /// The area that picks up `handle`: a square at a corner, the rest of the edge between.
        func hitArea(of handle: CropHandle, reach: Double) -> CGRect {
            let x: (Double, Double) = switch handle.horizontal {
            case -1: (box.minX - reach, box.minX + reach)
            case 1: (box.maxX - reach, box.maxX + reach)
            default: (box.minX + reach, box.maxX - reach)
            }
            let y: (Double, Double) = switch handle.vertical {
            case -1: (box.minY - reach, box.minY + reach)
            case 1: (box.maxY - reach, box.maxY + reach)
            default: (box.minY + reach, box.maxY - reach)
            }
            return CGRect(x: x.0, y: y.0, width: max(x.1 - x.0, 0), height: max(y.1 - y.0, 0))
        }
    }
}

private extension CropHandle {
    var resizePosition: FrameResizePosition {
        switch self {
        case .topLeft: .topLeading
        case .top: .top
        case .topRight: .topTrailing
        case .right: .trailing
        case .bottomRight: .bottomTrailing
        case .bottom: .bottom
        case .bottomLeft: .bottomLeading
        case .left: .leading
        }
    }
}
