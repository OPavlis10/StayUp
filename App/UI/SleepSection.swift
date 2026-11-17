import SwiftUI

/// Tři přepínače (dva pro spánek, úsporný režim), bdění podle AI, doba, zhasnutí displeje a hlášení.
struct SleepSection: View {
    let sleep: SleepController
    let settings: AppSettings
    let activity: AIActivityMonitor
    let network: NetworkWatch

    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    keepAwakeCard
                        .glassEffectID("keepAwake", in: glassNamespace)
                    neverSleepCard
                        .glassEffectID("neverSleep", in: glassNamespace)
                    lowPowerCard
                        .glassEffectID("lowPower", in: glassNamespace)
                }
            }

            AIAutoOffRow(settings: settings, activity: activity)

            DurationRow(sleep: sleep)

            HStack(spacing: 8) {
                Button {
                    sleep.sleepDisplayNow()
                } label: {
                    Label("Zhasnout displej teď", systemImage: "display")
                }
                .buttonStyle(.glass)
                .help(Text("Zhasne displej; Mac běží dál podle přepínačů výše"))

                Spacer(minLength: 0)

                if sleep.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Pracuji…"))
                }
            }

            if let notice = sleep.lastNotice {
                MessageBanner(message: notice, kind: .notice)
                    .transition(.opacity)
            }
            if let message = sleep.lastMessage {
                MessageBanner(message: message)
                    .transition(.opacity)
            }
            NetworkOutageBanner(network: network)
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: sleep.lowPowerOn)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: sleep.lastNotice)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: sleep.neverSleepOn)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: sleep.keepAwakeOn)
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: sleep.helperState)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: sleep.lastMessage)
    }

    // MARK: Přepínač A

    private var keepAwakeCard: some View {
        SwitchCard(
            symbol: "cup.and.saucer.fill",
            title: "Displej spí, Mac běží",
            subtitle: "Mac neusne nečinností. Displej smí zhasnout a zamknout se.",
            caption: sleep.neverSleepOn ? "Zahrnuto v režimu Nikdy nevypínat" : nil,
            isOn: Binding(
                get: { sleep.effectiveKeepAwake },
                set: { sleep.setKeepAwake($0) }
            ),
            isDisabled: sleep.neverSleepOn,
            tint: sleep.effectiveKeepAwake ? .accentColor : nil
        ) {
            EmptyView()
        }
    }

    // MARK: Přepínač B

    private var neverSleepCard: some View {
        SwitchCard(
            symbol: "bolt.shield.fill",
            title: "Nikdy nevypínat, ani po zavření víka",
            subtitle: "Mac zůstane vzhůru i se zavřeným víkem. Zahrnuje i první přepínač. Sám se vypne při slabé baterii nebo přehřívání.",
            caption: pendingCaption(until: sleep.neverSleepPendingUntil),
            // Při čekání na povolení zůstává přepínač zapnutý (záměr platí) a jeho vypnutí čekání ruší.
            isOn: Binding(
                get: { sleep.neverSleepOn || sleep.neverSleepPendingUntil != nil },
                set: { on in Task { await sleep.setNeverSleep(on) } }
            ),
            isDisabled: sleep.isBusy,
            tint: sleep.neverSleepOn ? .orange : nil
        ) {
            HelperApproval(sleep: sleep)
        }
    }

    // MARK: Úsporný režim

    private var lowPowerCard: some View {
        SwitchCard(
            symbol: "leaf.fill",
            title: "Úsporný režim",
            subtitle: "Nižší spotřeba a méně tepla, pomalejší procesor. AI v cloudu to nepozná, místní modely zpomalí.",
            caption: lowPowerCaption,
            captionTint: sleep.lowPowerSupported == false || sleep.lowPowerPendingUntil != nil ? .orange : nil,
            isOn: Binding(
                get: { sleep.lowPowerOn || sleep.lowPowerPendingUntil != nil },
                set: { on in Task { await sleep.setLowPower(on) } }
            ),
            isDisabled: sleep.isBusy || sleep.lowPowerSupported == false,
            tint: sleep.lowPowerOn ? .green : nil
        ) {
            EmptyView()
        }
    }

    /// Poctivě: co platí právě teď a čí to nastavení je.
    private var lowPowerCaption: LocalizedStringKey? {
        if sleep.lowPowerSupported == false { return "Na tomto Macu nedostupné" }
        if let pending = pendingCaption(until: sleep.lowPowerPendingUntil) { return pending }
        if sleep.lowPowerOn { return nil }
        if sleep.systemLowPowerOn { return "Úsporný režim je teď zapnutý v Nastavení systému." }
        return nil
    }

    /// Viditelná poznámka u přepínače, který čeká na povolení pomocného procesu.
    private func pendingCaption(until deadline: Date?) -> LocalizedStringKey? {
        guard let deadline else { return nil }
        let time = deadline.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(MetricsFormatter.czech))
        return "Zatím nezapnuto. Zapne se sám, až pomocný proces povolíte; čeká se do \(time)."
    }
}

