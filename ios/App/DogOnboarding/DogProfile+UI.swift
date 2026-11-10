import DogMonitorCore
import SwiftUI

// Copy and symbols for the "Meet your dog" answers. Kept next to each other so the flow,
// the summary and (later) the profile editor say the same thing.

extension DogLifeStage {
    var title: LocalizedStringKey {
        switch self {
        case .puppy: "Puppy"
        case .adult: "Adult"
        case .senior: "Senior"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .puppy: "Under a year"
        case .adult: "1 to 8 years"
        case .senior: "8 years or older"
        }
    }

    var systemImage: String {
        switch self {
        case .puppy: "sparkles"
        case .adult: "dog.fill"
        case .senior: "heart.fill"
        }
    }
}

extension DogTrait {
    var title: LocalizedStringKey {
        switch self {
        case .barksAtNoises: "Barks at noises"
        case .whines: "Whines or howls"
        case .waitsAtDoor: "Waits by the door"
        case .getsOnFurniture: "Gets on the sofa"
        case .mostlySleeps: "Mostly sleeps"
        }
    }

    var systemImage: String {
        switch self {
        case .barksAtNoises: "speaker.wave.2.fill"
        case .whines: "waveform"
        case .waitsAtDoor: "door.left.hand.open"
        case .getsOnFurniture: "sofa.fill"
        case .mostlySleeps: "moon.zzz.fill"
        }
    }
}

extension DogAlertStyle {
    var title: LocalizedStringKey {
        switch self {
        case .important: "Only what matters"
        case .balanced: "A good balance"
        case .everything: "Everything"
        }
    }

    func subtitle(dogName: String) -> Text {
        switch self {
        case .important: Text("Long barking and whining.")
        case .balanced: Text("Also \(dogName)'s habits, and when things calm down.")
        case .everything: Text("Every time something changes.")
        }
    }

    var systemImage: String {
        switch self {
        case .important: "bell.badge"
        case .balanced: "bell"
        case .everything: "bell.and.waves.left.and.right"
        }
    }
}

extension DogPersonalization.Promise {
    func text(dogName name: String) -> Text {
        switch self {
        case .barking: Text("We'll tell you when \(name) barks for a while.")
        case .whining: Text("Whining and howling come through right away.")
        case .atDoor: Text("And when \(name) waits by the door.")
        case .furniture(needsZone: true): Text("Sofa alerts start once you mark the sofa on the camera.")
        case .furniture(needsZone: false): Text("We'll tell you when \(name) gets on the sofa.")
        case .calmedDown: Text("And when \(name) settles down again.")
        case .quietWhenSleeping: Text("\(name) mostly sleeps, so we'll stay quiet unless something changes.")
        case .puppyProgress: Text("The daily summary shows how \(name) is settling in.")
        case .dailySummary: Text("Every evening, a short summary of \(name)'s day.")
        }
    }

    var systemImage: String {
        switch self {
        case .barking: "speaker.wave.2.fill"
        case .whining: "waveform"
        case .atDoor: "door.left.hand.open"
        case .furniture: "sofa.fill"
        case .calmedDown: "moon.fill"
        case .quietWhenSleeping: "moon.zzz.fill"
        case .puppyProgress: "chart.line.uptrend.xyaxis"
        case .dailySummary: "chart.bar.fill"
        }
    }
}
