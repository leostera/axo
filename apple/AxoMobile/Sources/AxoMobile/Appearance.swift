import SwiftUI

/// System means no override: follow trait changes while the app is running.
enum AppAppearance: String, CaseIterable, Identifiable {
  case system, light, dark

  var id: Self { self }
  var title: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }
  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}

enum AppAccentColor: String, CaseIterable, Identifiable {
  case white, blue, mint, orange, pink

  var id: Self { self }

  var title: String {
    switch self {
    case .white: "Default"
    case .blue: "Blue"
    case .mint: "Mint"
    case .orange: "Orange"
    case .pink: "Pink"
    }
  }

  var color: Color {
    switch self {
    case .white: .primary
    case .blue: .blue
    case .mint: .mint
    case .orange: .orange
    case .pink: .pink
    }
  }
}

/// Semantic colors resolve in the view's selected appearance, including sheets.
enum ChatColors {
  static let background = Color(uiColor: .systemBackground)
  static let surface = Color(uiColor: .secondarySystemBackground)
  static let inset = Color(uiColor: .tertiarySystemFill)
  static let border = Color.primary.opacity(0.14)
  static let disabledControl = Color(uiColor: .systemGray5)
}
