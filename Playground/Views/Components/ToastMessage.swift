import Foundation
import SwiftUI

/// A simple toast message view component for displaying temporary status messages or notifications.
/// This view provides consistent styling for brief informational messages throughout the application.
struct ToastMessage: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.subheadline)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
    }
}