// MARK: - Karta přepínače

private struct SwitchCard<Footer: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let caption: LocalizedStringKey?
    /// Barva doplňující poznámky; `nil` = barva vedlejšího textu.
    var captionTint: Color? = .orange
    @Binding var isOn: Bool
    let isDisabled: Bool
    let tint: Color?
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(isOn ? AnyShapeStyle(tint ?? .accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: 26)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.caption)
                        .secondaryText()
                        .fixedSize(horizontal: false, vertical: true)
                    if let caption {
                        Group {
                            if let captionTint {
                                Text(caption).foregroundStyle(captionTint)
                            } else {
                                Text(caption).secondaryText()
                            }
                        }
                        .font(.caption.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                    }
                }
                .accessibilityHidden(true)

                Spacer(minLength: 4)

                Toggle(isOn: $isOn) {
                    Text(title)
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(isDisabled)
                .accessibilityLabel(Text(title))
                .accessibilityHint(caption.map { Text($0) } ?? Text(subtitle))
            }

            footer
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: tint)
    }
}

// MARK: - Povolení pomocného procesu

/// Stav privilegovaného pomocného procesu přímo v kartě přepínače B. Platí i pro úsporný režim,
/// který stejný proces potřebuje; jeho karta na tento návod jen odkáže.
private struct HelperApproval: View {
    let sleep: SleepController

    var body: some View {
        switch sleep.helperState {
        case .ready:
            // Jen výsledek nové registrace, jinak nic.
            if sleep.helperNote != nil {
                block(label: nil, buttons: [])
            }
        case .notRegistered:
            block(
                label: Text("Tento režim i úsporný režim potřebují pomocný proces s právy správce. macOS vás požádá o jednorázové povolení."),
                buttons: [.register]
            )
        case .requiresApproval:
            block(
                label: isWaiting
                    ? Text("Pomocný proces čeká na povolení. V Nastavení systému › Obecné › Položky přihlášení zapněte Stay Up; přepínač se pak zapne sám.")
                    : Text("Pomocný proces čeká na povolení. V Nastavení systému › Obecné › Položky přihlášení zapněte Stay Up a pak přepínač zapněte znovu."),
                buttons: [.settings, .recheck]
            )
        case .unavailable(let reason):
            block(label: Text(verbatim: reason), buttons: [.recheck, .reregister])
        case .missingFromBundle:
            block(
                label: Text("V této kopii aplikace pomocný proces chybí. Sestavte nebo nainstalujte Stay Up znovu."),
                buttons: []
            )
        }
    }

    /// Čeká některý přepínač na povolení, aby se zapnul sám?
    private var isWaiting: Bool {
        sleep.neverSleepPendingUntil != nil || sleep.lowPowerPendingUntil != nil
    }

    private enum ActionButton {
        case register, settings, recheck, reregister
    }

    private func block(label: Text?, buttons: [ActionButton]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            if let label {
                label
                    .font(.caption)
                    .secondaryText()
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let note = sleep.helperNote {
                Text(verbatim: note)
                    .font(.caption.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text("Stav pomocného procesu"))
                    .accessibilityValue(Text(verbatim: note))
            }
            if !buttons.isEmpty {
                HStack(spacing: 8) {
                    if buttons.contains(.register) {
                        Button("Povolit pomocný proces…") {
                            Task { await sleep.registerHelper() }
                        }
                    }
                    if buttons.contains(.settings) {
                        Button("Otevřít Nastavení systému") {
                            sleep.openLoginItemsSettings()
                        }
                    }
                    if buttons.contains(.recheck) {
                        Button("Zkontrolovat znovu") {
                            Task { await sleep.refreshHelperState() }
                        }
                    }
                    if buttons.contains(.reregister) {
                        Button("Zaregistrovat znovu") {
                            Task { await sleep.reregisterHelper() }
                        }
                        .help(Text("Odregistruje pomocný proces a zaregistruje ho znovu z této aplikace"))
                    }
                }
                // Uvnitř skleněné karty obyčejná tlačítka: sklo se na sklo nevrství.
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(sleep.isBusy)
            }
        }
    }
}

// MARK: - Bdění podle AI

/// Volba „Bdít, jen dokud AI pracuje" a při zapnuté volbě jeden řádek se stavem. Řádek je vždy
/// právě jeden, takže se při změně stavu nemění výška panelu; mění se nejvýš jednou za 15 s.
private struct AIAutoOffRow: View {
    @Bindable var settings: AppSettings
    let activity: AIActivityMonitor

