import SwiftUI

/// Usage: token accounting for every request the local gateway served.
///
/// The numbers come from the engine's `[usage]` telemetry, recorded by
/// `UsageStore` into daily JSONL files, and priced with the model prices the
/// provider loaders already store. The screen never invents a number: a cost
/// estimate prints how many calls it covers, and an empty period stays empty.
struct UsageView: View {
    @Binding var selection: MTSection

    @ObservedObject private var store = UsageStore.shared
    @ObservedObject private var prices = ModelSourcesStore.shared
    @ObservedObject private var providers = ProviderUsageStore.shared
    @ObservedObject private var gateway = CodexGatewayService.shared

    @State private var period: UsagePeriod = .week
    @State private var confirmClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MTTheme.s5) {
                MTPageHeader(
                    kicker: "melon tools",
                    title: L("Usage"),
                    subtitle: L("Usage subtitle")
                )
                controls
                metrics
                chartCard
                HStack(alignment: .top, spacing: MTTheme.s4) {
                    providerCard
                    modelCard
                }
                balancesCard
                recentCard
            }
            .padding(MTTheme.s6)
            .frame(maxWidth: 1080, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            store.loadIfNeeded()
            if !gateway.usageHistory.isEmpty {
                store.record(gateway.usageHistory)
            }
            Task { await providers.refresh(force: false) }
        }
        .confirmationDialog(
            L("Delete the recorded usage history?"),
            isPresented: $confirmClear,
            titleVisibility: .visible
        ) {
            Button(L("Delete history"), role: .destructive) { store.clear() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Only the local usage files are removed. Provider balances are not affected."))
        }
    }

    // MARK: - Data

    private var scopedEvents: [UsageEvent] {
        UsageHistory.events(store.events, in: period)
    }

    private func price(_ event: UsageEvent) -> Double? {
        UsageHistory.cost(of: event, price: prices.priceRow(for: event.model)?.model)
    }

    private var totals: UsageTotals {
        UsageHistory.totals(scopedEvents, price: price)
    }

    private var bars: [UsageBar] {
        UsageHistory.bars(scopedEvents, in: period, price: price)
    }

    // MARK: - Header controls

    private var controls: some View {
        HStack(spacing: MTTheme.s3) {
            MTChipPicker(items: UsagePeriod.allCases, title: { $0.title }, selection: $period)
            Spacer(minLength: MTTheme.s2)
            if store.isLoaded {
                Text(String(format: L("%d requests kept"), store.events.count))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
            }
            MTGlassButton(title: L("Refresh"), systemImage: "arrow.clockwise", tint: MTTheme.cyan) {
                Task {
                    await providers.refresh(force: true)
                    store.reload()
                }
            }
            MTMenuButton(systemImage: "ellipsis.circle", tint: MTTheme.textSecondary, entries: [
                .item(L("Reload history"), systemImage: "arrow.clockwise") { store.reload() },
                .divider,
                .item(L("Clear history"), systemImage: "trash", destructive: true) { confirmClear = true }
            ])
        }
    }

    // MARK: - Metrics

    private var metrics: some View {
        HStack(alignment: .top, spacing: MTTheme.s4) {
            MTMetricTile(
                title: L("Requests"),
                value: "\(totals.calls)",
                caption: totals.errors > 0
                    ? String(format: L("%d errors"), totals.errors)
                    : L("No failed requests"),
                tint: MTTheme.cyan
            )
            MTMetricTile(
                title: L("Input"),
                value: compact(totals.input),
                caption: L("Prompt tokens"),
                tint: MTTheme.gold
            )
            MTMetricTile(
                title: L("Output"),
                value: compact(totals.output),
                caption: L("Completion tokens"),
                tint: MTTheme.violet
            )
            MTMetricTile(
                title: L("Cost estimate"),
                value: totals.pricedCalls == 0 ? "-" : money(totals.cost),
                caption: costCaption,
                tint: MTTheme.emerald
            )
        }
        .padding(MTTheme.s4)
        .background(
            RoundedRectangle(cornerRadius: MTTheme.rCard, style: .continuous)
                .fill(MTTheme.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MTTheme.rCard, style: .continuous)
                .strokeBorder(MTTheme.borderColor.opacity(0.7), lineWidth: 0.75)
        )
    }

    private var costCaption: String {
        guard totals.calls > 0, totals.pricedCalls > 0 else {
            return L("No prices for these models")
        }
        if totals.pricedCalls == totals.calls {
            return L("From list prices")
        }
        return String(format: L("Priced %d of %d requests"), totals.pricedCalls, totals.calls)
    }

    // MARK: - Chart

    private var chartCard: some View {
        MTCard(
            title: period.isHourly ? L("Tokens by hour") : L("Tokens by day"),
            systemImage: "chart.bar.xaxis",
            accent: MTTheme.gold
        ) {
            VStack(alignment: .leading, spacing: MTTheme.s3) {
                if totals.calls == 0 {
                    MTEmptyState(
                        systemImage: "chart.bar.xaxis",
                        title: L("No requests in this period"),
                        subtitle: L("Usage lines appear here as soon as the gateway serves a request.")
                    )
                    .frame(height: 160)
                } else {
                    UsageBarChart(bars: bars)
                        .frame(height: 170)
                    HStack(spacing: MTTheme.s4) {
                        legendDot(title: L("Input"), color: MTTheme.gold)
                        legendDot(title: L("Output"), color: MTTheme.cyan)
                        Spacer(minLength: MTTheme.s2)
                        Text(String(format: L("%d requests · %@ tokens"), totals.calls, compact(totals.tokens)))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textSecondary)
                    }
                    if period == .all {
                        Text(L("All time shows at most the last 90 days."))
                            .font(MTTheme.mono(9))
                            .foregroundStyle(MTTheme.textTertiary)
                    }
                }
            }
        }
    }

    private func legendDot(title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textSecondary)
        }
    }

    // MARK: - Breakdowns

    private var providerRows: [UsageBreakdown] {
        Array(UsageBreakdown.rows(
            from: scopedEvents,
            key: { $0.provider.isEmpty ? "-" : $0.provider },
            title: { $0 == "-" ? L("Unknown") : $0 },
            cost: price
        ).prefix(8))
    }

    private var modelRows: [UsageBreakdown] {
        Array(UsageBreakdown.rows(
            from: scopedEvents,
            key: { $0.model },
            title: { $0 == "-" ? L("Unknown") : $0 },
            cost: price
        ).prefix(10))
    }

    private var providerCard: some View {
        MTCard(title: L("Providers"), systemImage: "square.stack.3d.up", accent: MTTheme.emerald) {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                if providerRows.isEmpty {
                    Text(L("Nothing recorded yet."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                } else {
                    ForEach(providerRows) { row in
                        breakdownRow(row, tint: MTTheme.emerald)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var modelCard: some View {
        MTCard(title: L("Top models"), systemImage: "square.grid.2x2", accent: MTTheme.violet) {
            VStack(alignment: .leading, spacing: MTTheme.s2) {
                if modelRows.isEmpty {
                    Text(L("Nothing recorded yet."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                } else {
                    ForEach(modelRows) { row in
                        breakdownRow(row, tint: MTTheme.violet)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func breakdownRow(_ row: UsageBreakdown, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: MTTheme.s2) {
                Text(row.title)
                    .font(MTTheme.mono(10, weight: .medium))
                    .foregroundStyle(MTTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: MTTheme.s2)
                Text(compact(row.totals.tokens) + " " + L("tokens"))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textSecondary)
                if row.totals.pricedCalls > 0 {
                    Text(money(row.totals.cost))
                        .font(MTTheme.mono(9, weight: .semibold))
                        .foregroundStyle(MTTheme.textPrimary)
                }
                Text(String(format: L("%d requests"), row.totals.calls))
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
            }
            MTMeter(fraction: row.share, tint: tint, height: 3)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Balances

    private var balancesCard: some View {
        MTCard(title: L("Balances"), systemImage: "creditcard", accent: MTTheme.cyan) {
            VStack(alignment: .leading, spacing: MTTheme.s4) {
                HStack(alignment: .top, spacing: MTTheme.s4) {
                    MTMetricTile(
                        title: "OpenRouter",
                        value: providers.openRouter?.creditsRemaining.map(money) ?? "-",
                        caption: L("Credits left on the account"),
                        tint: MTTheme.emerald
                    )
                    MTMetricTile(
                        title: L("Key balance"),
                        value: providers.openRouter?.keyRemaining.map(money) ?? "-",
                        caption: L("Remaining on this key"),
                        tint: MTTheme.cyan
                    )
                    MTMetricTile(
                        title: "Vercel",
                        value: providers.vercel?.balance.map(money) ?? "-",
                        caption: L("Team wallet"),
                        tint: MTTheme.cyan
                    )
                    MTMetricTile(
                        title: L("Claude 5 h"),
                        value: percent(providers.claude?.fiveHourPercent),
                        caption: resetCaption(providers.claude?.fiveHourReset),
                        tint: MTTheme.amber
                    )
                }
                HStack(spacing: MTTheme.s3) {
                    MTGlassButton(title: L("Refresh balances"), systemImage: "arrow.clockwise", tint: MTTheme.cyan, isLoading: false) {
                        Task { await providers.refresh(force: true) }
                    }
                    Text(L("Balances come from the providers directly; usage history never changes them."))
                        .font(MTTheme.mono(9))
                        .foregroundStyle(MTTheme.textTertiary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "-" }
        return "\(Int(value.rounded()))%"
    }

    private func resetCaption(_ date: Date?) -> String {
        guard let date else { return L("No reset reported") }
        return L("Reset") + " " + date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Recent

    private var recentCard: some View {
        MTCard(title: L("Recent requests"), systemImage: "clock", accent: MTTheme.textSecondary) {
            VStack(alignment: .leading, spacing: 0) {
                if scopedEvents.isEmpty {
                    Text(L("Nothing recorded yet."))
                        .font(MTTheme.mono(10))
                        .foregroundStyle(MTTheme.textSecondary)
                } else {
                    ForEach(Array(scopedEvents.suffix(12).reversed())) { event in
                        recentRow(event)
                        if event.id != scopedEvents.suffix(12).reversed().last?.id {
                            MTRowSeparator(inset: 0)
                        }
                    }
                }
            }
        }
    }

    private func recentRow(_ event: UsageEvent) -> some View {
        HStack(spacing: MTTheme.s2) {
            MTStatusDot(status: event.isError ? .error : .ok, size: 6)
            Text(event.at.formatted(date: .omitted, time: .standard))
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textTertiary)
                .frame(width: 74, alignment: .leading)
            Text(event.provider == "-" ? L("Unknown") : event.provider)
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textSecondary)
                .frame(width: 92, alignment: .leading)
                .lineLimit(1)
            Text(event.model)
                .font(MTTheme.mono(9.5))
                .foregroundStyle(MTTheme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: MTTheme.s2)
            Text("\(compact(event.input)) / \(compact(event.output))")
                .font(MTTheme.mono(9))
                .foregroundStyle(MTTheme.textSecondary)
            if let cost = price(event) {
                Text(money(cost))
                    .font(MTTheme.mono(9, weight: .semibold))
                    .foregroundStyle(MTTheme.textPrimary)
                    .frame(width: 58, alignment: .trailing)
            } else {
                Text("-")
                    .font(MTTheme.mono(9))
                    .foregroundStyle(MTTheme.textTertiary)
                    .frame(width: 58, alignment: .trailing)
            }
            if event.isError {
                MTBadge(text: "HTTP \(event.status)", tint: MTTheme.ruby)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Formatting

    private func compact(_ value: Int) -> String {
        if value >= 1_000_000 {
            return decimal(Double(value) / 1_000_000) + " " + L("M")
        }
        if value >= 1_000 {
            return decimal(Double(value) / 1_000) + " " + L("K")
        }
        return "\(value)"
    }

    /// One fractional digit in the user's locale, so Russian prints `2,9`.
    private func decimal(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

    private func money(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = value >= 100 ? 0 : (value >= 1 ? 2 : 4)
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }
}

// MARK: - Chart

/// Stacked bar chart: input tokens at the bottom, output on top. Drawn with
/// `Canvas` so a 30 day series stays cheap and the card can be resized freely.
struct UsageBarChart: View {
    let bars: [UsageBar]

    private var maxTokens: Int {
        max(1, bars.map { $0.totals.input + $0.totals.output }.max() ?? 1)
    }

    var body: some View {
        Canvas { context, size in
            let bottomPadding: CGFloat = 16
            let topPadding: CGFloat = 6
            let plotHeight = max(1, size.height - bottomPadding - topPadding)
            let count = max(1, bars.count)
            let slot = size.width / CGFloat(count)
            let barWidth = min(18, max(3, slot * 0.62))
            let scale: CGFloat = plotHeight / CGFloat(maxTokens)

            // Grid: 4 hairlines with the top one carrying the max value.
            for step in 0...4 {
                let y = topPadding + plotHeight * CGFloat(step) / 4
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(
                    line,
                    with: .color(Color.primary.opacity(step == 4 ? 0.14 : 0.07)),
                    lineWidth: 0.5
                )
            }

            for (index, bar) in bars.enumerated() {
                let centerX = slot * (CGFloat(index) + 0.5)
                let inputHeight = CGFloat(bar.totals.input) * scale
                let outputHeight = CGFloat(bar.totals.output) * scale
                let totalHeight = inputHeight + outputHeight
                guard totalHeight > 0.2 else { continue }
                let x = centerX - barWidth / 2
                let baseY = topPadding + plotHeight

                let inputRect = CGRect(x: x, y: baseY - inputHeight, width: barWidth, height: inputHeight)
                context.fill(
                    Path(roundedRect: inputRect, cornerRadius: min(3, barWidth / 3)),
                    with: .color(MTTheme.gold.opacity(0.9))
                )
                if outputHeight > 0.2 {
                    let outputRect = CGRect(
                        x: x,
                        y: baseY - totalHeight,
                        width: barWidth,
                        height: max(0, outputHeight - 0.5)
                    )
                    context.fill(
                        Path(roundedRect: outputRect, cornerRadius: min(3, barWidth / 3)),
                        with: .color(MTTheme.cyan.opacity(0.85))
                    )
                }
            }

            // Value labels: max on the left, zero at the bottom.
            let label = Text(formatToken(maxTokens))
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(Color.secondary)
            context.draw(label, at: CGPoint(x: 18, y: topPadding + 2), anchor: .topLeading)

            // X labels: first, middle and last slot only, so 30 days of bars
            // do not collide into an unreadable strip.
            if bars.count > 1 {
                let indices = [0, bars.count / 2, bars.count - 1]
                for index in indices {
                    let text = Text(bars[index].label)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Color.secondary)
                    let x = slot * (CGFloat(index) + 0.5)
                    context.draw(text, at: CGPoint(x: x, y: size.height - 2), anchor: .bottom)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("Token usage chart"))
        .accessibilityValue(String(format: L("%d bars"), bars.count))
    }

    private func formatToken(_ value: Int) -> String {
        if value >= 1_000_000 {
            return (Double(value) / 1_000_000).formatted(.number.precision(.fractionLength(1))) + " " + L("M")
        }
        if value >= 1_000 {
            return (Double(value) / 1_000).formatted(.number.precision(.fractionLength(0))) + " " + L("K")
        }
        return "\(value)"
    }
}
