import SwiftUI

enum RecordWatchInk {
    static let foreground = Color(red: 0.075, green: 0.15, blue: 0.245)
    static let secondary = Color(red: 0.27, green: 0.34, blue: 0.37)
    static let blue = SessionPalette.kleinBlue
    static let sage = SessionPalette.sage
}

/// The always-on view uses its own black canvas. Only the awake player shows this face.
struct RecordWatchBackdrop: View {
    @Environment(\.accessibilityReduceTransparency) private var opaque

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.995, green: 0.994, blue: 0.963),
                                    Color(red: 0.953, green: 0.965, blue: 0.944),
                                    Color(red: 0.92, green: 0.94, blue: 0.965)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { context, size in
                context.translateBy(x: size.width * 1.09, y: size.height * 0.46)
                context.rotate(by: .degrees(-32))
                let width = size.width * 1.24
                let height = width * 0.54
                let outer = CGRect(x: -width / 2, y: -height / 2, width: width, height: height)
                let shape = Path(ellipseIn: outer)
                context.fill(shape, with: .linearGradient(
                    Gradient(colors: [RecordWatchInk.sage.opacity(opaque ? 0.11 : 0.32),
                                      .white.opacity(0.72), RecordWatchInk.sage.opacity(0.3)]),
                    startPoint: CGPoint(x: -width / 2, y: -height / 2),
                    endPoint: CGPoint(x: width / 2, y: height / 2)))
                for index in 0..<17 {
                    let fraction = CGFloat(index) * 0.022
                    let groove = outer.insetBy(dx: width * fraction, dy: height * fraction)
                    context.stroke(Path(ellipseIn: groove), with: .color(RecordWatchInk.secondary.opacity(0.12)), lineWidth: 0.55)
                }
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// A deterministic still of the string, also used by the timed live response.
/// Progress runs from impact (0) to settled (1).
struct RecordWatchString: View {
    var progress: Double
    var strength: Double
    var reduceMotion: Bool

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            context.scaleBy(x: size.width / 196, y: size.height / 105)
            let t = min(1, max(0, progress))
            let decay = (1 - t) * (1 - t)
            let amplitude = reduceMotion ? 0 : (32 + min(1, max(0, strength)) * 9) * decay
            let lead = Self.curve(amplitude * cos(2.7 * .pi * t))
            let wake = amplitude * sin(2.7 * .pi * t - 0.78)
            let echo = Self.curve(wake + 4)
            var membrane = lead
            membrane.addQuadCurve(to: CGPoint(x: 110, y: 56 + wake), control: CGPoint(x: 157, y: 44 + wake))
            membrane.addQuadCurve(to: CGPoint(x: -8, y: 86), control: CGPoint(x: 55, y: 84 + wake * 0.55))
            membrane.closeSubpath()
            let green = Color(red: 0.44, green: 0.58, blue: 0.44)
            context.fill(membrane, with: .color(green.opacity(0.19 + 0.16 * decay)))
            context.stroke(echo, with: .color(green.opacity(0.65)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            var shadow = context
            shadow.translateBy(x: 0, y: 1.3)
            shadow.stroke(lead, with: .color(RecordWatchInk.foreground.opacity(0.15)), lineWidth: 5)
            context.stroke(lead, with: .color(reduceMotion && t < 1 ? green : RecordWatchInk.blue),
                           style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
            context.translateBy(x: 0, y: -0.8)
            context.stroke(lead, with: .color(Color.white.opacity(0.36)), lineWidth: 0.7)
        }
        .accessibilityHidden(true)
    }

    private static func curve(_ amplitude: CGFloat) -> Path {
        Path { line in
            line.move(to: CGPoint(x: -8, y: 86))
            line.addCurve(to: CGPoint(x: 66, y: 77 + 0.57 * amplitude),
                          control1: CGPoint(x: 19, y: 83), control2: CGPoint(x: 44, y: 89 + 0.25 * amplitude))
            line.addCurve(to: CGPoint(x: 114, y: 49 + 0.6 * amplitude),
                          control1: CGPoint(x: 82, y: 69 + 0.8 * amplitude), control2: CGPoint(x: 94, y: 54 + amplitude))
            line.addCurve(to: CGPoint(x: 208, y: 14), control1: CGPoint(x: 143, y: 38 + 0.46 * amplitude),
                          control2: CGPoint(x: 168, y: 39 - 0.44 * amplitude))
        }
    }
}

struct LiveRecordWatchString: View {
    let playedCount: Int
    let active: Bool
    let strength: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started: TimeInterval?

    private var duration: TimeInterval { reduceMotion ? 0.19 : 0.86 }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30.0, paused: started == nil || reduceMotion)) { _ in
            let t = started.map { (ProcessInfo.processInfo.systemUptime - $0) / duration } ?? 1
            RecordWatchString(progress: t, strength: strength, reduceMotion: reduceMotion)
        }
        .onChange(of: playedCount) { old, new in
            started = active && new > old ? ProcessInfo.processInfo.systemUptime : nil
        }
        .task(id: started) {
            guard let hit = started else { return }
            do { try await Task.sleep(for: .seconds(duration)) }
            catch { return }
            if hit == started { started = nil }
        }
        .onChange(of: active) { _, active in
            if !active { started = nil }
        }
        .onDisappear { started = nil }
    }
}

