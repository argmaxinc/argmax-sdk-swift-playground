# Argmax SDK Swift Playground

This repository hosts the source code for [Argmax Playground for iOS and macOS](https://testflight.apple.com/join/Q1cywTJw).

It is open-sourced to demonstrate best practices when building with [Argmax Pro SDK Swift](https://app.argmaxinc.com/docs) through an end-to-end example app. Specifically, this app demonstrates [Real-time Transcription](https://app.argmaxinc.com/docs/examples/custom-vocabulary) with [Speakers](https://app.argmaxinc.com/docs/examples/real-time-transcription#with-speakers) and [Custom Vocabulary](https://app.argmaxinc.com/docs/examples/custom-vocabulary).


---

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

> **Do not commit your API key.**.

---


### 4. Select Development Team
In Xcode, select your app target and go to **Signing & Capabilities**. Choose your **Development Team** from the dropdown to enable code signing.
