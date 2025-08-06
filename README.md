# Argmax SDK Swift Playground

This repository hosts the source code for [Argmax Playground](https://testflight.apple.com/join/Q1cywTJw). It is open-sourced to demonstrate best practices when using the [Argmax SDK](https://argmaxinc.com/#SDK) through an end-to-end example app. Specifically, this app demonstrates Real-time Transcription, File Transcription and Diarized Transcription.


---

## Getting Started

### 1. Clone the Repository

```bash
git clone https://github.com/argmaxinc/argmax-sdk-swift-playground.git
cd argmax-sdk-swift-playground
```

### 2. Open the Project

```bash
open Playground.xcodeproj
```

---


## Configuration

Before running the app, you must complete these setup steps:

### 1. Select Development Team
In Xcode, select your app target and go to **Signing & Capabilities**. Choose your **Development Team** from the dropdown to enable code signing.

### 2. Add Your API Key
In order to unlock the SDK, you will need to provide your API key. You can create one at [https://app.argmaxinc.com](https://app.argmaxinc.com).

#### Option 1: Using Configuration File (Recommended)
1. Copy the template configuration file:
   ```bash
   cp Playground/Resources/config.template.json Playground/Resources/config.json
   ```
2. Edit `Playground/Resources/config.json` and replace `YOUR_API_KEY_HERE` with your actual API key:
   ```json
   {
       "apiKey": "your_actual_api_key_here"
   }
   ```

The `config.json` file is already added to `.gitignore` to prevent accidentally committing your API key.

#### Option 2: Direct Code Modification
Alternatively, you can modify the fallback API key in `DefaultEnvInitializer.swift`:

```swift
return PlainTextAPIKeyProvider(
    apiKey: "your_api_key_here" // Fallback API key
)
```

> **Important**: Never commit your actual API key to version control.
