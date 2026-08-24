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
        // Whisper  →  platform.openai.com/api-keys
        // CloudAPIConfiguration.provider      = .whisper
        // CloudAPIConfiguration.whisperAPIKey = "sk-YOUR-OPENAI-KEY-HERE"

        // Gemini  →  aistudio.google.com/apikey
        CloudAPIConfiguration.provider     = .gemini
        CloudAPIConfiguration.geminiAPIKey = "AQ.Ab8RN6IBV9PeZwf1CnAkDw9x8pc_QFBvzTK9alX2ibjXmhg8LA"
        // ──────────────────────────────────────────────────────────────
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
