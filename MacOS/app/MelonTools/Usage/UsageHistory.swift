import Foundation

// MARK: - Event

/// One gateway usage line, kept forever (within the retention window) instead
/// of only in memory. The engine emits `[usage]` telemetry for every finished
/// request; the app records it here and the Usage screen aggregates it.
struct UsageEvent: Codable, Equatable, Identifiable {
    /// Stable dedup key: the same line replayed after a log tail restart must
    /// not be counted twice.
    var id: String
    var at: Date
    var model: String
    var provider: String
    var auth: String
    var input: Int
    var output: Int
    var mode: String
    var status: Int

    var isError: Bool { status >= 400 }
    var tokens: Int { input + output }

    init(
        at: Date,
        model: String,
        provider: String,
        auth: String,
        input: Int,
        output: Int,
        mode: String,
        status: Int
    ) {
        self.at = at
        self.model = model
        self.provider = provider
        self.auth = auth
        self.input = input
        self.output = output
        self.mode = mode
        self.status = status
        self.id = UsageHistory.eventID(
            at: at, model: model, provider: provider,
            input: input, output: output, status: status
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, at, model, provider, auth, input, output, mode, status
    }
}

// MARK: - Totals

/// Aggregated numbers for one selection of events.
struct UsageTotals: Equatable {
    var calls = 0
    var errors = 0
    var input = 0
    var output = 0
    /// Calls whose price is known. The estimate covers only these, which is
    /// why the UI prints the covered share instead of a bare number.
    var pricedCalls = 0
    var cost: Double = 0

    var tokens: Int { input + output }
    var errorRate: Double { calls > 0 ? Double(errors) / Double(calls) : 0 }

    mutating func add(_ event: UsageEvent, cost eventCost: Double?) {
        calls += 1
        if event.isError { errors += 1 }
        input += event.input
        output += event.output
        if let eventCost {
            pricedCalls += 1
            cost += eventCost
        }
    }

    static func + (lhs: UsageTotals, rhs: UsageTotals) -> UsageTotals {
        var sum = lhs
        sum.calls += rhs.calls
        sum.errors += rhs.errors
        sum.input += rhs.input
        sum.output += rhs.output
        sum.pricedCalls += rhs.pricedCalls
        sum.cost += rhs.cost
        return sum
    }
}

/// One row of a breakdown table.
struct UsageBreakdown: Identifiable, Equatable {
    var id: String
    var title: String
    var totals: UsageTotals
    var share: Double

    static func rows(
        from events: [UsageEvent],
        key: (UsageEvent) -> String,
        title: (String) -> String,
        cost: (UsageEvent) -> Double?
    ) -> [UsageBreakdown] {
        var buckets: [String: UsageTotals] = [:]
        for event in events {
            buckets[key(event), default: UsageTotals()].add(event, cost: cost(event))
        }
        let all = buckets.values.reduce(UsageTotals()) { $0 + $1 }
        return buckets.map { key, totals in
            UsageBreakdown(
                id: key,
                title: title(key),
                totals: totals,
                share: all.tokens > 0 ? Double(totals.tokens) / Double(all.tokens) : 0
            )
        }
        .sorted { lhs, rhs in
            if lhs.totals.tokens != rhs.totals.tokens { return lhs.totals.tokens > rhs.totals.tokens }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}

/// One bar of the chart.
struct UsageBar: Identifiable, Equatable {
    var id: Date
    var date: Date
    var label: String
    var totals: UsageTotals
}

/// Time range shown by the Usage screen.
enum UsagePeriod: String, CaseIterable, Identifiable {
    case today
    case week
    case month
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return L("Today")
        case .week: return L("7 days")
        case .month: return L("30 days")
        case .all: return L("All time")
        }
    }

    /// First instant included in the period, or nil for "all".
    func start(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .today: return calendar.startOfDay(for: now)
        case .week: return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
        case .month: return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))
        case .all: return nil
        }
    }

    /// Bar width: hours for today, days otherwise.
    var isHourly: Bool { self == .today }
}

// MARK: - Pure aggregation

/// All aggregation rules live here, free of file I/O and SwiftUI, so the
/// numbers can be unit-tested without a running gateway.
enum UsageHistory {
    static let retentionDays = 90

    static func eventID(
        at: Date,
        model: String,
        provider: String,
        input: Int,
        output: Int,
        status: Int
    ) -> String {
        let stamp = Int(at.timeIntervalSince1970)
        return "\(stamp)|\(model)|\(provider)|\(input)|\(output)|\(status)"
    }

    static func cost(of event: UsageEvent, price: SourceModel?) -> Double? {
        guard let price,
              let prompt = price.promptPerToken,
              let completion = price.completionPerToken
        else { return nil }
        return Double(event.input) * prompt + Double(event.output) * completion
    }

    static func events(
        _ events: [UsageEvent],
        in period: UsagePeriod,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [UsageEvent] {
        guard let start = period.start(now: now, calendar: calendar) else { return events }
        return events.filter { $0.at >= start }
    }

    static func totals(
        _ events: [UsageEvent],
        price: (UsageEvent) -> Double?
    ) -> UsageTotals {
        events.reduce(into: UsageTotals()) { totals, event in
            totals.add(event, cost: price(event))
        }
    }

    /// Bars for the chart. Every slot in the period is present, so a gap in
    /// traffic reads as a gap instead of a narrower chart.
    static func bars(
        _ events: [UsageEvent],
        in period: UsagePeriod,
        now: Date = Date(),
        calendar: Calendar = .current,
        price: (UsageEvent) -> Double?
    ) -> [UsageBar] {
        let formatter = DateFormatter()
        formatter.timeZone = calendar.timeZone

        if period.isHourly {
            formatter.dateFormat = "HH"
            let dayStart = calendar.startOfDay(for: now)
            var slots: [Date: UsageTotals] = [:]
            for hour in 0..<24 {
                if let slot = calendar.date(byAdding: .hour, value: hour, to: dayStart) {
                    slots[slot] = UsageTotals()
                }
            }
            for event in events where event.at >= dayStart {
                let components = calendar.dateComponents([.year, .month, .day, .hour], from: event.at)
                guard let slot = calendar.date(from: components) else { continue }
                slots[slot, default: UsageTotals()].add(event, cost: price(event))
            }
            return slots.keys.sorted().map { slot in
                UsageBar(id: slot, date: slot, label: formatter.string(from: slot), totals: slots[slot] ?? UsageTotals())
            }
        }

        formatter.dateFormat = "d MMM"
        let days: Int
        switch period {
        case .today: days = 1
        case .week: days = 7
        case .month: days = 30
        case .all: days = min(90, max(1, spanDays(events, now: now, calendar: calendar)))
        }
        let end = calendar.startOfDay(for: now)
        var slots: [Date: UsageTotals] = [:]
        for offset in stride(from: days - 1, through: 0, by: -1) {
            if let day = calendar.date(byAdding: .day, value: -offset, to: end) {
                slots[day] = UsageTotals()
            }
        }
        let first = slots.keys.min()
        for event in events {
            if let first, event.at < first { continue }
            let day = calendar.startOfDay(for: event.at)
            slots[day, default: UsageTotals()].add(event, cost: price(event))
        }
        return slots.keys.sorted().map { day in
            UsageBar(id: day, date: day, label: formatter.string(from: day), totals: slots[day] ?? UsageTotals())
        }
    }

    private static func spanDays(_ events: [UsageEvent], now: Date, calendar: Calendar) -> Int {
        guard let first = events.map(\.at).min() else { return 1 }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: first), to: calendar.startOfDay(for: now)).day ?? 1
        return max(1, days + 1)
    }
}
