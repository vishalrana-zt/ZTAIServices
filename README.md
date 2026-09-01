# ZTAIServices

Swift Package for the reusable Core engines from `ZTSpeechToText`.

## Requirements

- Xcode 16+
- iOS 16.0+

## Package

This repository now exposes one library product:

- `ZTAIServices`

It maps to:

- `ZTSpeechToText/Core`

## Add Dependency

In another project `Package.swift`:

```swift
.package(
    name: "ZTAIServices",
    url: "https://github.com/vishalrana-zt/ZTAIServices.git",
    branch: "spm-package"
)
```

Then add the product to your target dependencies:

```swift
.product(name: "ZTAIServices", package: "ZTAIServices")
```

For local development:

```swift
.package(path: "../ZTSpeechToText")
```

## Notes

- The package intentionally includes only `Core` sources (no app/UI layer).
- Some features rely on Apple frameworks such as `Speech`, `Vision`, `AVFoundation`, and `FoundationModels`.
