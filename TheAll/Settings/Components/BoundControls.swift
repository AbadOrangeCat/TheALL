import SwiftUI

// MARK: - BoundToggle

struct BoundToggle: View {
    let settings: SettingsConfigStore
    let key: String
    let defaultValue: Bool
    let label: LocalizedStringResource

    var body: some View {
        Toggle(isOn: Binding(
            get: {
                guard let raw = settings.get(key) else { return defaultValue }
                return raw.lowercased() == "true"
            },
            set: { newValue in
                if newValue == defaultValue {
                    settings.set(key, nil)
                } else {
                    settings.set(key, newValue ? "true" : "false")
                }
            }
        )) {
            Text(label)
        }
    }
}

// MARK: - BoundSlider

struct BoundSlider: View {
    let settings: SettingsConfigStore
    let key: String
    let defaultValue: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: LocalizedStringResource

    @Environment(\.locale) private var locale

    var body: some View {
        let value = Binding<Double>(
            get: {
                guard let raw = settings.get(key), let v = Double(raw) else {
                    return defaultValue
                }
                return v
            },
            set: { newValue in
                let rounded = (newValue / step).rounded() * step
                // setLive —— 50ms throttle，让 blur / opacity 等在拖动过程中
                // 持续跟随，而不是全部攒到 200ms debounce 末尾 snap 一下。
                if abs(rounded - defaultValue) < step / 2 {
                    settings.setLive(key, nil)
                } else {
                    settings.setLive(key, Self.format(rounded))
                }
            }
        )
        return LabeledContent(String(localized: (label).withLocale(locale))) {
            HStack(spacing: DT.Space.sm) {
                // 不传 `step:` 给 Slider —— macOS 在指定 step 时会在轨道下画
                // 刻度点，噪点多。吸附行为放在 setter 里：每次写入都对齐到 step，
                // 触发 get 回读把 thumb 拉回整数位，UX 等价于带 step 但无点点。
                Slider(value: value, in: range)
                    .frame(minWidth: 160)
                Text(Self.format(value.wrappedValue))
                    .monospacedDigit()
                    .frame(minWidth: DT.Space.xl * 2, alignment: .trailing)
                    .fixedSize()
            }
        }
    }

    private static func format(_ v: Double) -> String {
        if v == floor(v) { return String(Int(v)) }
        return String(format: "%.2f", v)
    }
}

// MARK: - BoundStepper (integer)

struct BoundStepper: View {
    let settings: SettingsConfigStore
    let key: String
    let defaultValue: Int
    let range: ClosedRange<Int>
    let label: LocalizedStringResource

    @Environment(\.locale) private var locale

    var body: some View {
        let value = Binding<Int>(
            get: {
                guard let raw = settings.get(key), let v = Int(raw) else {
                    return defaultValue
                }
                return v
            },
            set: { newValue in
                let clamped = min(max(newValue, range.lowerBound), range.upperBound)
                if clamped == defaultValue {
                    settings.set(key, nil)
                } else {
                    settings.set(key, String(clamped))
                }
            }
        )
        return LabeledContent(String(localized: (label).withLocale(locale))) {
            HStack(spacing: DT.Space.sm) {
                Spacer(minLength: 0)
                Stepper("", value: value, in: range)
                    .labelsHidden()
                Text("\(value.wrappedValue)")
                    .monospacedDigit()
                    .frame(minWidth: DT.Space.xl * 2, alignment: .trailing)
                    .fixedSize()
            }
        }
    }
}

// MARK: - BoundTextField

struct BoundTextField: View {
    let settings: SettingsConfigStore
    let theme: AppTheme
    let key: String
    let placeholder: LocalizedStringResource
    let label: LocalizedStringResource

    @Environment(\.locale) private var locale

    var body: some View {
        LabeledContent(String(localized: (label).withLocale(locale))) {
            HStack {
                Spacer(minLength: 0)
                TextField(String(localized: (placeholder).withLocale(locale)), text: Binding(
                    get: { settings.get(key) ?? "" },
                    set: { newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                        settings.set(key, trimmed.isEmpty ? nil : trimmed)
                    }
                ))
                .themedTextField(theme)
                .frame(minWidth: 220)
            }
        }
    }
}

// MARK: - BoundSegmented (single-select dropdown)

struct BoundSegmented: View {
    let settings: SettingsConfigStore
    let key: String
    /// 首项视作默认值（存到文件会删除该 key 行）
    let options: [String]
    let label: LocalizedStringResource

    @Environment(\.locale) private var locale

    var body: some View {
        let binding = Binding<String>(
            get: { settings.get(key) ?? options.first ?? "" },
            set: { newValue in
                if newValue == options.first {
                    settings.set(key, nil)
                } else {
                    settings.set(key, newValue)
                }
            }
        )
        return LabeledContent(String(localized: (label).withLocale(locale))) {
            HStack {
                Spacer(minLength: 0)
                Picker("", selection: binding) {
                    ForEach(options, id: \.self) { opt in
                        Text(opt).tag(opt)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}

// MARK: - BoundMultiSelect (comma-joined)

struct BoundMultiSelect: View {
    let settings: SettingsConfigStore
    let key: String
    let allOptions: [String]
    let label: LocalizedStringResource

    @Environment(\.locale) private var locale

    var body: some View {
        LabeledContent(String(localized: (label).withLocale(locale))) {
            HStack {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: DT.Space.xxs) {
                    ForEach(allOptions, id: \.self) { opt in
                        Toggle(opt, isOn: binding(for: opt))
                            .toggleStyle(.checkbox)
                    }
                }
            }
        }
    }

    private func binding(for option: String) -> Binding<Bool> {
        Binding(
            get: { currentSet().contains(option) },
            set: { isOn in
                var set = currentSet()
                if isOn { set.insert(option) } else { set.remove(option) }
                let ordered = allOptions.filter { set.contains($0) }
                settings.set(key, ordered.isEmpty ? nil : ordered.joined(separator: ","))
            }
        )
    }

    private func currentSet() -> Set<String> {
        guard let raw = settings.get(key), !raw.isEmpty else { return [] }
        return Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }
}
