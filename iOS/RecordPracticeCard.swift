import SwiftUI

struct RecordPracticeCard: View {
    let showsGuide: Bool
    let onDismissGuide: () -> Void
    let onStroke: () -> Void
    let onPrepare: () -> Void
    let onOpenDetails: () -> Void

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 44
    @GestureState private var touch: StringTouch?
    @State private var release: StringRelease?
    @State private var guideStart = Date()

    private var ink: Color {
        scheme == .dark ? Color(red: 0.85, green: 0.90, blue: 1) : SessionPalette.kleinBlue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if typeSize.isAccessibilitySize { accessibleTitle }
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !needsAnimation)) { timeline in
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let scale = width / StringGeometry.width
                    let frame = gestureFrame(at: timeline.date)
                    ZStack(alignment: .topLeading) {
                        RecordDisc(solid: reduceTransparency)
                            .frame(width: 250 * scale, height: 250 * scale)
                            .rotationEffect(.degrees(reduceMotion ? 0 : frame.turn))
                            .position(x: 235 * scale, y: 107 * scale)
                            .accessibilityHidden(true)
                        stringSurface(frame, width: width, scale: scale)
                        if !typeSize.isAccessibilitySize {
                            sleeveTitle(scale: scale)
                            if showsGuide {
                                guideControls
                                    .position(x: width / 2, y: 219 * scale)
                                    .frame(width: width)
                            }
                        }
                    }
                    // The visible rim extends past the text margin to the screen edge.
                    .frame(width: width + 18, height: geometry.size.height, alignment: .topLeading)
                    .clipped()
                }
            }
            .aspectRatio(StringGeometry.width / StringGeometry.height, contentMode: .fit)
            if showsGuide && typeSize.isAccessibilitySize { guideControls }
            ViewThatFits(in: .horizontal) {
                HStack { practiceInfo; Spacer(minLength: 12); prepareButton }
                VStack(alignment: .leading, spacing: 8) { practiceInfo; prepareButton }
            }
            .padding(.top, 4)
        }
        .onChange(of: showsGuide) { _, visible in
            if visible { guideStart = Date(); release = nil }
        }
        .task(id: release?.start) {
            guard let start = release?.start else { return }
            do { try await Task.sleep(for: .seconds(StringRelease.duration)) } catch { return }
            if release?.start == start { release = nil }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { release = nil }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: release?.start) { _, new in new != nil }
    }

    private var needsAnimation: Bool {
        scenePhase == .active && !reduceMotion && (release != nil || (showsGuide && touch == nil))
    }

    private var accessibleTitle: some View {
        Text("随手练习")
            .font(.title.bold()).foregroundStyle(ink)
            .accessibilityAddTraits(.isHeader)
    }

    private func sleeveTitle(scale: CGFloat) -> some View {
        Button(action: onOpenDetails) {
            VStack(alignment: .leading, spacing: -4 * scale) {
                Text("随手")
                Text("练习").padding(.leading, 12 * scale)
            }
            .font(.system(size: min(titleSize, 49) * scale, weight: .bold))
            .tracking(-2.7 * scale)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(ink)
            .rotationEffect(.degrees(-6))
            .padding(.top, 6 * scale)
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!showsGuide)
        .accessibilityHidden(true)
    }

    private func stringSurface(_ frame: StringFrame, width: CGFloat, scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            PracticeString(frame: frame, dark: scheme == .dark,
                           highContrast: contrast == .increased)
            if showsGuide && touch == nil {
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 25 * scale, weight: .medium))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, ink)
                    .shadow(color: .black.opacity(0.57), radius: 1.1, y: 1)
                    .position(x: (frame.contact.x + 9) * scale, y: (frame.contact.y + 14) * scale)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: width, height: StringGeometry.height * scale)
        .contentShape(Rectangle())
        .simultaneousGesture(strokeGesture(width: width))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("随手练习，试拨琴弦")
        .accessibilityHint("轻点两下拨响一声")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { pluck(StringTouch(x: 0.54, strength: 0.72)) }
    }

    private var guideControls: some View {
        HStack(spacing: 8) {
            Label(touch == nil ? "横划，拨响第一声" : "松手，听琴声", systemImage: "arrow.left.and.right")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ink)
                .fixedSize(horizontal: false, vertical: true)
            Button("跳过", action: onDismissGuide)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(reduceTransparency ? Color.primary.opacity(0.10) : SessionPalette.sage.opacity(0.26), in: Capsule())
                .frame(minWidth: 44, minHeight: 44)
                .buttonStyle(.plain).accessibilityLabel("跳过试拨引导")
            Spacer(minLength: 0)
        }
        .padding(.leading, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var practiceInfo: some View {
        if showsGuide {
            practiceLabel
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("随手练习，20 秒")
        } else {
            Button(action: onOpenDetails) { practiceLabel }
                .buttonStyle(.plain)
                .accessibilityLabel("随手练习，20 秒")
                .accessibilityHint("打开歌曲详情")
        }
    }

    private var practiceLabel: some View {
        HStack(spacing: 8) {
            Text("内置练习曲")
            Rectangle().fill(.secondary.opacity(0.45)).frame(width: 1, height: 12)
            Text("0:20").monospacedDigit()
        }
        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var prepareButton: some View {
        if !showsGuide {
            Button(action: onPrepare) {
                Label("用手表弹", systemImage: "applewatch")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .frame(minHeight: 44)
                    .background(LinearGradient(colors: [Color(red: 0.10, green: 0.28, blue: 0.68), SessionPalette.kleinBlue],
                                               startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.32), lineWidth: 0.8))
            }
            .buttonStyle(.plain)
        }
    }

    private func strokeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .updating($touch) { value, state, _ in
                state = sample(value, width: width, threshold: 0)
            }
            .onEnded { value in
                if let sample = sample(value, width: width, threshold: 34) {
                    pluck(sample)
                }
            }
    }

    private func sample(_ value: DragGesture.Value, width: CGFloat, threshold: CGFloat) -> StringTouch? {
        let delta = value.translation
        guard width > 0, abs(delta.width) >= threshold, abs(delta.width) > 1.25 * abs(delta.height) else { return nil }
        return StringTouch(x: min(0.84, max(0.13, value.location.x / width)),
                           strength: min(1, max(-1, delta.width / 82)))
    }

    private func pluck(_ sample: StringTouch) {
        guard scenePhase == .active else { return }
        release = StringRelease(start: Date(), touch: sample)
        onStroke()
        if showsGuide { onDismissGuide() }
    }

    private func gestureFrame(at now: Date) -> StringFrame {
        if let touch { return .init(touch: touch, elapsed: nil, guide: false) }
        if let release {
            let elapsed = min(1, max(0, now.timeIntervalSince(release.start) / StringRelease.duration))
            return .init(touch: release.touch, elapsed: reduceMotion ? 1 : elapsed, guide: false)
        }
        let cycle = reduceMotion ? 0 : (now.timeIntervalSince(guideStart) / 1.65).truncatingRemainder(dividingBy: 1)
        let drift = showsGuide ? (1 - cos(2 * .pi * cycle)) * 0.028 : 0
        return .init(touch: .init(x: 0.27 + drift, strength: 0), elapsed: nil, guide: showsGuide)
    }
}

