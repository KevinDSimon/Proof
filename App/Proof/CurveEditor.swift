import AppKit
import ProofKit
import SwiftUI

/// The tone curve: a channel picker, a square graph of the chosen channel's curve with the
/// photo's histogram behind it, and black, midtone and white handles under the graph.
///
/// Clicking the graph adds a point on the curve and dragging moves it. A point is removed by
/// dragging it off the graph, by double-clicking it, or by selecting it and pressing Delete.
/// The end points can't be removed. Arrow keys nudge the selected point, Shift for larger steps.
/// The handles apply before the points: the graph draws the whole channel, handles and points
/// together, and each point where it lands on that curve.
///
/// The red, green and blue curves are drawn in the histogram's colors, so like the histogram
/// they are an exception to the inspector's gray.
struct CurveEditor: View {
    let library: Library
    @State private var channel: ToneCurve.Channel = .rgb
    @State private var selected: Int?
    @State private var drag: Drag?
    @State private var lastClick: Click?
    /// The graph's size, which the gesture needs to turn locations into curve values.
    @State private var canvasSize: CGSize = .zero
    /// Watches the keyboard, and clicks elsewhere, while a point is selected.
    @State private var keyMonitor: Any?
    /// The graph's frame in the window, to tell a click on it from a click elsewhere.
    @State private var graphFrame: CGRect = .zero
    @Environment(\.colorScheme) private var colorScheme
    /// True while a drag is in progress. It resets when the drag ends and also when the system
    /// cancels it, which `onEnded` doesn't report, so a drag can't be left half finished.
    @GestureState private var isDragging = false

    /// A drag in progress: the point being moved, the channel's points when it started, where on
    /// the point it was grabbed, so the point doesn't jump to the pointer, and whether the point
    /// is off the graph and will be removed.
    private struct Drag {
        var index: Int?
        var points: [CurvePoint]
        var offset: CGSize
        var added: Bool
        var moved = false
        var isRemoving = false
    }

    private struct Click {
        var index: Int
        var time: Date
    }

