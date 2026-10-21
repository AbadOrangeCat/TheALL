import SwiftUI

struct AppearanceSectionView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore

    @Environment(LanguageStore.self) private var languageStore

    /// 本 section 管控的所有 config key。Reset 按钮会把它们从 theall override 里清掉。
    private static let managedKeys = [
        "theme",
        "background-opacity",
        "background-blur-radius",
        "theall-content-opacity",
        "theall-content-shadow",
        "window-padding-x",
        "window-padding-y",
        "cursor-style",
        "cursor-style-blink",
        "unfocused-split-opacity",
    ]

    var body: some View {
        Form {
            ThemePickerView(settings: settings, theme: theme)

            BoundSlider(
                settings: settings,
                key: "background-opacity",
                defaultValue: 1.0,
                range: 0.0...1.0,
                step: 0.05,
                label: L10n.Settings.backgroundOpacity
            )

            BoundSlider(
                settings: settings,
                key: "background-blur-radius",
                defaultValue: 0,
                range: 0...100,
                step: 1,
                label: L10n.Settings.backgroundBlur
            )

            BoundSlider(
                settings: settings,
                key: "theall-content-opacity",
                defaultValue: 1.0,
                range: 0.0...1.0,
                step: 0.05,
                label: L10n.Settings.contentOpacity
            )

            BoundSlider(
                settings: settings,
                key: "theall-content-shadow",
                defaultValue: 0,
                range: 0.0...1.0,
                step: 0.05,
                label: L10n.Settings.contentShadow
            )

            BoundStepper(
                settings: settings,
                key: "window-padding-x",
                defaultValue: 4,
                range: 0...100,
                label: L10n.Settings.windowPaddingX
            )

            BoundStepper(
                settings: settings,
                key: "window-padding-y",
                defaultValue: 4,
                range: 0...100,
                label: L10n.Settings.windowPaddingY
            )

            BoundSegmented(
                settings: settings,
                key: "cursor-style",
                options: ["block", "bar", "underline"],
                label: L10n.Settings.cursorStyle
            )

            BoundToggle(
                settings: settings,
                key: "cursor-style-blink",
                defaultValue: false,
                label: L10n.Settings.cursorBlink
            )

            BoundSlider(
                settings: settings,
                key: "unfocused-split-opacity",
                defaultValue: 0.7,
                range: 0.0...1.0,
                step: 0.05,
                label: L10n.Settings.unfocusedPaneOpacity
            )

            LabeledContent {
                Picker("", selection: Binding(
                    get: { languageStore.preference },
                    set: { languageStore.preference = $0 }
                )) {
                    Text(L10n.Settings.languageSystem).tag(LanguageStore.Preference.system)
                    // Language names are intentionally NOT translated — they
                    // always display in their own language so the user can recognize them
                    // regardless of current UI language (matches macOS system Language picker).
                    Text(verbatim: "中文（简体）").tag(LanguageStore.Preference.zh)
                    Text(verbatim: "English").tag(LanguageStore.Preference.en)
                    Text(verbatim: "Français").tag(LanguageStore.Preference.fr)
                    Text(verbatim: "日本語").tag(LanguageStore.Preference.ja)
                    Text(verbatim: "한국어").tag(LanguageStore.Preference.ko)
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            } label: {
                Text(L10n.Settings.language)
            }

            SettingsResetRow(settings: settings, keys: Self.managedKeys)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
