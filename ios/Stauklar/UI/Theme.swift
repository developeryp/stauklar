import SwiftUI

enum Theme {
    static let accent = Color(red: 0, green: 0.443, blue: 0.89)
    static let sign = Color(red: 0.114, green: 0.345, blue: 0.706)

    static func color(_ s: Severity) -> Color {
        switch s {
        case .voll: return Color(red: 0.75, green: 0.15, blue: 0.17)
        case .sperr: return Color(red: 0.9, green: 0.2, blue: 0.16)
        case .kurz: return Color(red: 0.89, green: 0.52, blue: 0.05)
        case .dauer: return Color(red: 0.79, green: 0.64, blue: 0)
        case .live: return Color(red: 0.54, green: 0.25, blue: 0.99)
        }
    }

    static func statusColor(_ status: String) -> Color {
        switch status {
        case "rot": return color(.sperr)
        case "gelb": return color(.kurz)
        default: return Color(red: 0.12, green: 0.62, blue: 0.33)
        }
    }
}

/// Blaues Autobahnschild mit weißem Rand
struct Shield: View {
    let id: String
    var size: CGFloat = 14

    var body: some View {
        Text(id)
            .font(.system(size: size, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, size * 0.5)
            .padding(.vertical, size * 0.32)
            .frame(minWidth: size * 3.2)
            .background(Theme.sign, in: RoundedRectangle(cornerRadius: size * 0.42, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.42, style: .continuous).inset(by: size * 0.12).stroke(.white, lineWidth: size * 0.1))
            .fixedSize()
    }
}

struct StatusPill: View {
    let status: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.statusColor(status)).frame(width: 8, height: 8)
            Text(text)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Color(.secondarySystemBackground), in: Capsule())
    }
}

/// Kennzahl-Kachel wie auf der Website
struct KPI: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text("\(value)")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .padding(.top, 4)
            Text(label)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Querschnitt der Fahrbahn aus den Spurdaten der API (impact.symbols)
struct LaneGraphic: View {
    let symbols: [String]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { _, s in cell(s) }
        }
        .padding(.horizontal, 3)
        .frame(height: 22)
        .background(Color(red: 0.23, green: 0.23, blue: 0.24), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    @ViewBuilder
    private func cell(_ s: String) -> some View {
        switch s {
        case "SEPARATE": Rectangle().fill(Color(red: 0.95, green: 0.76, blue: 0)).frame(width: 3)
        case "BORDER_LEFT", "BORDER_RIGHT": Rectangle().fill(.white).frame(width: 2)
        case "BREAKDOWN_LANE": Rectangle().fill(Color(red: 0.39, green: 0.39, blue: 0.4)).frame(width: 9)
        case "CLOSED": Hatch().frame(width: 19)
        case "ARROW_UP": lane("↑", .white)
        case "ARROW_DOWN": lane("↓", Color(white: 0.7))
        default: EmptyView()
        }
    }

    private func lane(_ arrow: String, _ color: Color) -> some View {
        Text(arrow)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 19)
            .frame(maxHeight: .infinity)
            .background(Color(red: 0.28, green: 0.28, blue: 0.29))
    }

    /// Rot-weiß schraffierte Fläche für gesperrte Spuren
    struct Hatch: View {
        var body: some View {
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.9, green: 0.2, blue: 0.16)))
                var p = Path()
                var x: CGFloat = -size.height
                while x < size.width + size.height {
                    p.move(to: CGPoint(x: x, y: size.height))
                    p.addLine(to: CGPoint(x: x + size.height, y: 0))
                    x += 7
                }
                ctx.stroke(p, with: .color(.white), lineWidth: 3)
            }
        }
    }
}

struct SectionTitle: View {
    let text: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(text).font(.title2.weight(.semibold))
            if let detail { Text(detail).font(.subheadline.weight(.medium)).foregroundStyle(.secondary) }
        }
    }
}

extension View {
    /// Flache Kachel wie Apples Hellgrau-Flächen
    func card() -> some View {
        padding(16).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Filter-Knopf für eine Art von Meldung (Karte und Liste)
struct SevChip: View {
    static let all: [(Severity, String)] = [(.voll, "Vollsperrung"), (.sperr, "Auf-/Abfahrt zu"), (.kurz, "Baustelle"), (.dauer, "Dauerbaustelle"), (.live, "Stau & Gefahr")]
    let severity: Severity
    let title: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle().fill(on ? Theme.color(severity) : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                Text(title).font(.footnote.weight(.medium))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(on ? Theme.color(severity).opacity(0.14) : Color(.secondarySystemBackground), in: Capsule())
            .overlay(Capsule().stroke(on ? Theme.color(severity).opacity(0.5) : .clear, lineWidth: 1))
            .foregroundStyle(on ? Color.primary : Color.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Reihe von Filter-Knöpfen, horizontal scrollbar
struct SevChips: View {
    @Binding var on: Set<Severity>
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SevChip.all, id: \.0) { s, t in
                    SevChip(severity: s, title: t, on: on.contains(s)) {
                        if on.contains(s) { on.remove(s) } else { on.insert(s) }
                    }
                }
            }
        }
    }
}
