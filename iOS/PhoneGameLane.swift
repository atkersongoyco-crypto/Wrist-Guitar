import SwiftUI

struct PhoneGameLane: View {
    let targets: [Double]
    let firstTarget: Int
    let seconds: Double
    let feedbackTime: Double
    let grade: SongGameGrade?
    let strength: Double
    let countdown: Int?
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        let elapsed = feedbackTime.isFinite ? max(0, ProcessInfo.processInfo.systemUptime - feedbackTime) : 1
        let pulse = max(0, 1 - elapsed / 0.43)
        ZStack {
            LinearGradient(colors: [Color(red: 0.86, green: 0.90, blue: 0.96), .white,
                                    SessionPalette.sage.opacity(0.26)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { g, size in
                let mid = size.width / 2, w = size.width, h = size.height
                let strikeY = h * 0.77
                for side in [-1.0,1.0] {
                    var line = Path()
                    line.move(to: CGPoint(x: mid + w * 0.09 * side, y: -5))
                    line.addLine(to: CGPoint(x: mid + w * 0.34 * side, y: h))
                    g.stroke(line, with: .color(SessionPalette.kleinBlue.opacity(0.13)), lineWidth: 1)
                }
                var string = Path()
                let bend = reduced ? 0 : 18 * pulse * sin(elapsed * 30) * (0.6 + strength)
                string.move(to: CGPoint(x: 0, y: strikeY))
                string.addQuadCurve(to: CGPoint(x: mid, y: strikeY + bend),
                                    control: CGPoint(x: mid * 0.6, y: strikeY))
                string.addQuadCurve(to: CGPoint(x: w, y: strikeY), control: CGPoint(x: w * 0.76, y: strikeY-bend))
                g.stroke(string, with: .color(SessionPalette.kleinBlue), lineWidth: 3)
                let window = 1.8
                for index in max(0,min(targets.count, firstTarget))..<targets.count {
                    let ahead = targets[index] - seconds
                    if ahead > window { break }
                    if ahead < -0.18 { continue }
                    let location = 1 - ahead/window
                    let y = reduced ? strikeY - 35 * max(0, ceil(ahead / 0.45)) : -12 + (strikeY+12) * location
                    let width = 16 + 34 * max(0,location)
                    let rect = CGRect(x: mid - width/2, y: y-5, width: width, height: 10)
                    g.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(SessionPalette.kleinBlue.opacity(0.50 + 0.5*max(0,min(1,location)))))
                }
                if pulse > 0 {
                    let r = reduced ? 19 : 18 + 30*(1-pulse)
                    g.stroke(Path(ellipseIn: CGRect(x: mid-r, y: strikeY-r, width: 2*r, height: 2*r)),
                             with: .color((grade == .free ? SessionPalette.kleinBlue : Color(red: 0.28,green: 0.46,blue: 0.29)).opacity(pulse)),
                             lineWidth: grade == .free ? 2 : 4)
                }
            }
            if let countdown {
                Text("\(countdown)").font(.system(size: 64, weight: .bold, design: .rounded))
                    .foregroundStyle(SessionPalette.kleinBlue)
            } else if elapsed >= 0.48 && (firstTarget >= targets.count ||
                      targets[max(0, firstTarget)] - seconds > 1.8) {
                Text("自由挥腕").font(.subheadline.weight(.medium))
                    .foregroundStyle(SessionPalette.kleinBlue).offset(y: -25)
            } else if elapsed < 0.48, let grade {
                Text(grade == .perfect ? "精准" : (grade == .good ? "合拍" : "已挥动"))
                    .font(.headline).foregroundStyle(grade == .free ? SessionPalette.kleinBlue : Color(red: 0.18, green: 0.36, blue: 0.22))
                    .padding(.horizontal, 14).padding(.vertical, 7).background(.white.opacity(0.93), in: Capsule())
                    .offset(y: -26)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }
}
