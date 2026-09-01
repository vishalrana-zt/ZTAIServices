# ZTAIServiceEngine

Swift Package for the reusable Core engines from `ZTSpeechToText`.

## Requirements

- Xcode 16+
- iOS 16.0+

## Package

This repository now exposes one library product:

- `ZTAIServiceEngine`

It maps to:

- `ZTSpeechToText/Core`

## Add Dependency

In another project `Package.swift`:

```swift
.package(url: "https://github.com/<your-org>/ZTSpeechToText.git", branch: "main")
```

Then add the product to your target dependencies:

```swift
.product(name: "ZTAIServiceEngine", package: "ZTSpeechToText")
```

## Notes

- The package intentionally includes only `Core` sources (no app/UI layer).
- Some features rely on Apple frameworks such as `Speech`, `Vision`, `AVFoundation`, and `FoundationModels`.
