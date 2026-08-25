//
//  ZTSpeechToTextApp.swift
//  ZTSpeechToText
//
//  Created by apple on 11/08/26.
//

import SwiftUI

@main
struct ZTSpeechToTextApp: App {
    init() {
        // ── Pick ONE provider ──────────────────────────────────────────
        // OpenAI  →  platform.openai.com/api-keys
         CloudAPIConfiguration.provider     = .openAI
         CloudAPIConfiguration.openAIAPIKey = "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"

        // Gemini  →  aistudio.google.com/apikey
//        CloudAPIConfiguration.provider     = .gemini
//        CloudAPIConfiguration.geminiAPIKey = "AQ.Ab8RN6IBV9PeZwf1CnAkDw9x8pc_QFBvzTK9alX2ibjXmhg8LA"
        // ──────────────────────────────────────────────────────────────
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
