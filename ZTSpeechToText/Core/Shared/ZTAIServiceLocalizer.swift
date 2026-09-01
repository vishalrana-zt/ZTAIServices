import Foundation

public enum ZTAIServiceLocalizer {
    private static let languageKey = "ZTAIServices.currentLanguage"

    public static var currentLanguageCode: String? {
        get { UserDefaults.standard.string(forKey: languageKey) }
        set {
            if let newValue, !newValue.isEmpty {
                UserDefaults.standard.set(newValue, forKey: languageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: languageKey)
            }
        }
    }

    public static func localized(_ key: String) -> String {
        let bundle = localizationBundle(for: resolvedLanguageCode()) ?? baseBundle
        return NSLocalizedString(key, bundle: bundle, comment: "")
    }

    private static var baseBundle: Bundle {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        if let url = Bundle.main.url(forResource: "ZTAIServices_ZTAIServices", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        if let url = Bundle.main.url(forResource: "ZTAIServices", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.main
        #endif
    }

    private static func localizationBundle(for code: String) -> Bundle? {
        if let path = baseBundle.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        if let path = baseBundle.path(forResource: "en", ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return nil
    }

    private static func resolvedLanguageCode() -> String {
        if let raw = currentLanguageCode, !raw.isEmpty {
            return normalizedLanguageCode(raw)
        }
        if let language = Locale.preferredLanguages.first, !language.isEmpty {
            return normalizedLanguageCode(language)
        }
        return "en"
    }

    private static func normalizedLanguageCode(_ value: String) -> String {
        let code = value.replacingOccurrences(of: "_", with: "-").lowercased()
        if code.hasPrefix("fr-ca") || code.hasPrefix("fr") { return "fr-CA" }
        if code.hasPrefix("es") { return "es" }
        return "en"
    }
}
