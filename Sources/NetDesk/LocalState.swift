import SwiftUI

/// The macOS 27 SDK declares `@State` as a macro whose plugin ships only with Xcode.
/// This alias points at the classic property wrapper so the app builds with the Command Line Tools alone.
typealias LocalState<Value> = SwiftUICore.State<Value>