private enum StringGeometry {
    static let width: CGFloat = 306
    static let height: CGFloat = 242
    static let left = CGPoint(x: 12, y: 163)
    static let right = CGPoint(x: 280, y: 100)

    static func restY(_ x: CGFloat) -> CGFloat {
        left.y + (right.y - left.y) * (x - left.x) / (right.x - left.x)
    }
}

private struct StringTouch {
    let x: CGFloat
    let strength: CGFloat
}

private struct StringRelease {
    static let duration = 1.15
    let start: Date
    let touch: StringTouch
}

private struct StringFrame {
    let touch: StringTouch
    let elapsed: Double?
    let guide: Bool

    var contact: CGPoint {
        let x = touch.x * StringGeometry.width
        return CGPoint(x: x, y: StringGeometry.restY(x) + 36 * touch.strength)
    }

    var turn: Double {
        let t = elapsed ?? 0
        return -6 * touch.strength * exp(-5 * t) * cos(t * 10)
    }

    // Initial displacement is the same on the last drag frame and the first release frame.
    func path(echoDelay: Double = 0) -> Path {
        let span = StringGeometry.right.x - StringGeometry.left.x
        let peak = min(0.98, max(0.02, (contact.x - StringGeometry.left.x) / span))
        var path = Path()
        for i in 0...64 {
            let f = CGFloat(i) / 64
            let x = StringGeometry.left.x + f * span
            let shape = f < peak ? f / peak : (1 - f) / (1 - peak)
            var bend = 36 * touch.strength * shape
            if let elapsed {
                let t = min(1, elapsed + echoDelay)
                bend = (bend * cos(t * 15) + 13 * touch.strength * sin(.pi * f) * sin(f * 8 + t * 14) * sin(t * 8)) * pow(1 - t, 3)
            }
            let point = CGPoint(x: x, y: StringGeometry.restY(x) + bend)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

private struct PracticeString: View {
    let frame: StringFrame
    let dark: Bool
    let highContrast: Bool

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / StringGeometry.width, y: size.height / StringGeometry.height)
            if let elapsed = frame.elapsed {
                context.stroke(frame.path(echoDelay: 0.065), with: .color(SessionPalette.sage.opacity(0.9 * (1 - elapsed))), lineWidth: 2.1)
                context.stroke(frame.path(echoDelay: 0.14), with: .color(SessionPalette.sage.opacity(0.6 * (1 - elapsed))), lineWidth: 1.3)
            }
            let path = frame.path()
            let blue = dark ? Color(red: 0.42, green: 0.61, blue: 1) : SessionPalette.kleinBlue
            let edge = (frame.elapsed ?? 1) < 0.66 ? Color(red: 0.35, green: 0.46, blue: 0.35) : blue
            context.stroke(path, with: .color(edge), style: .init(lineWidth: highContrast ? 4.2 : 3.3, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(.white.opacity(0.90)), lineWidth: 1.1)
            for pin in [StringGeometry.left, StringGeometry.right] {
                let dot = CGRect(x: pin.x - 2.3, y: pin.y - 2.3, width: 4.6, height: 4.6)
                context.fill(Path(ellipseIn: dot), with: .color(blue))
                context.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: 0.8)
            }
            if frame.guide || (frame.touch.strength != 0 && frame.elapsed == nil) {
                let p = frame.contact
                let touch = Path(ellipseIn: CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16))
                context.fill(touch, with: .color(.white.opacity(0.39)))
                context.stroke(touch, with: .color(.white), lineWidth: 1.35)
            }
        }
    }
}

