import Foundation
import ZTAIServiceEngine

enum AppLocalizer {
    static func localized(_ key: String) -> String {
        ZTAIServiceLocalizer.localized(key)
    }
}
