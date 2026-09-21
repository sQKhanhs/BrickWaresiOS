import SwiftUI

// MARK: - Badges & small labels

struct StatusBadge: View {
    let status: Availability
    /// Minifigs only distinguish Retail vs Retired (derived from the sets they appear in).
    var labelOverride: String?

    var body: some View {
        Text(labelOverride ?? status.label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(status.color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(status.color.opacity(0.13), in: Capsule())
            .overlay(Capsule().strokeBorder(status.color.opacity(0.35)))
            .lineLimit(1)
            .fixedSize()
    }
}

/// "▲ +12.5% Growth" / "▼ -3% Growth" / "0% Growth".
struct GrowthLabel: View {
    let percent: Double
    var compact = false

    var body: some View {
        let color: Color = percent > 0 ? Bw.success : (percent < 0 ? Bw.error : Bw.textMuted)
        Text(text)
            .font((compact ? Font.caption2 : .caption).weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private var text: String {
        if percent > 0 { return L("growth_up", Money.oneDecimalTrimmed(percent)) }
        if percent < 0 { return L("growth_down", Money.oneDecimalTrimmed(percent)) }
        return L("growth_flat")
    }
}

extension Money {
    /// "9" / "12.5" / "-3" — growth body without sign or percent (the string resource adds those).
    static func oneDecimalTrimmed(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(r)) : oneDecimal(r)
    }
}

/// A "Label  value" line used on cards (Retail / Paid / Value / Sale).
struct PriceLine: View {
    let label: String
    let value: String
    var valueColor: Color = Bw.text
    var bold = false

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(Bw.textMuted)
            Text(value).font(.caption.weight(bold ? .bold : .semibold)).foregroundStyle(valueColor)
        }
        .lineLimit(1)
    }
}

/// The community "current value" with its ⓘ explainer. Shows "…" while loading and "----" when
/// there is no value; a stale value is muted.
struct ValueLine: View {
    let label: String
    let value: CurrentValue?
    var isLoading = false
    var font: Font = .caption

    @Environment(AppSettings.self) private var settings
    @State private var showInfo = false

    var body: some View {
        let _ = settings.ratesRevision
        HStack(spacing: 6) {
            Text(label).font(font).foregroundStyle(Bw.textMuted)
            Text(text)
                .font(font.weight(.semibold))
                .foregroundStyle(value?.freshness == .stale ? Bw.textMuted : Bw.text)
            Button { showInfo = true } label: {
                Image(systemName: "info.circle").font(font).foregroundStyle(Bw.link)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("current_value"))
            .popover(isPresented: $showInfo, attachmentAnchor: .point(.top), arrowEdge: .bottom) {
                Text(Self.note(for: value))
                    .font(.footnote)
                    .foregroundStyle(Bw.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(maxWidth: 280)
                    .presentationCompactAdaptation(.popover)
            }
        }
        .lineLimit(1)
    }

    private var text: String {
        if isLoading { return L("value_loading") }
        guard let minor = value?.displayMinor(settings.currency) else { return L("value_none") }
        return Money.formatIn(minor, settings.currency)
    }

    static func note(for value: CurrentValue?) -> String {
        guard let value, value.amountUsdCents != nil else { return L("value_note_none") }
        switch value.freshness {
        case .fresh: return L("value_note_fresh", value.contributionCount)
        case .stale: return L("value_note_stale", ageText(days: value.newestAgeDays ?? 0))
        case .none: return L("value_note_none")
        }
    }

    static func ageText(days: Int) -> String {
        // Same buckets as Android: < 60 days → days; < 2 years → months; else years (each min 1).
        if days < 60 { return L("value_age_days", max(1, days)) }
        if days < 730 { return L("value_age_months", max(1, days / 30)) }
        return L("value_age_years", max(1, days / 365))
    }
}

// MARK: - Placeholders

struct EmptyStateView: View {
    let message: String
    var image = "empty_state"
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            Image(image).resizable().scaledToFit().frame(maxWidth: 190, maxHeight: 210)
            Text(message).font(.subheadline).foregroundStyle(Bw.textMuted).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.bwPrimaryCompact)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36).padding(.horizontal, 24)
    }
}

struct ErrorStateView: View {
    var message = L("error_connection")
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image("error_state").resizable().scaledToFit().frame(maxWidth: 170, maxHeight: 210)
            Text(message).font(.subheadline).foregroundStyle(Bw.textMuted).multilineTextAlignment(.center)
            Button(L("action_retry"), action: retry).buttonStyle(.bwPrimaryCompact)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36).padding(.horizontal, 24)
    }
}

/// The logged-out placeholder shown where owned-item content would be.
struct SignInPromptCard: View {
    let message: String
    @Environment(AuthService.self) private var auth

    var body: some View {
        VStack(spacing: 16) {
            Image("sign_in").resizable().scaledToFit().frame(maxWidth: 170, maxHeight: 220)
            Text(message).font(.subheadline).foregroundStyle(Bw.textSecondary).multilineTextAlignment(.center)
            Button(L("action_sign_in")) { auth.requestSignIn() }.buttonStyle(.bwPrimaryCompact)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32).padding(.horizontal, 24)
    }
}

/// Wide illustrated banner at the top of a tab.
struct BannerImage: View {
    let name: String

    var body: some View {
        Image(name)
            .resizable().scaledToFill()
            .frame(maxWidth: .infinity).frame(height: 132)
            .clipShape(RoundedRectangle(cornerRadius: Bw.cardRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Three-up stat tiles (Sets / Minifigs / Pieces, or the Sales tiles).
struct StatTile: View {
    let value: String
    let label: String
    var valueColor: Color = Bw.text

    var body: some View {
        VStack(spacing: 3) {
            Text(value).font(.title3.weight(.bold)).foregroundStyle(valueColor)
                .minimumScaleFactor(0.6).lineLimit(1)
                .contentTransition(.numericText())
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(Bw.textMuted).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .bwCard(padding: 12)
    }
}

/// A capsule `Menu` for picking one option (sort orders, subtheme filters).
struct OptionMenu<Option: Hashable>: View {
    let title: String?
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String
    var systemImage = "arrow.up.arrow.down"

    var body: some View {
        Menu {
            Picker(title ?? "", selection: $selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.caption2.weight(.bold))
                Text(label(selection)).font(.caption.weight(.semibold)).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
            .foregroundStyle(Bw.textSecondary)
            .padding(.horizontal, 11).padding(.vertical, 7)
            .background(Bw.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Bw.border))
        }
    }
}

/// Section title used inside scrolling pages.
struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline).foregroundStyle(Bw.text)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Bw.textMuted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A `Label : value` row inside a details card; `onTap` renders the value as a link.
struct DetailRow<Trailing: View>: View {
    let label: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(.subheadline).foregroundStyle(Bw.textMuted)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 9)
    }
}

extension DetailRow where Trailing == Text {
    init(_ label: String, value: String) {
        self.label = label
        self.trailing = {
            Text(value).font(.subheadline.weight(.medium)).foregroundStyle(Bw.text)
        }
    }
}
