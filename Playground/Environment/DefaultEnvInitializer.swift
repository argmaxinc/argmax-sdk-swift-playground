import Foundation
import Argmax
#if canImport(ArgmaxSecrets)
import ArgmaxSecrets
#endif

/// A default implementation of `PlaygroundEnvInitializer` suitable for public and development builds.
///
/// `DefaultEnvInitializer` provides a basic environment setup with no-operation analytics logging
/// and placeholder API key providers. This implementation is designed for external developers
/// who want to get started quickly with the Playground application without complex setup.
///
/// ## API Key Configuration
///
/// To get started, you'll need to provide your own API keys by either:
/// 1. **Simple approach**: Modify the `PlainTextAPIKeyProvider` values below with your actual keys
/// 2. **Secure approach**: Consider using `ObfuscatedKeyProvider` for better protection
/// 3. **Production approach**: Retrieve keys from a secure backend API
///
/// ### About ObfuscatedKeyProvider
///
/// The `ObfuscatedKeyProvider` offers light tamper-resistance by XOR-encoding API keys in the binary.
/// While this provides some protection against casual inspection, it should **not** be considered
/// cryptographically secure. The obfuscation can be easily reversed by anyone with binary analysis tools.
///
/// **Limitations of obfuscation:**
/// - Only protects against very basic tampering attempts
/// - Keys can be extracted with reverse engineering tools
/// - Not suitable for highly sensitive applications
/// - Provides no protection against runtime memory inspection
///
/// **Production recommendations:**
/// - Retrieve API keys from a secure backend service at runtime
/// - Use certificate pinning for API communications
/// - Implement proper authentication flows instead of embedding keys
/// - Consider using secure enclaves or keychain services for local storage
///
/// ## Analytics Configuration
///
/// This implementation uses `NoOpAnalyticsLogger` which discards all analytics events.
/// For production applications, consider integrating with analytics services like:
/// - Firebase Analytics
/// - Mixpanel
/// - Custom analytics endpoints
///
/// ## Usage Example
///
/// ```swift
/// let envInitializer = DefaultEnvInitializer()
/// envInitializer.initialize()
/// 
/// let coordinator = ArgmaxSDKCoordinator(keyProvider: envInitializer.createAPIKeyProvider())
/// let logger = envInitializer.createAnalyticsLogger()
/// ```
public class DefaultEnvInitializer: PlaygroundEnvInitializer {

    public func createAPIKeyProvider() -> APIKeyProvider {
        return PlainTextAPIKeyProvider(
            apiKey: "", // TODO: Add your Argmax Pro API key here (required)
            huggingFaceToken: "" // TODO: Add your Hugging Face token here (optional)
        )
    }

    public func createAnalyticsLogger() -> AnalyticsLogger {
        return NoOpAnalyticsLogger()
    }
}

/// A simple API key provider that stores keys as plain text.
///
/// This provider is suitable for development and testing but should not be used
/// in production applications. For better security, consider using `ObfuscatedKeyProvider`
/// or retrieving keys from a secure backend service.
private class PlainTextAPIKeyProvider: APIKeyProvider {
    public let apiKey: String?
    public let huggingFaceToken: String?
    
    init(apiKey: String, huggingFaceToken: String? = nil) {
        self.apiKey = apiKey.isEmpty ? nil : apiKey
        // huggingFaceToken is optional
        if let huggingFaceToken {
            self.huggingFaceToken = huggingFaceToken.isEmpty ? nil : huggingFaceToken
        } else {
            self.huggingFaceToken = nil
        }
    }
}