    /// How close a click must be to a point to grab it, and how far past the plot's edge a point
    /// must be dragged to be removed.
    private static let hitRadius: CGFloat = 8
    private static let removeDistance: CGFloat = 12
    /// The closest two points can be, as a fraction of the graph's width.
    private static let minimumGap = 0.01

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Channel", selection: $channel) {
                ForEach(ToneCurve.Channel.allCases, id: \.self) { Text(Self.title(of: $0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Small, with flexible segments so it spans the row like the slider tracks. The
            // segmented control sizes every segment to its longest label once it redraws; at the
            // regular size the four together are wider than the default inspector, which pushed
            // the section sideways. At the small size they fit, so flexible sizing only ever
            // widens them. Its width must not be set from the graph's: the two would feed each
            // other.
            .controlSize(.small)
            .buttonSizing(.flexible)
            .frame(maxWidth: .infinity)
            // The other rows' text sits a little below the card's edge; match it.
            .padding(.top, 2)
            .onChange(of: channel) { selected = nil }

            VStack(spacing: 2) {
                Canvas { context, size in draw(in: &context, size: size) }
                    // A fixed height rather than a square: a height that follows the width can
                    // feed back into the inspector's layout and make the section jump.
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.graphHeight)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasSize = $0 }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { graphFrame = $0 }
                    .contentShape(Rectangle())
                    .gesture(dragGesture)
                    .onChange(of: isDragging) { if !isDragging { endDrag() } }
                    .onChange(of: selected) { updateKeyMonitor() }
                    .onDisappear { selected = nil; updateKeyMonitor() }
                    .accessibilityElement()
                    .accessibilityLabel("Tone curve")
                    .accessibilityValue("\(Self.title(of: channel)), \(points.count) points")
                    .accessibilityHint("Click to add a point and drag to move it. Drag a point off the graph or double-click it to remove it.")
                // The handles belong to the RGB curve, as in Lightroom, where the color channels
                // show their color field instead. The space stays so the graph doesn't jump.
                if channel == .rgb {
                    LevelsTrack(library: library, channel: .rgb, color: Self.color(of: .rgb))
                } else {
                    Color.clear.frame(height: LevelsTrack.height)
                }
            }
            // The plot's edges line up with the other rows' content, like the slider tracks;
            // the margin that keeps corner points and end handles whole hangs into the row's
            // own padding instead of narrowing the plot.
            .padding(.horizontal, -Self.inset)
            .padding(.bottom, 2)
        }
        // Takes the inspector's width rather than asking for one. The inspector grows to fit
        // its content's preferred width, and the picker's preferred width is a little wider than
        // the default inspector, so without this the panel widened whenever the curve redrew.
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)
    }

    private var curve: ToneCurve { library.selectedEdit?.recipe.curve ?? ToneCurve() }
    private var points: [CurvePoint] { curve[channel] }
    private var levels: LevelsMap { LevelsMap(curve[levels: channel]) }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        context.translateBy(x: Self.inset, y: Self.inset)
        let size = Self.plotSize(size)
        let faint = Color.primary.opacity(0.1)
        if let field = Self.colorField(of: channel) {
            // What the color channel does where: raising the curve adds the channel's color,
            // lowering it adds the opposite one, as Lightroom shades it.
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(Gradient(colors: [field.color.opacity(0.32), field.color.opacity(0.06),
                                                                 field.opposite.opacity(0.06), field.opposite.opacity(0.32)]),
                                               startPoint: .zero, endPoint: CGPoint(x: size.width, y: size.height)))
        }
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
        context.stroke(Path(CGRect(origin: .zero, size: size)), with: .color(faint), lineWidth: 1)
        context.stroke(Path { $0.move(to: CGPoint(x: 0, y: size.height)); $0.addLine(to: CGPoint(x: size.width, y: 0)) },
                       with: .color(faint), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

        // The other channels' curves, faintly, where they aren't straight.
        for other in ToneCurve.Channel.allCases where other != channel && !curve.isIdentity(other) {
            context.stroke(path(of: curve.function(of: other), in: size),
                           with: .color(Self.color(of: other).opacity(0.35)), lineWidth: 1)
        }
        let color = Self.color(of: channel)
        let removing = drag?.isRemoving == true
        context.stroke(path(of: curve.function(of: channel), in: size), with: .color(color), lineWidth: 1.5)
        for (index, point) in points.enumerated() {
            let center = position(of: point, in: size)
            // As in Lightroom: a light gray dot outlined in the curve's color.
            let dot = Path(ellipseIn: CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9))
            context.fill(dot, with: .color(Color(white: colorScheme == .dark ? 0.62 : 0.82)))
            context.stroke(dot, with: .color(color), lineWidth: 1.5)
            if index == selected, !removing {
                context.stroke(Path(ellipseIn: CGRect(x: center.x - 7.5, y: center.y - 7.5, width: 15, height: 15)),
                               with: .color(color), lineWidth: 1.5)
            }
        }
    }

    private func path(of function: (Double) -> Double, in size: CGSize) -> Path {
        Path { path in
            let steps = 256
            for i in 0...steps {
                let x = Double(i) / Double(steps)
                let point = CGPoint(x: x * size.width, y: (1 - function(x)) * size.height)
                if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }

    /// Room around the plot so a point at a corner, and its selection ring, isn't cut off.
    static let inset: CGFloat = 9
    static let graphHeight: CGFloat = 220

    private static func plotSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(size.width - 2 * inset, 0), height: max(size.height - 2 * inset, 0))
    }

    private static func inPlot(_ location: CGPoint) -> CGPoint {
        CGPoint(x: location.x - inset, y: location.y - inset)
    }

    /// Where a point sits on the graph: its input goes through the handles first, so it is drawn
    /// where the handles move it.
    private func position(of point: CurvePoint, in size: CGSize) -> CGPoint {
        CGPoint(x: levels.inverse(point.input) * size.width, y: (1 - point.output) * size.height)
    }

    /// The point a location on the graph stands for, before clamping.
    private func value(at location: CGPoint, in size: CGSize) -> CurvePoint {
        CurvePoint(levels(location.x / size.width), 1 - location.y / size.height)
    }

    // MARK: Editing

    /// One drag is one undo step.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .updating($isDragging) { _, isDragging, _ in isDragging = true }
            .onChanged { value in
                let size = Self.plotSize(canvasSize)
                guard size.width > 0 else { return }
                if drag == nil {
                    drag = startDrag(at: Self.inPlot(value.startLocation), in: size)
                }
                guard var current = drag, let index = current.index else { return }
                if hypot(value.translation.width, value.translation.height) > 2 { current.moved = true }
                let location = Self.inPlot(value.location)
                let target = CGPoint(x: location.x + current.offset.width, y: location.y + current.offset.height)
                let isEnd = index == 0 || index == current.points.count - 1
                let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -Self.removeDistance, dy: -Self.removeDistance)
                let removing = !isEnd && !bounds.contains(target)
                if removing != current.isRemoving {
                    // The system's "poof" pointer says the point will go when the button is released.
                    if removing { NSCursor.disappearingItem.push() } else { NSCursor.pop() }
                    current.isRemoving = removing
                }
                drag = current
                set(moving(index, of: current.points, to: target, removing: removing, in: size))
            }
    }

    private func endDrag() {
        guard let ended = drag else { return }
        if ended.isRemoving { NSCursor.pop() }
        drag = nil
        // A second click on the same point, without moving it, removes it.
        if let index = ended.index, !ended.moved, !ended.added {
            if let lastClick, lastClick.index == index, Date().timeIntervalSince(lastClick.time) < NSEvent.doubleClickInterval {
                self.lastClick = nil
                selected = index
                removeSelected()
            } else {
                lastClick = Click(index: index, time: Date())
            }
        } else {
            lastClick = nil
        }
        library.isAdjusting = false
    }

    private func startDrag(at location: CGPoint, in size: CGSize) -> Drag {
        library.isAdjusting = true
        var current = points
        let nearest = current.indices.min { distance(current[$0], location, size) < distance(current[$1], location, size) }
        if let nearest, distance(current[nearest], location, size) <= Self.hitRadius {
            let center = position(of: current[nearest], in: size)
            selected = nearest
            return Drag(index: nearest, points: current,
                        offset: CGSize(width: center.x - location.x, height: center.y - location.y), added: false)
        }
        selected = nil
        guard current.count < ToneCurve.maximumPoints else {
            return Drag(index: nil, points: current, offset: .zero, added: false)
        }
        // A click away from every point adds one on the curve where it was clicked, so the curve
        // doesn't change until the point is dragged.
        let input = min(max(value(at: location, in: size).input, 0), 1)
        let index = current.firstIndex { $0.input > input } ?? current.count
        let gapBefore = index == 0 || input - current[index - 1].input >= Self.minimumGap
        let gapAfter = index == current.count || current[index].input - input >= Self.minimumGap
        guard index > 0, index < current.count, gapBefore, gapAfter else {
            return Drag(index: nil, points: current, offset: .zero, added: false)
        }
        current.insert(Self.rounded(CurvePoint(input, CurveSpline(current)(input))), at: index)
        selected = index
        let center = position(of: current[index], in: size)
        return Drag(index: index, points: current,
                    offset: CGSize(width: center.x - location.x, height: center.y - location.y), added: true)
    }

    /// `points` with the point at `index` moved to `target`, kept between its neighbors and
    /// inside the graph, or without it while it is dragged off the graph.
    private func moving(_ index: Int, of points: [CurvePoint], to target: CGPoint, removing: Bool,
                        in size: CGSize) -> [CurvePoint] {
        var points = points
        if removing {
            points.remove(at: index)
            selected = nil
            return points
        }
        points[index] = clamped(value(at: target, in: size), at: index, in: points)
        selected = index
        return points
    }

    private func clamped(_ point: CurvePoint, at index: Int, in points: [CurvePoint]) -> CurvePoint {
        let low = index == 0 ? 0 : points[index - 1].input + Self.minimumGap
        let high = index == points.count - 1 ? 1 : points[index + 1].input - Self.minimumGap
        return Self.rounded(CurvePoint(min(max(point.input, low), high), min(max(point.output, 0), 1)))
    }

    // MARK: Keyboard

    /// While a point is selected, Delete removes it and the arrow keys nudge it, Shift for larger
    /// steps. A local event monitor rather than keyboard focus: a custom view on the Mac only
    /// takes focus by click with keyboard navigation turned on, so focus-based key handling
    /// doesn't reach the graph for most people. Keys typed into a text field pass through, and
    /// a click anywhere else deselects the point, so the keys go back to the other controls.
    private func updateKeyMonitor() {
        if selected == nil, let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        } else if selected != nil, keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
                handle(event)
            }
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .leftMouseDown {
            if let content = event.window?.contentView {
                let location = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
                if !graphFrame.contains(location) { selected = nil }
            }
            return event
        }
        guard event.window?.firstResponder as? NSText == nil,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
        let step = event.modifierFlags.contains(.shift) ? 0.1 : 0.01
        switch event.keyCode {
        case 51, 117: return removeSelected() ? nil : event
        case 123: return nudge(dx: -step, dy: 0) ? nil : event
        case 124: return nudge(dx: step, dy: 0) ? nil : event
        case 125: return nudge(dx: 0, dy: -step) ? nil : event
        case 126: return nudge(dx: 0, dy: step) ? nil : event
        default: return event
        }
    }

    private func nudge(dx: Double, dy: Double) -> Bool {
        guard let selected, points.indices.contains(selected) else { return false }
        var point = points[selected]
        point.input += dx
        point.output += dy
        var moved = points
        moved[selected] = clamped(point, at: selected, in: points)
        set(moved)
        return true
    }

    @discardableResult
    private func removeSelected() -> Bool {
        guard let selected, selected > 0, selected < points.count - 1 else { return false }
        var removed = points
        removed.remove(at: selected)
        self.selected = nil
        set(removed)
        return true
    }

    private func set(_ points: [CurvePoint]) {
        let channel = channel
        library.setOn(.curve, true)
        library.changeEdit { $0.curve[channel] = points }
    }

    private func distance(_ point: CurvePoint, _ location: CGPoint, _ size: CGSize) -> CGFloat {
        let center = position(of: point, in: size)
        return hypot(center.x - location.x, center.y - location.y)
    }

    /// Four decimals is finer than the lookup can show and keeps sidecars short.
    static func rounded(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }

    private static func rounded(_ point: CurvePoint) -> CurvePoint {
        CurvePoint(rounded(point.input), rounded(point.output))
    }

    static func title(of channel: ToneCurve.Channel) -> String {
        switch channel {
        case .rgb: "RGB"
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        }
    }

    /// A color channel's own color and its opposite: cyan for red, magenta for green, yellow
    /// for blue.
    private static func colorField(of channel: ToneCurve.Channel) -> (color: Color, opposite: Color)? {
        switch channel {
        case .rgb: nil
        case .red: (HistogramView.red, Color(red: 0.25, green: 0.85, blue: 0.9))
        case .green: (HistogramView.green, Color(red: 0.9, green: 0.35, blue: 0.85))
        case .blue: (HistogramView.blue, Color(red: 0.95, green: 0.85, blue: 0.3))
        }
    }

    static func color(of channel: ToneCurve.Channel) -> Color {
        switch channel {
        case .rgb: .primary
        case .red: HistogramView.red
        case .green: HistogramView.green
        case .blue: HistogramView.blue
        }
    }
}

