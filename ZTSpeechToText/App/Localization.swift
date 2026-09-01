import Foundation
import ZTAIServices

enum AppLocalizer {
    static func localized(_ key: String) -> String {
        ZTAIServiceLocalizer.localized(key)
    }
}