/// Content and timing are provided by the playback model. The layout is shared with preview rendering.
struct RecordWatchFace<Volume: View, Strings: View>: View {
    let title: String
    let status: String
    var chord: String? = nil
    let elapsed: TimeInterval
    let duration: TimeInterval?
    let showsHint: Bool
    let running: Bool
    let starting: Bool
    let frontmost: Bool
    let strokeCount: Int
    let options: () -> Void
    let chooseSong: () -> Void
    let skip: () -> Void
    let audition: () -> Void
    let toggle: () -> Void
    @ViewBuilder var volume: () -> Volume
    @ViewBuilder var strings: () -> Strings

    @Environment(\.dynamicTypeSize) private var type
    @ScaledMetric(relativeTo: .headline) private var songSize = 29.0

    var body: some View {
        GeometryReader { proxy in
            let inset: CGFloat = proxy.size.width < 175 ? 10 : 15
            let small = proxy.size.height < 179
            if type.isAccessibilitySize {
                ScrollView { content(inset: inset, small: small).frame(minHeight: max(210, proxy.size.height)) }
            } else {
                content(inset: inset, small: small)
                    .frame(height: max(0, proxy.size.height))
            }
        }
        .foregroundStyle(RecordWatchInk.foreground)
        .background { RecordWatchBackdrop().ignoresSafeArea() }
        .buttonStyle(.plain)
    }

