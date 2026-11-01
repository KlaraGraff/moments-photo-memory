import Foundation

// Some macOS 27.2 seed builds lack Foundation's `Date.>=` and `Date.<=`
// (an app built with the 27.2 SDK then jumps to address 0). Compare with
// `<` only, which every macOS has.
extension Date {
    func isOnOrAfter(_ other: Date) -> Bool { !(self < other) }
    func isOnOrBefore(_ other: Date) -> Bool { !(other < self) }
}
