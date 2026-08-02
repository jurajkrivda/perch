# Runtime Language Localization Design

## Context

Perch is a macOS SwiftUI menu bar app. Most user-facing strings are currently hardcoded in SwiftUI views, AppKit menu items, alerts, and toast messages. `Perch/Resources/Localizable.strings` exists but is empty, so the app does not currently have an effective localization workflow.

The app needs five language variants:

- Czech (`cs`)
- Slovak (`sk`)
- English (`en`)
- Spanish (`es`)
- German (`de`)

The selected language must be changeable from Settings and must apply immediately without restarting Perch. When possible, the app should detect the user's preferred system language.

## Goals

- Add a language picker in General Settings.
- Support a `System` language option that chooses the first supported language from `Locale.preferredLanguages`.
- Fall back to English when the system preference does not match a supported language.
- Apply language changes immediately to SwiftUI settings screens, menu bar menu items, alerts, and toast messages.
- Store the language preference in `UserDefaults`, not in `slots.json`.
- Keep saved layout data and existing hotkey behavior unchanged.

## Non-Goals

- Do not localize user-created layout names.
- Do not change the layout document schema.
- Do not require users to restart the app after changing language.
- Do not add remote translation services or runtime network dependencies.

## Architecture

Add an app-local localization layer instead of relying only on Apple's bundle-selected `Localizable.strings` behavior. macOS normally resolves `LocalizedStringKey` from the active bundle language, which is not a reliable fit for immediate in-app language switching across both SwiftUI and AppKit menu content.

New core types:

- `AppLanguage`: supported language enum with `system`, `cs`, `sk`, `en`, `es`, and `de`.
- `LocalizationManager`: main-actor observable object that stores the selected language, resolves the effective language, and returns localized strings by key.
- `L10n`: lightweight key namespace and formatting helpers so UI code does not pass raw string literals around.

The manager persists the selected option in `UserDefaults` under `SelectedAppLanguage`. `system` is the default for new installs.

## Language Detection

When `selectedLanguage == .system`, the manager inspects `Locale.preferredLanguages` in order. It normalizes values like `cs-CZ`, `sk-SK`, `en-US`, `es-ES`, and `de-DE` to their language code and returns the first supported match.

If no supported match is found, the effective language is English.

## Runtime Update Flow

When the user selects a language in General Settings:

1. `SettingsModel` updates `LocalizationManager.selectedLanguage`.
2. The manager writes the selection to `UserDefaults`.
3. The manager posts a language-changed notification.
4. SwiftUI views observing the manager redraw immediately.
5. `MenuBarController` observes the same notification and rebuilds the status item/menu.
6. Existing windows remain open; no relaunch is requested.

## UI Changes

General Settings gets a new `Language` section with a picker containing:

- System
- Čeština
- Slovenčina
- English
- Español
- Deutsch

The picker displays each language name in its own language. The first implementation will keep the `System` row as a simple picker option without a secondary detected-language note.

## Translation Coverage

Localize user-facing strings in:

- `SettingsView`
- `GeneralSettingsTab`
- `LayoutsSettingsTab`
- `AboutSettingsTab`
- `AccessibilityBanner`
- `SettingsWindowController`
- `MenuBarController`
- `ToastWindow`
- `HotkeyRecorder`
- User-facing operation summaries and validation messages in `SlotEngine`, `WindowMover`, and `WindowSnapshotter` where they surface in UI or toasts
- `LaunchAtLogin.statusDescription`

Technical log messages and diagnostic JSON keys remain English because they are developer/support artifacts rather than UI copy.

## Error Handling

Missing localization keys fall back to the English string. In debug builds, missing keys log through `AppLog.app` to make gaps visible during development.

Formatted strings use explicit helper methods instead of ad hoc interpolation at call sites. This keeps plural-sensitive strings such as saved/restored window counts testable and avoids grammar mistakes where possible.

## Testing

Add focused unit tests for:

- Language detection from ordered preferred language lists.
- Fallback to English for unsupported system languages.
- Persistence and restoration of selected language values.
- Lookup fallback when a key is missing in a non-English language.
- Formatting helpers for common count-based messages.

Manual verification:

- Open Settings, switch each supported language, and confirm the visible settings tabs update immediately.
- Open the menu bar menu after each switch and confirm menu labels update immediately.
- Trigger save/restore toasts and confirm they use the selected language.

## Implementation Notes

The first implementation should favor explicit keys and a static in-code translation table. This best supports immediate language switching in both SwiftUI and AppKit without requiring bundle mutation or relaunch behavior. If the translation surface grows substantially, the table can later move to per-language `.strings` files while keeping the same `LocalizationManager` API.
