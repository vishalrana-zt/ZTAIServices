import SwiftUI
import UIKit
import ZTAIServices

// MARK: - Localized strings

private enum ZTAIOnboardingStrings {
    private static func localized(_ key: String, fallback: String) -> String {
        let v = ZTAIServiceLocalizer.localized(key)
        return v == key ? fallback : v
    }

    static var micTitle: String        { localized("lbl_ai_onboarding_mic_title",         fallback: "Speak") }
    static var micSubtitle: String     { localized("lbl_ai_onboarding_mic_subtitle",      fallback: "Tap the mic to dictate your notes. We convert your speech into editable text.") }
    static var cleanupTitle: String    { localized("lbl_ai_onboarding_cleanup_title",     fallback: "Clean Up & Summarize") }
    static var cleanupSubtitle: String { localized("lbl_ai_onboarding_cleanup_subtitle",  fallback: "Polish your text with Clean Up or summarize it. Choose Short for key points, Standard for a balanced summary, or Detailed for full context.") }
    static var autofillTitle: String   { localized("lbl_ai_onboarding_autofill_title",    fallback: "Auto Fill") }
    static var autofillSubtitle: String{ localized("lbl_ai_onboarding_autofill_subtitle", fallback: "Capture details from a photo or by dictating with your voice. We map them to matching form fields so you can review and save faster.") }
    static var done: String            { "Done" }
    static var next: String            { localized("lbl_ai_onboarding_next",              fallback: "Next") }
    static var skip: String            { localized("lbl_ai_onboarding_skip",              fallback: "Skip") }
    static var cleanupPillCleanUp: String  { localized("lbl_ai_onboarding_pill_cleanup",  fallback: "Clean Up") }
    static var cleanupPillShort: String    { localized("lbl_ai_onboarding_pill_short",    fallback: "Short") }
    static var cleanupPillStandard: String { localized("lbl_ai_onboarding_pill_standard", fallback: "Standard") }
    static var cleanupPillDetailed: String { localized("lbl_ai_onboarding_pill_detailed", fallback: "Detailed") }
    static var appleBadgeNote: String { localized("lbl_ai_onboarding_apple_badge_note", fallback: "Apple Foundation Models badge indicates, this AI action uses on-device Apple models and can work offline when available.") }
    static var outputDisclaimer: String { localized("lbl_ai_onboarding_output_disclaimer", fallback: "It can make mistakes. Please review before using.") }
}

// MARK: - Notification names (buttons post their window frames here)

public extension Notification.Name {
    static let ztAIMicButtonFrame     = Notification.Name("ZTAIMicButtonFrameUpdated")
    static let ztAICleanupButtonFrame = Notification.Name("ZTAICleanupButtonFrameUpdated")
    static let ztAIAutofillButtonFrame  = Notification.Name("ZTAIAutofillButtonFrameUpdated")
    /// Posted when the spotlight tour activates so the host VC can scroll AI buttons into view
    static let ztAIOnboardingDidActivate = Notification.Name("ZTAIOnboardingDidActivate")
}

// MARK: - Internal step model

private struct ZTAIOnboardingInternalStep {
    let stepKey: String
    let highlightFrame: CGRect   // in global window coords
    let title: String
    let body: String
    let pills: [String]
    let icon: String
    let color: Color
}

// MARK: - Host view

public struct ZTAIOnboardingHostView: View {
    public let shouldShow: Bool
    public let showsAutofill: Bool
    public let pendingStepKeys: Set<String>
    public let frameDebounceDelay: Double
    public let revealDelay: Double
    /// Called when user explicitly completes the tour (Skip / Done) with visible step keys.
    public let onDismiss: ([String]) -> Void
    /// Called when the tour is abandoned silently (timeout / VC dismissed) → does NOT mark done.
    public let onAbandon: () -> Void