    var body: some View {
        let status = statusText
        VStack(alignment: .leading, spacing: 3) {
            Toggle(isOn: $settings.autoOffWhenAIIdle) {
                Text("Bdít, jen dokud AI pracuje")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityHint(Text("Až sledované aplikace dokončí práci, bdění se samo vypne a Mac může usnout."))

            if settings.autoOffWhenAIIdle {
                SteadyText(text: status)
                    .font(.caption)
                    .monospacedDigit()
                    .secondaryText()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Stav sledování AI"))
                    .accessibilityValue(Text(verbatim: status))
            }
        }
        .help(Text("Až sledované aplikace dokončí práci, bdění se samo vypne a Mac může usnout. Sledované procesy a dobu nečinnosti změníte v nastavení."))
    }

    private var statusText: String {
        switch activity.status {
        case nil:
            return String(localized: "Začne hlídat po zapnutí přepínače")
        case .measuring:
            return String(localized: "Zjišťuji aktivitu…")
        case .working(let names):
            return names.isEmpty ? String(localized: "AI pracuje") : String(localized: "AI pracuje · \(names)")
        case .idle(let minutes, let limit):
            return String(localized: "AI nečinná \(minutes)\u{00A0}min z\u{00A0}\(limit)")
        case .noProcess(let minutes, let limit):
            return String(localized: "Žádný sledovaný proces neběží, \(minutes)\u{00A0}min z\u{00A0}\(limit)")
        }
    }
}

// MARK: - Doba

private struct DurationRow: View {
    let sleep: SleepController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Doba")
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                remaining
                    .font(.caption)
                    .secondaryText()
            }
            // Vlastní segmenty místo systémového přepínače: ten má pevnou nejmenší šířku, která byla
            // větší než panel a vytlačila celý obsah z okna. Tady se čtyři volby dělí o šířku rovným dílem.
            HStack(spacing: 4) {
                ForEach(AwakeDuration.allCases) { duration in
                    let selected = sleep.duration == duration
                    Button {
                        sleep.setDuration(duration)
                    } label: {
                        Text(verbatim: duration.shortLabel)
                            .font(.callout.weight(selected ? .semibold : .regular))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .background(
                                selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                                in: .rect(cornerRadius: 7)
                            )
                            .contentShape(.rect(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: duration.label))
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Doba, po kterou zůstanou přepínače zapnuté"))
        }
    }

    @ViewBuilder
    private var remaining: some View {
        if sleep.effectiveKeepAwake {
            if let expiresAt = sleep.expiresAt {
                // Odpočet si SwiftUI překresluje samo, jen když je panel vidět.
                Text("Zbývá \(Text(timerInterval: min(Date.now, expiresAt)...expiresAt, countsDown: true))")
                    .monospacedDigit()
            } else {
                Text("Bez časového limitu")
            }
        } else {
            Text("Začne běžet po zapnutí přepínače")
        }
    }
}

extension AwakeDuration {
    /// Krátký popisek do segmentového přepínače.
    var shortLabel: String {
        switch self {
        case .oneHour: String(localized: "1\u{00A0}h")
        case .twoHours: String(localized: "2\u{00A0}h")
        case .fourHours: String(localized: "4\u{00A0}h")
        case .untilOff: String(localized: "Do vypnutí")
        }
    }
}

// MARK: - Hlášení

struct MessageBanner: View {
    enum Kind {
        /// Chyba nebo vynucené vypnutí.
        case warning
        /// Klidné sdělení: aplikace udělala, co měla.
        case notice
    }

    let message: String
    var kind: Kind = .warning

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let color: Color = kind == .warning ? .orange : .accentColor
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind == .warning ? "exclamationmark.triangle.fill" : "moon.zzz.fill")
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(verbatim: message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(color.opacity(contrast == .increased ? 0.22 : 0.12),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(color.opacity(contrast == .increased ? 0.9 : 0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(kind == .warning ? Text("Hlášení") : Text("Oznámení"))
        .accessibilityValue(Text(verbatim: message))
    }
}

/// Výpadek připojení při zapnutém bdění. Mění se jen při přechodu stavu, čas se formátuje jednou.
private struct NetworkOutageBanner: View {
    let network: NetworkWatch

    var body: some View {
        if network.phase == .lost {
            MessageBanner(message: text)
                .transition(.opacity)
        }
    }

    private var text: String {
        guard let since = network.outageStartedAt else {
            return String(localized: "Mac je bez připojení k síti.")
        }
        let time = since.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(MetricsFormatter.czech))
        return String(localized: "Mac je bez připojení k síti od \(time).")
    }
}