private struct RecordDisc: View {
    let solid: Bool
    private let silver = Color(red: 0.80, green: 0.85, blue: 0.87)
    private let rimShadow = Color(red: 0.29, green: 0.38, blue: 0.41)

    var body: some View {
        GeometryReader { proxy in
            let d = proxy.size.width
            let foil = AngularGradient(colors: [rimShadow, SessionPalette.sage, .white, silver, rimShadow,
                                                Color(white: 0.93), SessionPalette.sage, rimShadow], center: .center)
            ZStack {
                Circle().fill(foil)
                Image("LivelyPracticeCover")
                    .resizable().scaledToFill()
                    .rotationEffect(.degrees(-9)).scaleEffect(1.12)
                    .frame(width: d * 0.90, height: d * 0.90)
                    .clipShape(Circle())
                Canvas { context, size in
                    let bounds = CGRect(origin: .zero, size: size)
                    for i in 0..<16 {
                        let inset = d * (0.007 + Double(i) * 0.0095)
                        context.stroke(Path(ellipseIn: bounds.insetBy(dx: inset, dy: inset)),
                                       with: .color(i.isMultiple(of: 2) ? .white.opacity(0.36) : rimShadow.opacity(0.28)),
                                       lineWidth: 0.7)
                    }
                }
                if !solid {
                    Circle().fill(LinearGradient(stops: [
                        .init(color: .clear, location: 0.23), .init(color: .white.opacity(0.17), location: 0.41),
                        .init(color: .clear, location: 0.48), .init(color: .clear, location: 0.70),
                        .init(color: silver.opacity(0.14), location: 0.84)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                Circle().fill(foil).frame(width: d * 0.18, height: d * 0.18)
                    .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
                Circle().fill(Color(red: 0.07, green: 0.15, blue: 0.20))
                    .frame(width: d * 0.036, height: d * 0.036)
                    .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 0.8))
            }
            .shadow(color: .black.opacity(0.12), radius: 4, y: 4)
        }
    }
}
