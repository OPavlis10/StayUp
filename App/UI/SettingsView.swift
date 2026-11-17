import SwiftUI

/// Nastavení přímo v panelu (aplikace bez ikony v Docku nemá spolehlivé samostatné okno).
struct SettingsView: View {
    @Bindable var settings: AppSettings

    /// Rozepsaný seznam sledovaných procesů; do nastavení se zapíše po potvrzení nebo opuštění pole.
    @State private var patternsText = ""
    @FocusState private var patternsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nastavení")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            group(title: "Spuštění") {
                Toggle(isOn: $settings.launchAtLogin) {
                    Text("Spouštět po přihlášení")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = settings.launchAtLoginError {
                    Text(verbatim: error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(isOn: $settings.restoreSwitchesAfterRestart) {
                    Text("Obnovit přepínače i po restartu Macu")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                caption("Po novém spuštění aplikace se přepínače obnoví vždy; po restartu Macu jen s touto volbou.")
            }

            group(title: "Pojistky režimu Nikdy nevypínat") {
                Stepper(value: $settings.batteryThresholdPercent,
                        in: AppSettings.batteryThresholdRange, step: 5) {
                    HStack {
                        Text("Vypnout při baterii pod")
                        Spacer(minLength: 8)
                        Text(verbatim: "\(settings.batteryThresholdPercent)\u{00A0}%")
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
                .accessibilityLabel(Text("Vypnout při baterii pod"))
                .accessibilityValue(Text(verbatim: "\(settings.batteryThresholdPercent) %"))

                Picker("Vypnout při teplotě", selection: $settings.thermalLimit) {
                    Text("Vypnuto").tag(0)
                    Text("Mírně zvýšená").tag(1)
                    Text("Vážná").tag(2)
                    Text("Kritická").tag(3)
                }
                caption("Když Mac běží na baterii a nabití klesne pod mez, nebo když se zahřeje na zvolenou úroveň, režim se sám vypne a Mac může znovu usínat.")
            }

            group(title: "Bdění podle AI") {
                Stepper(value: $settings.aiIdleMinutes, in: IdleTracker.minutesRange) {
                    valueLabel("Vypnout po nečinnosti", value: String(localized: "\(settings.aiIdleMinutes)\u{00A0}min"))
                }
                .accessibilityLabel(Text("Vypnout po nečinnosti"))
                .accessibilityValue(Text("\(settings.aiIdleMinutes)\u{00A0}min"))

                Stepper(value: $settings.aiCPUThresholdPercent, in: AppSettings.aiCPUThresholdRange) {
                    valueLabel("Práh aktivity", value: String(localized: "\(settings.aiCPUThresholdPercent)\u{00A0}% jádra"))
                }
                .accessibilityLabel(Text("Práh aktivity"))
                .accessibilityValue(Text("\(settings.aiCPUThresholdPercent)\u{00A0}% jednoho jádra"))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Sledované procesy")
                    TextField(text: $patternsText, prompt: Text(verbatim: ProcessMatcher.defaultPatterns.joined(separator: ", "))) {
                        Text("Sledované procesy")
                    }
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .focused($patternsFocused)
                    .onSubmit(commitPatterns)
                    .accessibilityLabel(Text("Sledované procesy, oddělené čárkou"))
                    HStack {
                        Spacer(minLength: 0)
                        Button("Obnovit výchozí") {
                            settings.aiProcessPatterns = ProcessMatcher.defaultPatterns
                            patternsText = settings.aiProcessPatterns.joined(separator: ", ")
                        }
                        .buttonStyle(.bordered)
                        .disabled(settings.aiProcessPatterns == ProcessMatcher.defaultPatterns
                                  && patternsText == ProcessMatcher.defaultPatterns.joined(separator: ", "))
                    }
                }
                caption("Názvy procesů oddělené čárkou. Stačí začátek názvu, na velikosti písmen nezáleží; vzory kratší než 3\u{00A0}znaky musí odpovídat přesně. AI pracuje, když sledované procesy dohromady vytěžují procesor aspoň na nastavený práh.")
            }
            .onAppear { patternsText = settings.aiProcessPatterns.joined(separator: ", ") }
            .onDisappear(perform: commitPatterns)
            .onChange(of: patternsFocused) { _, focused in
                if !focused { commitPatterns() }
            }

            group(title: "Hlídání sítě") {
                Toggle(isOn: $settings.networkWatchEnabled) {
                    Text("Upozornit, když Mac ztratí připojení")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Toggle(isOn: $settings.networkEndAfterEnabled) {
                    Text("Při výpadku sítě ukončit bdění")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Stepper(value: $settings.networkEndAfterMinutes, in: OutageTracker.endAfterMinutesRange) {
                    valueLabel("Ukončit po", value: String(localized: "\(settings.networkEndAfterMinutes)\u{00A0}min"))
                }
                .disabled(!settings.networkEndAfterEnabled)
                .accessibilityLabel(Text("Ukončit bdění po výpadku delším než"))
                .accessibilityValue(Text("\(settings.networkEndAfterMinutes)\u{00A0}min"))
                caption("Hlídá se jen při zapnutém bdění a výpadek se hlásí po minutě bez připojení. Sleduje jen stav síťového připojení, nic neodesílá. Nepozná výpadek internetu za routerem ani přihlašovací stránku Wi‑Fi.")
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .task { settings.refreshLaunchAtLogin() }
    }

    /// Zapíše rozepsaný seznam do nastavení a ukáže ho tak, jak se uložil (vyčištěný; prázdný = výchozí).
    private func commitPatterns() {
        let entered = patternsText.split(separator: ",").map(String.init)
        if ProcessMatcher.normalize(entered) != settings.aiProcessPatterns {
            settings.aiProcessPatterns = entered
        }
        let saved = settings.aiProcessPatterns.joined(separator: ", ")
        if patternsText != saved { patternsText = saved }
    }

    /// Popisek vlevo, hodnota vpravo (pro krokovač).
    private func valueLabel(_ title: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Text(verbatim: value)
                .monospacedDigit()
        }
    }

    private func group(title: LocalizedStringKey, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .secondaryText()
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.caption2)
            .secondaryText()
            .fixedSize(horizontal: false, vertical: true)
    }
}