/// The black, midtone and white handles under the curve, as in Photoshop's Levels: drag the
/// black or white handle inward to clip, and the midtone handle to brighten (left) or darken
/// (right) the middle tones. The midtone keeps its place between the other two as they move.
/// Double-clicking a handle puts it back.
private struct LevelsTrack: View {
    let library: Library
    let channel: ToneCurve.Channel
    let color: Color
    @State private var dragged: Handle?
    @State private var lastClick: (handle: Handle, time: Date)?
    @State private var moved = false
    @State private var width: CGFloat = 0
    @GestureState private var isDragging = false

    private enum Handle: CaseIterable { case black, midtone, white }

    static let height: CGFloat = 16
    private static let hitDistance: CGFloat = 12

    var body: some View {
        Canvas { context, size in draw(in: &context, size: size) }
            .frame(height: Self.height)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($isDragging) { _, isDragging, _ in isDragging = true }
                .onChanged(changed))
            .onChange(of: isDragging) { if !isDragging { ended() } }
            .accessibilityRepresentation {
                VStack {
                    Slider(value: binding(\.black, range: 0...1), in: 0...1) { Text("\(CurveEditor.title(of: channel)) black point") }
                    Slider(value: binding(\.midtone, range: LevelsMap.midtoneRange), in: LevelsMap.midtoneRange) {
                        Text("\(CurveEditor.title(of: channel)) midtone")
                    }
                    Slider(value: binding(\.white, range: 0...1), in: 0...1) { Text("\(CurveEditor.title(of: channel)) white point") }
                }
            }
    }

    private var levels: LevelsMap { LevelsMap(library.selectedEdit?.recipe.curve[levels: channel] ?? Levels()) }

    private func x(of handle: Handle, map: LevelsMap) -> Double {
        switch handle {
        case .black: map.black
        case .white: map.white
        case .midtone: map.black + map.midtone * (map.white - map.black)
        }
    }

    /// The track spans the graph's plot, which is inset from the card by `CurveEditor.inset`; the
    /// handles at the ends hang into that margin rather than being cut off.
    private func plotWidth(_ width: CGFloat) -> CGFloat { max(width - 2 * CurveEditor.inset, 1) }

    /// Drawing passes the canvas's own width; the gesture uses the measured one.
    private func pixel(of handle: Handle, map: LevelsMap, width: CGFloat? = nil) -> CGFloat {
        CurveEditor.inset + x(of: handle, map: map) * plotWidth(width ?? self.width)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let inset = CurveEditor.inset
        let bar = CGRect(x: inset, y: 1, width: max(size.width - 2 * inset, 0), height: 3)
        context.fill(Path(roundedRect: bar, cornerRadius: 1.5),
                     with: .linearGradient(Gradient(colors: [.black, channel == .rgb ? .white : color]),
                                           startPoint: CGPoint(x: bar.minX, y: 0), endPoint: CGPoint(x: bar.maxX, y: 0)))
        let map = levels
        let fills: [Handle: Color] = [.black: Color(white: 0.08), .midtone: Color(white: 0.5), .white: Color(white: 0.96)]
        for handle in Handle.allCases {
            let center = pixel(of: handle, map: map, width: size.width)
            let triangle = Path { p in
                p.move(to: CGPoint(x: center, y: 5))
                p.addLine(to: CGPoint(x: center + 5.5, y: 14))
                p.addLine(to: CGPoint(x: center - 5.5, y: 14))
                p.closeSubpath()
            }
            context.fill(triangle, with: .color(fills[handle]!))
            context.stroke(triangle, with: .color(Color.primary.opacity(dragged == handle ? 0.9 : 0.45)), lineWidth: 1)
        }
    }

    private func changed(_ value: DragGesture.Value) {
        guard width > 0 else { return }
        let map = levels
        if dragged == nil {
            let start = value.startLocation.x
            let hits = Handle.allCases.filter { abs(pixel(of: $0, map: map) - start) <= Self.hitDistance }
            // Where black and white meet, the one on the side of the click, so both can still be
            // pulled apart; otherwise the nearest.
            let nearest: Handle? = if hits.contains(.black), hits.contains(.white) {
                start > (pixel(of: .black, map: map) + pixel(of: .white, map: map)) / 2 ? .white : .black
            } else {
                hits.min { abs(pixel(of: $0, map: map) - start) < abs(pixel(of: $1, map: map) - start) }
            }
            guard let nearest else { return }
            dragged = nearest
            moved = false
            library.isAdjusting = true
        }
        guard let dragged else { return }
        if abs(value.translation.width) > 2 { moved = true }
        let position = min(max((value.location.x - CurveEditor.inset) / plotWidth(width), 0), 1)
        var levels = Levels(black: map.black, midtone: map.midtone, white: map.white)
        switch dragged {
        case .black: levels.black = min(position, map.white - LevelsMap.minimumGap)
        case .white: levels.white = max(position, map.black + LevelsMap.minimumGap)
        case .midtone:
            let relative = (position - map.black) / (map.white - map.black)
            levels.midtone = min(max(relative, LevelsMap.midtoneRange.lowerBound), LevelsMap.midtoneRange.upperBound)
        }
        set(levels)
    }

    private func ended() {
        guard let handle = dragged else { return }
        dragged = nil
        if !moved {
            if let lastClick, lastClick.handle == handle, Date().timeIntervalSince(lastClick.time) < NSEvent.doubleClickInterval {
                self.lastClick = nil
                var levels = library.selectedEdit?.recipe.curve[levels: channel] ?? Levels()
                switch handle {
                case .black: levels.black = 0
                case .midtone: levels.midtone = 0.5
                case .white: levels.white = 1
                }
                set(levels)
            } else {
                lastClick = (handle, Date())
            }
        }
        library.isAdjusting = false
    }

    private func set(_ levels: Levels) {
        let channel = channel
        let rounded = Levels(black: CurveEditor.rounded(levels.black), midtone: CurveEditor.rounded(levels.midtone),
                             white: CurveEditor.rounded(levels.white))
        library.setOn(.curve, true)
        library.changeEdit { $0.curve[levels: channel] = rounded }
    }

    private func binding(_ keyPath: WritableKeyPath<Levels, Double>, range: ClosedRange<Double>) -> Binding<Double> {
        Binding(get: { library.selectedEdit?.recipe.curve[levels: channel][keyPath: keyPath] ?? Levels()[keyPath: keyPath] },
                set: { value in
                    var levels = library.selectedEdit?.recipe.curve[levels: channel] ?? Levels()
                    levels[keyPath: keyPath] = min(max(value, range.lowerBound), range.upperBound)
                    let map = LevelsMap(levels)
                    set(Levels(black: map.black, midtone: map.midtone, white: map.white))
                })
    }
}
