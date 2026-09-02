import SwiftUI
import UIKit

public struct LiveAwareTextView: UIViewRepresentable {
    @Binding public var text: String
    public let shouldAutoScrollLiveInsertion: Bool
    public let shouldShowLiveCaret: Bool
    public let onEditingChanged: (Bool) -> Void

    public init(
        text: Binding<String>,
        shouldAutoScrollLiveInsertion: Bool,
        shouldShowLiveCaret: Bool,
        onEditingChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self._text = text
        self.shouldAutoScrollLiveInsertion = shouldAutoScrollLiveInsertion
        self.shouldShowLiveCaret = shouldShowLiveCaret
        self.onEditingChanged = onEditingChanged
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.textColor = .label
        textView.tintColor = .systemBlue
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.inputAccessoryView = context.coordinator.makeKeyboardAccessoryToolbar()
        textView.text = text
        context.coordinator.attach(textView: textView)
        return textView
    }

    public func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateLiveMode(shouldAutoScrollLiveInsertion)
        context.coordinator.updateShouldShowLiveCaret(shouldShowLiveCaret)
        context.coordinator.updateBaseText(text)

        let displayText = context.coordinator.currentDisplayText()
        if uiView.text != displayText {
            context.coordinator.applyProgrammaticText(displayText, on: uiView)
        }
        uiView.font = .preferredFont(forTextStyle: .body)
        uiView.textColor = .label
        uiView.tintColor = .systemBlue

        if shouldAutoScrollLiveInsertion {
            context.coordinator.scrollToEnd(uiView)
        }
    }

    public final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LiveAwareTextView
        private weak var textView: UITextView?
        private var caretTimer: Timer?
        private var liveCaretVisible = false
        private var isProgrammaticTextChange = false
        private var baseText = ""
        private var isLiveMode = false
        private var shouldShowLiveCaret = false
        private let liveCaretCharacter = "▌"

        init(_ parent: LiveAwareTextView) {
            self.parent = parent
        }

        deinit {
            caretTimer?.invalidate()
        }

        func attach(textView: UITextView) {
            self.textView = textView
        }

        func makeKeyboardAccessoryToolbar() -> UIToolbar {
            let toolbar = UIToolbar()
            toolbar.sizeToFit()
            let flexible = UIBarButtonItem(systemItem: .flexibleSpace)
            let done = UIBarButtonItem(
                title: "Done",
                style: .plain,
                target: self,
                action: #selector(doneButtonTapped)
            )
            toolbar.items = [flexible, done]
            return toolbar
        }

        @objc
        private func doneButtonTapped() {
            textView?.resignFirstResponder()
        }

        func updateBaseText(_ text: String) {
            baseText = text
        }

        func updateLiveMode(_ enabled: Bool) {
            guard isLiveMode != enabled else { return }
            isLiveMode = enabled
            if enabled {
                startCaretTimer()
            } else {
                stopCaretTimer()
                if let textView {
                    applyProgrammaticText(baseText, on: textView)
                }
            }
        }

        func updateShouldShowLiveCaret(_ enabled: Bool) {
            shouldShowLiveCaret = enabled
            if let textView {
                applyProgrammaticText(currentDisplayText(), on: textView)
                if isLiveMode {
                    scrollToEnd(textView)
                }
            }
        }

        func currentDisplayText() -> String {
            guard isLiveMode else { return baseText }
            guard shouldShowLiveCaret else { return baseText }
            return liveCaretVisible ? baseText + liveCaretCharacter : baseText
        }

        func applyProgrammaticText(_ value: String, on textView: UITextView) {
            isProgrammaticTextChange = true
            if isLiveMode, shouldShowLiveCaret, value.hasSuffix(liveCaretCharacter) {
                let bodyText = String(value.dropLast(liveCaretCharacter.count))
                let bodyAttributes: [NSAttributedString.Key: Any] = [
                    .font: textView.font ?? UIFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: UIColor.label
                ]
                let caretAttributes: [NSAttributedString.Key: Any] = [
                    .font: textView.font ?? UIFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: UIColor.systemRed
                ]
                let rendered = NSMutableAttributedString(string: bodyText, attributes: bodyAttributes)
                rendered.append(NSAttributedString(string: liveCaretCharacter, attributes: caretAttributes))
                textView.attributedText = rendered
            } else {
                textView.attributedText = nil
                textView.text = value
                textView.textColor = .label
            }
            isProgrammaticTextChange = false
        }

        func scrollToEnd(_ textView: UITextView) {
            let end = (textView.text as NSString).length
            textView.selectedRange = NSRange(location: end, length: 0)
            textView.layoutIfNeeded()
            if end > 0 {
                textView.scrollRangeToVisible(NSRange(location: end - 1, length: 1))
            } else {
                textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
            let safeOffset = max(0, textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
            textView.setContentOffset(CGPoint(x: 0, y: safeOffset), animated: false)
        }

        private func startCaretTimer() {
            caretTimer?.invalidate()
            liveCaretVisible = true
            caretTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
                guard let self, self.isLiveMode, let textView else { return }
                self.liveCaretVisible.toggle()
                self.applyProgrammaticText(self.currentDisplayText(), on: textView)
                self.scrollToEnd(textView)
            }
            if let caretTimer {
                RunLoop.main.add(caretTimer, forMode: .common)
            }
        }

        private func stopCaretTimer() {
            caretTimer?.invalidate()
            caretTimer = nil
            liveCaretVisible = false
        }

        public func textViewDidChange(_ textView: UITextView) {
            guard !isProgrammaticTextChange else { return }
            parent.text = textView.text
        }

        public func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onEditingChanged(true)
        }

        public func textViewDidEndEditing(_ textView: UITextView) {
            parent.onEditingChanged(false)
        }
    }
}
