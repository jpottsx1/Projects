import SwiftUI

extension View {
    /// A sheet's smallest size on a Mac, where sheets are only as big as
    /// their content. On an iPhone or iPad the sheet is sized by the
    /// screen, and a minimum wider than the phone pushes its edges off it.
    func sheetSize(minWidth: CGFloat, minHeight: CGFloat) -> some View {
        #if os(macOS)
        frame(minWidth: minWidth, minHeight: minHeight)
        #else
        self
        #endif
    }
}
