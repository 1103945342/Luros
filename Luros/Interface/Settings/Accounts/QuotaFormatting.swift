import Foundation
import LurosProtocol

/// Locale-aware formatting for `Decimal` balances, percentages, and window reset times.
enum QuotaFormatting {
    static func decimalText(_ value: Decimal, maxFractionDigits: Int = 2) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maxFractionDigits
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }

    static func balanceAmountText(_ balance: AgentQuotaBalance, amount: Decimal?) -> String {
        if balance.isUnlimited {
            return String(localized: "Unlimited")
        }
        guard let amount else {
            return String(localized: "Unavailable")
        }
        if let currency = balance.currency, !currency.isEmpty {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = currency
            formatter.maximumFractionDigits = 2
            formatter.minimumFractionDigits = 2
            if let formatted = formatter.string(from: amount as NSDecimalNumber) {
                return formatted
            }
            return "\(currency) \(decimalText(amount))"
        }
        let unit = balance.unitLabel ?? "quota"
        return "\(decimalText(amount, maxFractionDigits: 4)) \(unit)"
    }

    static func percentText(_ percent: Decimal) -> String {
        let clamped = max(0, min(100, percent))
        return "\(decimalText(clamped, maxFractionDigits: 1))%"
    }

    static func summaryText(for snapshot: AgentQuotaSnapshot) -> String? {
        switch snapshot.status {
        case .circuitBroken:
            return String(localized: "Quota unavailable (paused 24h)")
        case .cooldown:
            if snapshot.balances.isEmpty && snapshot.windows.isEmpty {
                return String(localized: "Quota cooling down")
            }
        case .error:
            if snapshot.balances.isEmpty && snapshot.windows.isEmpty {
                return String(localized: "Quota check failed")
            }
        case .unsupported:
            if snapshot.kind == .billingLink {
                return nil
            }
        case .available, .exhausted:
            break
        }

        if snapshot.kind == .window || !snapshot.windows.isEmpty {
            let parts = snapshot.windows.prefix(2).map { window in
                "\(shortWindowLabel(window)) \(percentText(window.usedPercent))"
            }
            if !parts.isEmpty {
                return parts.joined(separator: " · ")
            }
        }

        if !snapshot.balances.isEmpty {
            let primary = snapshot.balances.first(where: \.isAvailable) ?? snapshot.balances[0]
            if primary.isUnlimited {
                return String(localized: "Unlimited")
            }
            if let remaining = primary.remaining ?? primary.total {
                return balanceAmountText(primary, amount: remaining)
            }
            if let used = primary.used {
                return String(localized: "Used \(balanceAmountText(primary, amount: used))")
            }
        }

        return snapshot.status == .exhausted ? String(localized: "Exhausted") : nil
    }

    static func shortWindowLabel(_ window: AgentQuotaWindow) -> String {
        switch window.id {
        case "fiveHour": "5h"
        case "sevenDay": "7d"
        case "overage": "Overage"
        default: window.label
        }
    }

    static func statusText(for status: AgentQuotaStatus) -> String {
        switch status {
        case .available: String(localized: "Available")
        case .exhausted: String(localized: "Exhausted")
        case .cooldown: String(localized: "Cooldown")
        case .circuitBroken: String(localized: "Paused (24h)")
        case .unsupported: String(localized: "Billing Console Only")
        case .error: String(localized: "Error")
        }
    }

    static func sourceText(for snapshot: AgentQuotaSnapshot) -> String {
        switch snapshot.source {
        case .activeAPI:
            return String(localized: "Active Query")
        case .passiveHeaders:
            return String(localized: "Response Headers")
        case .probedRelay:
            switch snapshot.relayKind {
            case "sub2api": return "Sub2API"
            case "newapi": return "New API"
            case "openaiBilling": return "OpenAI Billing"
            default: return String(localized: "Relay Probe")
            }
        case .billingLink:
            return String(localized: "Official Billing Page")
        }
    }

    static func resetText(for date: Date, now: Date = Date()) -> String {
        if date <= now {
            return String(localized: "Resetting now")
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return String(localized: "Resets \(formatter.localizedString(for: date, relativeTo: now))")
    }

    struct ComposerQuotaDisplay: Equatable {
        var badgeText: String
        var usedPercent: Decimal?
        var headline: String
        var detail: String
        var isExhausted: Bool
    }

    static func primaryWindow(in snapshot: AgentQuotaSnapshot, for model: String?) -> AgentQuotaWindow? {
        guard !snapshot.windows.isEmpty else { return nil }
        if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !model.isEmpty {
            if let exact = snapshot.windows.first(where: {
                let idBase = $0.id.lowercased().split(separator: ":").first.map(String.init) ?? $0.id.lowercased()
                return idBase == model || model.hasPrefix(idBase) || idBase.hasPrefix(model) || $0.label.lowercased() == model
            }) {
                return exact
            }
            if model.contains("gemini"),
               let gemini = snapshot.windows.first(where: {
                   $0.id.lowercased().hasPrefix("gemini") || $0.label.lowercased().contains("gemini")
               })
            {
                return gemini
            }
            if model.contains("claude") || model.contains("gpt"),
               let pool = snapshot.windows.first(where: {
                   $0.id.lowercased().hasPrefix("claude-gpt") || $0.label.lowercased().contains("claude & gpt")
               })
            {
                return pool
            }
            if model.contains("opus"),
               let opus = snapshot.windows.first(where: { $0.label.lowercased().contains("opus") })
            {
                return opus
            }
            if model.contains("sonnet"),
               let sonnet = snapshot.windows.first(where: { $0.label.lowercased().contains("sonnet") })
            {
                return sonnet
            }
        }
        return snapshot.windows.first(where: { $0.id == "fiveHour" })
            ?? snapshot.windows.first(where: { $0.id == "primary" })
            ?? snapshot.windows.first
    }

    static func composerDisplay(for snapshot: AgentQuotaSnapshot, model: String?) -> ComposerQuotaDisplay? {
        if let window = primaryWindow(in: snapshot, for: model) {
            let pct = max(0, min(100, window.usedPercent))
            let intPct = Int(NSDecimalNumber(decimal: pct).doubleValue.rounded())
            let badgeText = "\(intPct)%"
            let scopeName = shortComposerWindowName(window, provider: snapshot.provider)
            let headline = String(localized: "\(scopeName) · \(percentText(pct)) used")

            var detailParts: [String] = [
                String(localized: "\(percentText(window.remainingPercent)) remaining"),
            ]
            if let reset = window.resetsAt {
                detailParts.append(resetText(for: reset))
            }
            let secondary = snapshot.windows.first { $0.id != window.id && ($0.id == "sevenDay" || $0.id == "secondary") }
            if let secondary {
                detailParts.append("\(shortWindowLabel(secondary)) \(percentText(secondary.usedPercent))")
            }
            return ComposerQuotaDisplay(
                badgeText: badgeText,
                usedPercent: pct,
                headline: headline,
                detail: detailParts.joined(separator: " · "),
                isExhausted: snapshot.status == .exhausted || pct >= 100,
            )
        }

        if !snapshot.balances.isEmpty {
            let primary = snapshot.balances.first(where: \.isAvailable) ?? snapshot.balances[0]
            if primary.isUnlimited {
                return ComposerQuotaDisplay(
                    badgeText: "∞",
                    usedPercent: 0,
                    headline: String(localized: "\(snapshot.provider.displayName) · Unlimited"),
                    detail: String(localized: "Unlimited quota"),
                    isExhausted: false,
                )
            }
            if let total = primary.total, total > 0 {
                let used = primary.used ?? primary.remaining.map { max(0, total - $0) }
                if let used {
                    let pct = max(0, min(100, (used / total) * Decimal(100)))
                    let intPct = Int(NSDecimalNumber(decimal: pct).doubleValue.rounded())
                    let remainText = balanceAmountText(primary, amount: primary.remaining ?? max(0, total - used))
                    return ComposerQuotaDisplay(
                        badgeText: "\(intPct)%",
                        usedPercent: pct,
                        headline: String(localized: "\(snapshot.provider.displayName) · \(percentText(pct)) used"),
                        detail: String(localized: "\(remainText) remaining of \(balanceAmountText(primary, amount: total))"),
                        isExhausted: snapshot.status == .exhausted || !primary.isAvailable || pct >= 100,
                    )
                }
            }
            if let remaining = primary.remaining {
                let remainText = balanceAmountText(primary, amount: remaining)
                let shortBadge = compactBalanceBadge(primary, amount: remaining)
                return ComposerQuotaDisplay(
                    badgeText: shortBadge,
                    usedPercent: nil,
                    headline: String(localized: "\(snapshot.provider.displayName) · \(remainText)"),
                    detail: primary.isAvailable ? String(localized: "Available balance") : String(localized: "Exhausted"),
                    isExhausted: snapshot.status == .exhausted || !primary.isAvailable,
                )
            }
        }

        if snapshot.status == .cooldown || snapshot.status == .circuitBroken || snapshot.status == .error {
            return ComposerQuotaDisplay(
                badgeText: "!",
                usedPercent: nil,
                headline: "\(snapshot.provider.displayName) · \(statusText(for: snapshot.status))",
                detail: snapshot.errorSummary ?? statusText(for: snapshot.status),
                isExhausted: false,
            )
        }

        return nil
    }

    private static func shortComposerWindowName(_ window: AgentQuotaWindow, provider: AgentProvider) -> String {
        switch window.id {
        case "fiveHour": return "\(provider.displayName) (5h)"
        case "sevenDay": return "\(provider.displayName) (7d)"
        default: return window.label
        }
    }

    private static func compactBalanceBadge(_ balance: AgentQuotaBalance, amount: Decimal) -> String {
        let symbol: String = switch balance.currency {
        case "USD": "$"
        case "CNY": "¥"
        case "EUR": "€"
        default: ""
        }
        let dbl = NSDecimalNumber(decimal: amount).doubleValue
        if abs(dbl) >= 1000 {
            return "\(symbol)\(Int((dbl / 1000).rounded()))k"
        }
        return "\(symbol)\(decimalText(amount, maxFractionDigits: 1))"
    }
}
