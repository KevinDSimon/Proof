import ProofKit
import SwiftUI

/// The tone curve: a channel picker over a square graph of the chosen channel's curve, with the
/// photo's histogram behind it. Clicking adds a point on the curve and dragging moves it;
/// dragging a point off the graph, or pressing Delete, removes it. The end points can't be
/// removed, and moving them sets the black and white points. Arrow keys nudge the selected point.
///
/// The red, green and blue curves are drawn in the histogram's colors, so like the histogram
/// they are an exception to the inspector's gray.
struct CurveEditor: View {
    let library: Library
    @State private var channel: ToneCurve.Channel = .rgb
    @State private var selected: Int?
    @State private var drag: Drag?
    /// True while a drag is in progress. It resets when the drag ends and also when the system
    /// cancels it, which `onEnded` doesn't report, so a drag can't be left half finished.
    @GestureState private var isDragging = false

    /// A drag in progress: the point being moved, the channel's points when it started, and
    /// where on the point it was grabbed, so the point doesn't jump to the pointer.
    private struct Drag {
        var index: Int?
        var points: [CurvePoint]
        var offset: CGSize
    }

    /// How close a click must be to a point to grab it, and how far past the graph's edge a
    /// point must be dragged to be removed.
    private static let hitRadius: CGFloat = 8
    private static let removeDistance: CGFloat = 24
    /// The closest two points can be, as a fraction of the graph's width.
    private static let minimumGap = 0.01

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Channel", selection: $channel) {
                ForEach(ToneCurve.Channel.allCases, id: \.self) { Text(Self.title(of: $0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: channel) { selected = nil }

            Canvas { context, size in draw(in: &context, size: size) }
                .aspectRatio(1, contentMode: .fit)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
                .contentShape(Rectangle())
                .gesture(dragGesture)
                .onChange(of: isDragging) { if !isDragging { endDrag() } }
                .focusable()
                .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                    nudge(press.key, by: press.modifiers.contains(.shift) ? 0.1 : 0.01)
                }
                .onKeyPress(keys: [.delete, .deleteForward]) { _ in removeSelected() }
                .accessibilityElement()
                .accessibilityLabel("Tone curve")
                .accessibilityValue("\(Self.title(of: channel)), \(points.count) points")
                .accessibilityHint("Click to add a point and drag to move it. Drag a point off the graph to remove it.")
        }
    }

    private var curve: ToneCurve { library.selectedEdit?.recipe.curve ?? ToneCurve() }
    private var points: [CurvePoint] { curve[channel] }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        context.translateBy(x: Self.inset, y: Self.inset)
        let size = Self.plotSize(size)
        let faint = Color.primary.opacity(0.07)
        if let histogram = library.selectedHistogram {
            let bins: [Float] = switch channel {
            case .rgb: (0..<Histogram.binCount).map { (histogram.red[$0] + histogram.green[$0] + histogram.blue[$0]) / 3 }
            case .red: histogram.red
            case .green: histogram.green
            case .blue: histogram.blue
            }
            context.fill(HistogramView.area(of: bins, peak: HistogramView.peak(of: histogram), in: size),
                         with: .color(Color.primary.opacity(0.1)))
        }
        var grid = Path()
        for i in 1..<4 {
            let x = size.width * CGFloat(i) / 4, y = size.height * CGFloat(i) / 4
            grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
            grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(faint), lineWidth: 0.5)
        context.stroke(Path { $0.move(to: CGPoint(x: 0, y: size.height)); $0.addLine(to: CGPoint(x: size.width, y: 0)) },
                       with: .color(faint), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

        // The other channels' curves, faintly, where they aren't straight.
        for other in ToneCurve.Channel.allCases where other != channel && !curve.isIdentity(other) {
            context.stroke(path(of: CurveSpline(curve[other]), in: size),
                           with: .color(Self.color(of: other).opacity(0.35)), lineWidth: 1)
        }
        let color = Self.color(of: channel)
        context.stroke(path(of: CurveSpline(points), in: size), with: .color(color), lineWidth: 1.5)
        for (index, point) in points.enumerated() {
            let center = position(of: point, in: size)
            context.fill(Path(ellipseIn: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)), with: .color(color))
            if index == selected {
                context.stroke(Path(ellipseIn: CGRect(x: center.x - 6.5, y: center.y - 6.5, width: 13, height: 13)),
                               with: .color(color), lineWidth: 1.5)
            }
        }
    }

    private func path(of spline: CurveSpline, in size: CGSize) -> Path {
        Path { path in
            let steps = 128
            for i in 0...steps {
                let x = Double(i) / Double(steps)
                let point = position(of: CurvePoint(x, spline(x)), in: size)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }

    /// Room around the plot so a point at a corner, and its selection ring, isn't cut off.
    /// There's no frame: the plot sits directly on the card.
    private static let inset: CGFloat = 7

    private static func plotSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(size.width - 2 * inset, 0), height: max(size.height - 2 * inset, 0))
    }

    private static func inPlot(_ location: CGPoint) -> CGPoint {
        CGPoint(x: location.x - inset, y: location.y - inset)
    }

    private func position(of point: CurvePoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.input * size.width, y: (1 - point.output) * size.height)
    }

    // MARK: Editing

    /// One drag is one undo step.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isDragging) { _, isDragging, _ in isDragging = true }
            .onChanged { value in
                let size = Self.plotSize(canvasSize)
                guard size.width > 0 else { return }
                if drag == nil { drag = startDrag(at: Self.inPlot(value.startLocation), in: size) }
                guard let drag, let index = drag.index else { return }
                let location = Self.inPlot(value.location)
                let target = CGPoint(x: location.x + drag.offset.width, y: location.y + drag.offset.height)
                set(moving(index, of: drag.points, to: target, in: size))
            }
    }

    private func endDrag() {
        guard drag != nil else { return }
        drag = nil
        library.isAdjusting = false
    }

    /// The graph's size, which the gesture needs to turn locations into curve values.
    @State private var canvasSize: CGSize = .zero

    private func startDrag(at location: CGPoint, in size: CGSize) -> Drag {
        library.isAdjusting = true
        var current = points
        let nearest = current.indices.min { distance(current[$0], location, size) < distance(current[$1], location, size) }
        if let nearest, distance(current[nearest], location, size) <= Self.hitRadius {
            let center = position(of: current[nearest], in: size)
            return Drag(index: nearest, points: current,
                        offset: CGSize(width: center.x - location.x, height: center.y - location.y))
        }
        guard current.count < ToneCurve.maximumPoints else { return Drag(index: nil, points: current, offset: .zero) }
        // A click away from every point adds one on the curve where it was clicked, so the curve
        // doesn't change until the point is dragged.
        let input = min(max(location.x / size.width, 0), 1)
        let index = current.firstIndex { $0.input > input } ?? current.count
        let gapBefore = index == 0 || input - current[index - 1].input >= Self.minimumGap
        let gapAfter = index == current.count || current[index].input - input >= Self.minimumGap
        guard index > 0, index < current.count, gapBefore, gapAfter else {
            return Drag(index: nil, points: current, offset: .zero)
        }
        current.insert(Self.rounded(CurvePoint(input, CurveSpline(current)(input))), at: index)
        let center = position(of: current[index], in: size)
        return Drag(index: index, points: current, offset: CGSize(width: center.x - location.x, height: center.y - location.y))
    }

    /// `points` with the point at `index` moved to `target`, kept between its neighbors and
    /// inside the graph, or removed when it is dragged well off the graph.
    private func moving(_ index: Int, of points: [CurvePoint], to target: CGPoint, in size: CGSize) -> [CurvePoint] {
        var points = points
        let isEnd = index == 0 || index == points.count - 1
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -Self.removeDistance, dy: -Self.removeDistance)
        if !isEnd, !bounds.contains(target) {
            points.remove(at: index)
            selected = nil
            return points
        }
        points[index] = clamped(CurvePoint(target.x / size.width, 1 - target.y / size.height), at: index, in: points)
        selected = index
        return points
    }

    private func clamped(_ point: CurvePoint, at index: Int, in points: [CurvePoint]) -> CurvePoint {
        let low = index == 0 ? 0 : points[index - 1].input + Self.minimumGap
        let high = index == points.count - 1 ? 1 : points[index + 1].input - Self.minimumGap
        return Self.rounded(CurvePoint(min(max(point.input, low), high), min(max(point.output, 0), 1)))
    }

    private func nudge(_ key: KeyEquivalent, by step: Double) -> KeyPress.Result {
        guard let selected, points.indices.contains(selected) else { return .ignored }
        var point = points[selected]
        switch key {
        case .upArrow: point.output += step
        case .downArrow: point.output -= step
        case .leftArrow: point.input -= step
        default: point.input += step
        }
        var moved = points
        moved[selected] = clamped(point, at: selected, in: points)
        set(moved)
        return .handled
    }

    private func removeSelected() -> KeyPress.Result {
        guard let selected, selected > 0, selected < points.count - 1 else { return .ignored }
        var removed = points
        removed.remove(at: selected)
        self.selected = nil
        set(removed)
        return .handled
    }

    private func set(_ points: [CurvePoint]) {
        let channel = channel
        library.changeEdit { $0.curve[channel] = points }
    }

    private func distance(_ point: CurvePoint, _ location: CGPoint, _ size: CGSize) -> CGFloat {
        let center = position(of: point, in: size)
        return hypot(center.x - location.x, center.y - location.y)
    }

    /// Four decimals is finer than the lookup can show and keeps sidecars short.
    private static func rounded(_ point: CurvePoint) -> CurvePoint {
        CurvePoint((point.input * 10_000).rounded() / 10_000, (point.output * 10_000).rounded() / 10_000)
    }

    private static func title(of channel: ToneCurve.Channel) -> String {
        switch channel {
        case .rgb: "RGB"
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        }
    }

    private static func color(of channel: ToneCurve.Channel) -> Color {
        switch channel {
        case .rgb: .primary
        case .red: HistogramView.red
        case .green: HistogramView.green
        case .blue: HistogramView.blue
        }
    }
}
