import SwiftUI

/// Design tokens. Use these instead of raw numbers so every screen shares one rhythm
/// (a 4-pt grid), one set of corner radii and one motion language.
enum DS {
    /// Spacing on a 4-pt grid.
    enum Spacing {
        /// 4: icon to label, tight groups.
        static let xs: CGFloat = 4
        /// 8: within a component.
        static let s: CGFloat = 8
        /// 12: between related rows.
        static let m: CGFloat = 12
        /// 16: card padding, screen margins.
        static let l: CGFloat = 16
        /// 20: wide screen margins.
        static let xl: CGFloat = 20
        /// 24: between groups.
        static let xxl: CGFloat = 24
        /// 32: between major sections.
        static let section: CGFloat = 32
    }

    /// Corner radii. Always draw them with `.continuous` corners.
    enum Radius {
        /// 8: thumbnails, small chips.
        static let small: CGFloat = 8
        /// 12: snapshots and media inside cards.
        static let medium: CGFloat = 12
        /// 20: cards and floating panels.
        static let card: CGFloat = 20
    }

    /// Motion. Springs that settle quickly; nothing bounces for attention.
    enum Motion {
        /// State changes inside a view (a pill turning green, a row appearing).
        static var standard: Animation { .snappy }
        /// Larger layout changes (panels sliding in, cards rearranging).
        static var gentle: Animation { .smooth }

        /// The animation to use, or none when the person turned on Reduce Motion.
        static func animation(_ animation: Animation, reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : animation
        }
    }
}
