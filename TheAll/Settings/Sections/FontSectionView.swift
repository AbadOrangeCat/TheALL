import SwiftUI

struct FontSectionView: View {
    let theme: AppTheme
    let settings: SettingsConfigStore

    private static let managedKeys = [
        "font-family",
        "font-size",
        "font-thicken",
    ]

    var body: some View {
        Form {
            FontPickerView(settings: settings, theme: theme, label: L10n.Settings.fontFamily)

            BoundStepper(
                settings: settings,
                key: "font-size",
                defaultValue: 13,
                range: 6...72,
                label: L10n.Settings.fontSize
            )

            BoundToggle(
                settings: settings,
                key: "font-thicken",
                defaultValue: false,
                label: L10n.Settings.fontThicken
            )

            SettingsResetRow(settings: settings, keys: Self.managedKeys)
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