    public init(
        shouldShow: Bool,
        showsAutofill: Bool = false,
        pendingStepKeys: [String] = ["mic", "cleanup", "autofill"],
        frameDebounceDelay: Double = 0.15,
        revealDelay: Double = 0.65,
        onDismiss: @escaping ([String]) -> Void,
        onAbandon: @escaping () -> Void = {}
    ) {
        self.shouldShow = shouldShow
        self.showsAutofill = showsAutofill
        self.pendingStepKeys = Set(pendingStepKeys)
        self.frameDebounceDelay = frameDebounceDelay
        self.revealDelay = revealDelay
        self.onDismiss = onDismiss
        self.onAbandon = onAbandon
    }

    @State private var currentStepIndex = 0
    @State private var micFrame: CGRect = .zero
    @State private var cleanupFrame: CGRect = .zero
    @State private var autofillFrame: CGRect = .zero
    @State private var pulseScale: CGFloat = 1.0
    @State private var stepIconScale: CGFloat = 1.0
    @State private var stepIconRotation: Double = 0
    @State private var framesReady = false
    @State private var fallbackTimer: Timer?

    private func buildSteps() -> [ZTAIOnboardingInternalStep] {
        var steps: [ZTAIOnboardingInternalStep] = []

        if pendingStepKeys.contains("mic"), micFrame != .zero {
            steps.append(ZTAIOnboardingInternalStep(
                stepKey: "mic",
                highlightFrame: micFrame,
                title: ZTAIOnboardingStrings.micTitle,
                body: ZTAIOnboardingStrings.micSubtitle,
                pills: [],
                icon: "mic.fill",
                color: Color(hex: "#0B6BEF")
            ))
        }
        if pendingStepKeys.contains("cleanup"), cleanupFrame != .zero {
            steps.append(ZTAIOnboardingInternalStep(
                stepKey: "cleanup",
                highlightFrame: cleanupFrame,
                title: ZTAIOnboardingStrings.cleanupTitle,
                body: ZTAIOnboardingStrings.cleanupSubtitle,
                pills: [
                    ZTAIOnboardingStrings.cleanupPillCleanUp,
                    ZTAIOnboardingStrings.cleanupPillShort,
                    ZTAIOnboardingStrings.cleanupPillStandard,
                    ZTAIOnboardingStrings.cleanupPillDetailed,
                ],
                icon: "sparkles",
                color: Color(hex: "#0B6BEF")
            ))
        }
        if showsAutofill && pendingStepKeys.contains("autofill") && autofillFrame != .zero {
            steps.append(ZTAIOnboardingInternalStep(
                stepKey: "autofill",
                highlightFrame: autofillFrame,
                title: ZTAIOnboardingStrings.autofillTitle,
                body: ZTAIOnboardingStrings.autofillSubtitle,
                pills: [],
                icon: "plus.circle.fill",
                color: Color(hex: "#0B6BEF")
            ))
        }
        return steps
    }

