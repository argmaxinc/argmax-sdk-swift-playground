# Argmax SDK Swift Playground

This repository hosts the source code for [Argmax Playground for iOS and macOS](https://testflight.apple.com/join/Q1cywTJw).

It is open-sourced to demonstrate best practices when building with [Argmax Pro SDK Swift](https://app.argmaxinc.com/docs) through an end-to-end example app. Specifically, this app demonstrates [Real-time Transcription](https://app.argmaxinc.com/docs/examples/custom-vocabulary) with [Speakers](https://app.argmaxinc.com/docs/examples/real-time-transcription#with-speakers) and [Custom Vocabulary](https://app.argmaxinc.com/docs/examples/custom-vocabulary).

## What this demonstrates

- **Real-time transcription** — streaming microphone input through `WhisperKitPro`,
  including a Live Activity / Dynamic Island integration on iOS and macOS system-audio
  capture via `AudioProcessTapper`.
- **File transcription** — full-file transcribe pipeline with progress reporting,
  word-level timing, and resumable model downloads through `ModelStore`.
- **Speaker diarization** — both Pyannote and Sortformer
  via `SpeakerKitPro`.
- **Custom vocabulary** — Keyword boosting through the `WhisperKitPro`
  custom vocabulary models (canary and parakeet variants).
- **Session history & export** — persisted session records with SRT/VTT/JSON export.

## Getting Started

### 1. Get Argmax credentials

This project requires a secret token and an API key from that you may generate from your [Argmax Dashboard](https://app.argmaxinc.com).


### 2. Follow Installation instructions

Please see [Installation](https://app.argmaxinc.com/docs/guides/upgrading-to-pro-sdk) for details

### 3. Set Argmax credentials

Then, update `DefaultEnvInitializer.swift` with your Argmax API key

```swift
class DefaultEnvInitializer: PlaygroundEnvInitializer {
    public func createAPIKeyProvider() -> APIKeyProvider {
        return PlainTextAPIKeyProvider(
            apiKey: "", // TODO: Add your Argmax SDK API key
        )
    }
}
```

> **Do not commit your API key.** For shipping apps, prefer
> `ObfuscatedKeyProvider` or fetch the key from a backend you control.

---


### 4. Select Development Team
In Xcode, select your app target and go to **Signing & Capabilities**. Choose your **Development Team** from the dropdown to enable code signing.

## Requirements

- Xcode 16 or later
- iOS 18+ / macOS 15+
- An Argmax SDK API key
