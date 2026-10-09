// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. MIT; see LICENSE.txt.
// Focused extraction from Ghostty Helpers/Backport.swift at 7ec9e26a29399b30ef78f06985fc75045b3cecb6.
import SwiftUI

struct Backport<Content> { let content: Content }
extension View { var backport: Backport<Self> { Backport(content: self) } }
extension Backport where Content: View {
    func pointerStyle(_ style: BackportPointerStyle?) -> some View {
        if #available(macOS 15, *) { return content.pointerStyle(style?.official) }
        else { return content }
    }
}
enum BackportPointerStyle {
    case resizeUpDown, resizeLeftRight
    @available(macOS 15, *)
    var official: PointerStyle {
        switch self {
        case .resizeUpDown: return .rowResize
        case .resizeLeftRight: return .columnResize
        }
    }
}
