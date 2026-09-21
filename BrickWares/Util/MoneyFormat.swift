import Foundation

/// Money rendering + input parsing. Output strings are deliberately locale-independent and identical
/// to Android ("$3,485.02", "90.608.440₫") so a collection reads the same on both platforms.
enum Money {
    private static let usdFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSize = 3
        f.groupingSeparator = ","
        f.decimalSeparator = "."
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    private static let vndFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSize = 3
        f.groupingSeparator = "."
        f.maximumFractionDigits = 0
        return f
    }()

    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        // en_US_POSIX doesn't group by default — ask for it explicitly.
        f.usesGroupingSeparator = true
        f.groupingSize = 3
        f.groupingSeparator = ","
        f.maximumFractionDigits = 0
        return f
    }()

    /// Formats an amount already in `currency`'s own unit — USD cents or whole ₫.
    static func formatIn(_ amount: Int64, _ currency: AppCurrency) -> String {
        switch currency {
        case .vnd:
            return (vndFormatter.string(from: NSNumber(value: amount)) ?? "\(amount)") + currency.symbol
        case .usd:
            // Sign before the symbol so a loss reads "-$6.92", not "$-6.92".
            let sign = amount < 0 ? "-" : ""
            let body = usdFormatter.string(from: NSNumber(value: Double(abs(amount)) / 100.0)) ?? "0.00"
            return sign + currency.symbol + body
        }
    }

    /// Formats `amount` (in currency `from`) for display in `to`. Exact when equal.
    static func format(_ amount: Int64, from: AppCurrency, to: AppCurrency) -> String {
        formatIn(CurrencyConverter.shared.convert(amount, from: from, to: to), to)
    }

    /// Formats a **USD-cents** amount (retail, current value, aggregated totals) in `currency`.
    static func format(usdCents: Int64, in currency: AppCurrency) -> String {
        format(usdCents, from: .usd, to: currency)
    }

    /// Plain (symbol-less) prefill text for a money field. USD trims a trailing ".00" ("80").
    static func fieldText(_ amount: Int64?, from: AppCurrency, to: AppCurrency) -> String {
        guard let amount else { return "" }
        let v = CurrencyConverter.shared.convert(amount, from: from, to: to)
        switch to {
        case .vnd: return String(v)
        case .usd: return v % 100 == 0 ? String(v / 100) : String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(v) / 100.0)
        }
    }

    /// Sanitizes raw money-field text: VND digits only; USD digits plus one '.' and ≤ 2 decimals.
    static func sanitizeInput(_ raw: String, _ currency: AppCurrency, maxDigits: Int = 10) -> String {
        switch currency {
        case .vnd:
            return String(raw.filter(\.isASCIIDigit).prefix(maxDigits))
        case .usd:
            // Accept a comma as the decimal key (iOS decimal pad shows "," in many regions, incl. vi_VN).
            let filtered = raw.replacingOccurrences(of: ",", with: ".").filter { $0.isASCIIDigit || $0 == "." }
            guard let dot = filtered.firstIndex(of: ".") else { return String(filtered.prefix(maxDigits)) }
            let whole = filtered[..<dot].prefix(maxDigits)
            let frac = filtered[filtered.index(after: dot)...].filter(\.isASCIIDigit).prefix(2)
            return whole + "." + frac
        }
    }

    /// Parses money-field text typed in `currency` into that currency's own unit ("80.50" → 8050).
    static func amount(fromInput text: String, _ currency: AppCurrency, fallback: Int64 = 0) -> Int64 {
        switch currency {
        case .usd: Double(text).map { Int64(($0 * 100.0).rounded()) } ?? fallback
        case .vnd: Int64(text) ?? fallback
        }
    }

    /// 28553 → "28,553".
    static func count(_ value: Int) -> String {
        countFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// 0.48 → "0.5", -3.0 → "-3.0".
    static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// 9.0 → "+9%", -3.5 → "-3.5%".
    static func growth(_ percent: Double) -> String {
        let body: String
        if percent.truncatingRemainder(dividingBy: 1) == 0 {
            body = String(Int(percent))
        } else {
            // DecimalFormat("0.#"): at most one decimal, none when it rounds to a whole number.
            let rounded = (percent * 10).rounded() / 10
            body = rounded.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(rounded))
                : String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), rounded)
        }
        return (percent > 0 ? "+" : "") + body + "%"
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