    private func content(inset: CGFloat, small: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                Button(action: options) {
                    HStack(spacing: 3) {
                        Text("自由弹奏").font(.caption.weight(.semibold)).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(RecordWatchInk.blue)
                    .frame(minHeight: small ? 28 : 33)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("自由弹奏，更多演奏选项")
                volume()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, inset + 3)
            Button(action: chooseSong) {
                Text(title)
                    .font(.system(size: min(small ? 29 : 36, songSize), weight: .bold))
                    .tracking(-1.1)
                    .lineLimit(type.isAccessibilitySize ? 3 : 2)
                    .minimumScaleFactor(0.69)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .padding(.horizontal, inset)
            .accessibilityLabel("打开曲库，\(title)")
            .accessibilityValue(status)

            ZStack(alignment: .center) {
                Button(action: audition) {
                    strings()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(chord.map { "\($0)，轻点演奏" } ?? "琴弦，轻点拨奏")
                .accessibilityValue("已拨弦 \(strokeCount) 次")
                .accessibilityHint("也可以挥动手腕拨奏")
                if showsHint {
                    HStack(spacing: 4) {
                        Image(systemName: "hand.wave").font(.caption2)
                        Text("轻挥一下，跟着弹")
                            .font(.caption2.weight(.semibold))
                            .lineLimit(2)
                        Button(action: skip) {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                                .frame(minWidth: 25, minHeight: 30)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("跳过挥腕提示")
                    }
                    .foregroundStyle(RecordWatchInk.blue)
                    .padding(.leading, 7).padding(.trailing, 2)
                    .background(.white.opacity(0.94), in: Capsule())
                    .overlay { Capsule().strokeBorder(RecordWatchInk.sage.opacity(0.75), lineWidth: 0.7).allowsHitTesting(false) }
                } else if let chord {
                    Text(chord)
                        .font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(RecordWatchInk.foreground)
                        .padding(.horizontal, 5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, inset)
                        .allowsHitTesting(false)
                } else if !running, duration != nil {
                    Text(status)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(RecordWatchInk.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, inset + 1)
                        .allowsHitTesting(false)
                }
            }
            .frame(minHeight: 44, maxHeight: .infinity)

            HStack(spacing: 7) {
                if let duration, duration > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(Duration.seconds(max(0, elapsed)).formatted(.time(pattern: .minuteSecond)))
                                .font(.system(size: small ? 16 : 19, weight: .semibold, design: .rounded))
                            Text("/ " + Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(RecordWatchInk.secondary)
                        }.monospacedDigit()
                        GeometryReader { bar in
                            ZStack(alignment: .leading) {
                                Capsule().fill(RecordWatchInk.sage.opacity(0.50))
                                Capsule().fill(RecordWatchInk.blue)
                                    .frame(width: max(0, min(1, elapsed / duration)) * bar.size.width)
                            }
                        }.frame(height: 3)
                    }
                    .frame(maxWidth: 96)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("伴奏进度")
                    .accessibilityValue("\(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond)))，共\(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))")
                } else {
                    Text(status).font(.caption2).foregroundStyle(RecordWatchInk.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                playButton
            }
            .padding(.horizontal, inset + 1)
            .padding(.bottom, small ? 1 : 3)
        }
    }

    @ViewBuilder private var playButton: some View {
        let control = Button(action: toggle) {
            Group {
                if starting { ProgressView().tint(.white) }
                else {
                    Image(systemName: running ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .offset(x: running ? 0 : 1)
                }
            }
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(LinearGradient(colors: [Color(red: 0.19, green: 0.34, blue: 0.75), RecordWatchInk.blue],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
        }
        .disabled(starting)
        .accessibilityLabel(starting ? "正在准备" : (running ? "暂停演奏" : "开始演奏"))
        #if os(watchOS)
        control.handGestureShortcut(.primaryAction, isEnabled: frontmost && !starting)
        #else
        control
        #endif
    }
}

struct RecordWatchFeelPanel: View {
    let assisted: Bool
    let followsRecording: Bool
    let calibrated: Bool
    let close: () -> Void
    let choose: (Bool) -> Void
    let calibrate: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var opaque

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                Button(action: close) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.caption.bold())
                        Text("演奏手感").font(.headline.weight(.bold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 35, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("演奏手感，返回")
                VStack(spacing: 0) {
                    choice(true)
                    Divider().overlay(RecordWatchInk.sage.opacity(0.45)).padding(.horizontal, 10)
                    choice(false)
                }
                .background(panelSurface)
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                Button(action: calibrate) {
                    HStack {
                        Text(calibrated ? "重新校准手感" : "校准轻重手感")
                            .font(.caption.weight(.semibold))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption2.bold())
                    }
                    .foregroundStyle(RecordWatchInk.blue)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 37)
                    .contentShape(Rectangle())
                }
                .background(panelSurface)
                Text(detail(for: assisted))
                    .font(.caption2).foregroundStyle(RecordWatchInk.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 3)
            }
            .padding(.horizontal, 10).padding(.vertical, 3)
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(RecordWatchInk.foreground)
        .background { RecordWatchBackdrop().ignoresSafeArea() }
        .buttonStyle(.plain)
    }

    private var panelSurface: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        return shape.fill(.white.opacity(opaque ? 1 : 0.82))
            .overlay { shape.strokeBorder(RecordWatchInk.sage.opacity(0.48), lineWidth: 0.8) }
    }

    private func detail(for light: Bool) -> String {
        if light {
            return followsRecording ? "跟着歌轻挥，伴奏会顺着手势延续。" : "轻挥单音，重挥更饱满。"
        }
        return followsRecording ? "自己掌握每一下的轻重和时机。" : "转腕选和弦，挥动控制轻重。"
    }

    private func choice(_ light: Bool) -> some View {
        let selected = assisted == light
        return Button { choose(light) } label: {
            HStack {
                Text(light ? "轻松跟弹" : "精准控弦")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selected ? RecordWatchInk.blue : RecordWatchInk.foreground)
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.subheadline)
                    .foregroundStyle(selected ? RecordWatchInk.blue : RecordWatchInk.secondary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 37)
            .background(selected ? RecordWatchInk.sage.opacity(0.16) : .clear)
            .contentShape(Rectangle())
        }
        .accessibilityHint(detail(for: light))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