    public var body: some View {
        GeometryReader { geo in
            if shouldShow && framesReady {
                let steps = buildSteps()
                if !steps.isEmpty {
                    spotlightTour(steps: steps, screenSize: geo.size)
                }
            }
        }
        // Only intercept touches when the tour is actively displayed
        .allowsHitTesting(shouldShow && framesReady)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.3), value: currentStepIndex)
        .onAppear {
            pulseScale = 1.15
            startStepIconPulse()
            // Reset stale frames from any previous screen
            micFrame = .zero
            cleanupFrame = .zero
            autofillFrame = .zero
            framesReady = false
        }
        // Auto-cancelled when the view is removed from the hierarchy
        .task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !framesReady {
                // Buttons never appeared (VC was dismissed or note section hidden) — abandon silently
                // so the user sees the tour again next time
                onAbandon()
            }
        }
        .onDisappear {
            fallbackTimer?.invalidate()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ztAIMicButtonFrame)) { n in
            if let f = n.userInfo?["frame"] as? CGRect {
                micFrame = f
                activateIfReady()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ztAICleanupButtonFrame)) { n in
            if let f = n.userInfo?["frame"] as? CGRect {
                cleanupFrame = f
                activateIfReady()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ztAIAutofillButtonFrame)) { n in
            if let f = n.userInfo?["frame"] as? CGRect { autofillFrame = f }
        }
    }

    private func activateIfReady() {
        guard !framesReady else { return }
        // Small delay so both mic + cleanup frames can arrive together
        DispatchQueue.main.asyncAfter(deadline: .now() + frameDebounceDelay) {
            guard !framesReady, micFrame != .zero || cleanupFrame != .zero else { return }
            // Tell the host VC to scroll AI buttons into the viewport before we show the tour
            NotificationCenter.default.post(name: .ztAIOnboardingDidActivate, object: nil)
            // Wait for host scroll/layout to settle so the most recent button frames are used
            // before the spotlight is shown.
            DispatchQueue.main.asyncAfter(deadline: .now() + revealDelay) {
                framesReady = true
                currentStepIndex = 0
            }
        }
    }

    private func currentVisibleStepKeys() -> [String] {
        buildSteps().map(\.stepKey)
    }

    // MARK: - Spotlight tour

    @ViewBuilder
    private func spotlightTour(steps: [ZTAIOnboardingInternalStep], screenSize: CGSize) -> some View {
        if steps.indices.contains(currentStepIndex) {
            let step = steps[currentStepIndex]
            let isLast = currentStepIndex == steps.count - 1

            ZStack {
                // Dimmed overlay with spotlight cutout
                Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.72)))
                    if step.highlightFrame != .zero {
                        let spotlight = step.highlightFrame.insetBy(dx: -spotlightInset, dy: -spotlightInset)
                        ctx.blendMode = .destinationOut
                        ctx.fill(
                            Path(roundedRect: spotlight, cornerRadius: 16),
                            with: .color(.white)
                        )
                    }
                }
                .compositingGroup()
                .ignoresSafeArea()
                .allowsHitTesting(true)
                .onTapGesture {} // absorb taps on dim

                // Pulsing ring around spotlight
                if step.highlightFrame != .zero {
                    let spotlight = step.highlightFrame.insetBy(dx: -spotlightInset, dy: -spotlightInset)
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(step.color.opacity(0.7), lineWidth: 2.5)
                        .frame(width: spotlight.width, height: spotlight.height)
                        .scaleEffect(pulseScale)
                        .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulseScale)
                        .position(x: spotlight.midX, y: spotlight.midY)
                }

                // Tooltip card
                tooltipCard(
                    step: step,
                    stepIndex: currentStepIndex,
                    stepCount: steps.count,
                    isLast: isLast,
                    screenSize: screenSize
                )
            }
        }
    }

    // MARK: - Tooltip card

    @ViewBuilder
    private func tooltipCard(
        step: ZTAIOnboardingInternalStep,
        stepIndex: Int,
        stepCount: Int,
        isLast: Bool,
        screenSize: CGSize
    ) -> some View {
        let highlight = step.highlightFrame
        // Show card above the button when button is in the bottom half of the screen
        let cardAboveButton = highlight != .zero && highlight.midY > screenSize.height * 0.45

        let hPad: CGFloat = 16
        let cardMaxWidth: CGFloat = min(screenSize.width - hPad * 2, 520)
        let preferredArrowX = cardMaxWidth * 0.78
        let minCardX = hPad
        let maxCardX = max(hPad, screenSize.width - hPad - cardMaxWidth)
        let cardLeadingX = highlight != .zero
            ? max(minCardX, min(highlight.midX - preferredArrowX, maxCardX))
            : (screenSize.width - cardMaxWidth) / 2
        let arrowX = highlight != .zero
            ? max(20, min(highlight.midX - cardLeadingX, cardMaxWidth - 20))
            : preferredArrowX

        ZStack(alignment: .topLeading) {
            if cardAboveButton {
                // Card above button, arrow points DOWN
                VStack(spacing: 0) {
                    Spacer()
                    cardContent(step: step, stepIndex: stepIndex, stepCount: stepCount, isLast: isLast, arrowX: arrowX, arrowDown: true)
                        .frame(width: cardMaxWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, cardLeadingX)
                        .padding(.bottom, max(16, screenSize.height - highlight.minY + 20))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            } else {
                // Card below button, arrow points UP
                let topY = highlight != .zero ? highlight.maxY + 20 : screenSize.height * 0.5
                VStack(spacing: 0) {
                    Spacer().frame(height: topY)
                    cardContent(step: step, stepIndex: stepIndex, stepCount: stepCount, isLast: isLast, arrowX: arrowX, arrowDown: false)
                        .frame(width: cardMaxWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, cardLeadingX)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    // MARK: - Card content

    private let arrowW: CGFloat = 28
    private let arrowH: CGFloat = 14
    private let spotlightInset: CGFloat = 12

    private func startStepIconPulse() {
        stepIconScale = 1.0
        stepIconRotation = -8
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.62).repeatForever(autoreverses: true)) {
                stepIconScale = 1.18
                stepIconRotation = 8
            }
        }
    }

    private func badgeInfoRow(accent: Color) -> some View {
        let isPhone = UIDevice.current.userInterfaceIdiom == .phone

        return VStack(alignment: .leading, spacing: 8) {
            Rectangle()
                .fill(Color(hex: "#E5E7EB"))
                .frame(height: 1)

            HStack(alignment: .top, spacing: 8) {
                ZTAIModelBadge(kind: .appleFoundationModels)
                    .scaleEffect(isPhone ? 0.82 : 0.9)
                    .padding(.top, 1)

                Text(ZTAIOnboardingStrings.appleBadgeNote)
                    .font(isPhone ? .footnote : .caption)
                    .foregroundStyle(Color(hex: "#667085"))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    private func cardContent(
        step: ZTAIOnboardingInternalStep,
        stepIndex: Int,
        stepCount: Int,
        isLast: Bool,
        arrowX: CGFloat,
        arrowDown: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Icon + title + dots
            HStack(spacing: 10) {
                ZStack {
                    step.color.opacity(0.14)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Image(systemName: step.icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(step.color)
                }
                .frame(width: 36, height: 36)
                .scaleEffect(stepIconScale)
                .rotationEffect(.degrees(stepIconRotation))
                .shadow(color: step.color.opacity(0.34), radius: (stepIconScale - 1.0) * 26)

                Text(step.title)
                    .font(.headline)
                    .foregroundStyle(Color(hex: "#10121A"))

                Spacer()

                HStack(spacing: 6) {
                    ForEach(0..<stepCount, id: \.self) { i in
                        Circle()
                            .fill(i == stepIndex ? step.color : Color(hex: "#d1d5db"))
                            .frame(width: i == stepIndex ? 8 : 8, height: i == stepIndex ? 8 : 4)
                            .animation(.easeInOut(duration: 0.2), value: stepIndex)
                    }
                }
            }

            Text(step.body)
                .font(.subheadline)
                .foregroundStyle(Color(hex: "#4b5563"))
                .fixedSize(horizontal: false, vertical: true)

            if !step.pills.isEmpty {
                HStack(spacing: 6) {
                    ForEach(step.pills, id: \.self) { pill in
                        Text(pill)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(step.color)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(step.color.opacity(0.10))
                            .clipShape(Capsule())
                    }
                }
            }
            
            badgeInfoRow(accent: step.color)

            Text(ZTAIOnboardingStrings.outputDisclaimer)
                .font(.caption)
                .foregroundStyle(Color(hex: "#6b7280"))
                .fixedSize(horizontal: false, vertical: true)

            // Skip (left) + Next/Done pill (right)
            HStack {
                if !isLast {
                    Button(ZTAIOnboardingStrings.skip) { onDismiss(currentVisibleStepKeys()) }
                        .font(.subheadline)
                        .foregroundStyle(Color(hex: "#9ca3af"))
                        .buttonStyle(.plain)
                }
                Spacer()
                Button {
                    if isLast {
                        onDismiss(currentVisibleStepKeys())
                    } else {
                        withAnimation(.easeInOut(duration: 0.25)) { currentStepIndex += 1 }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(isLast ? ZTAIOnboardingStrings.done : ZTAIOnboardingStrings.next)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                        if !isLast {
                            Image(systemName: "arrow.right")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(step.color)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        // Extra padding on the arrow side so content doesn't overlap the arrow
        .padding(.top, arrowDown ? 16 : 16 + arrowH)
        .padding(.bottom, arrowDown ? 16 + arrowH : 16)
        .padding(.horizontal, 16)
        .background(
            TooltipBubble(cornerRadius: 18, arrowX: arrowX, arrowW: arrowW, arrowH: arrowH, arrowAtBottom: arrowDown)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.18), radius: 22, x: 0, y: 8)
        )
        .onAppear {
            startStepIconPulse()
        }
        .onChange(of: stepIndex) { _ in
            startStepIconPulse()
        }
    }
}

// MARK: - Unified tooltip bubble shape (card + arrow in one path = one shadow)

private struct TooltipBubble: Shape {
    let cornerRadius: CGFloat
    let arrowX: CGFloat      // center x of arrow within the shape
    let arrowW: CGFloat      // base width of the arrow
    let arrowH: CGFloat      // height of the arrow tip
    let arrowAtBottom: Bool  // true → arrow below card; false → arrow above

    func path(in rect: CGRect) -> Path {
        let cr = min(cornerRadius, rect.height / 2)
        let aw2 = arrowW / 2
        // Card body rect, leaving room for the arrow
        let bodyTop = arrowAtBottom ? rect.minY : rect.minY + arrowH
        let bodyBot = arrowAtBottom ? rect.maxY - arrowH : rect.maxY
        let bodyRect = CGRect(x: rect.minX, y: bodyTop, width: rect.width, height: bodyBot - bodyTop)

        var p = Path()
        // Rounded card body (drawn as individual arcs to avoid import ambiguity)
        p.move(to: CGPoint(x: bodyRect.minX + cr, y: bodyRect.minY))
        p.addLine(to: CGPoint(x: bodyRect.maxX - cr, y: bodyRect.minY))
        p.addArc(center: CGPoint(x: bodyRect.maxX - cr, y: bodyRect.minY + cr),
                 radius: cr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY - cr))
        p.addArc(center: CGPoint(x: bodyRect.maxX - cr, y: bodyRect.maxY - cr),
                 radius: cr, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: bodyRect.minX + cr, y: bodyRect.maxY))
        p.addArc(center: CGPoint(x: bodyRect.minX + cr, y: bodyRect.maxY - cr),
                 radius: cr, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: bodyRect.minX, y: bodyRect.minY + cr))
        p.addArc(center: CGPoint(x: bodyRect.minX + cr, y: bodyRect.minY + cr),
                 radius: cr, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()

        // Arrow triangle
        let ax = max(aw2 + cr, min(arrowX, rect.width - aw2 - cr))
        var arrow = Path()
        if arrowAtBottom {
            arrow.move(to: CGPoint(x: ax - aw2, y: bodyRect.maxY))
            arrow.addLine(to: CGPoint(x: ax, y: rect.maxY))
            arrow.addLine(to: CGPoint(x: ax + aw2, y: bodyRect.maxY))
        } else {
            arrow.move(to: CGPoint(x: ax - aw2, y: bodyRect.minY))
            arrow.addLine(to: CGPoint(x: ax, y: rect.minY))
            arrow.addLine(to: CGPoint(x: ax + aw2, y: bodyRect.minY))
        }
        arrow.closeSubpath()
        p.addPath(arrow)
        return p
    }
}

// MARK: - Previews

#if DEBUG
#Preview("AI Onboarding spotlight") {
    ZStack {
        Color.gray.opacity(0.4).ignoresSafeArea()
        ZTAIOnboardingHostView(shouldShow: true, showsAutofill: true, onDismiss: { _ in print("done") })
    }
}
#endif
