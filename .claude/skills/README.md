# Vendored agent skills

Third-party agent skills used by the agents building this app (see CLAUDE.md → "Design and UI quality").
All are MIT-licensed; each folder keeps its original LICENSE. Source list: https://github.com/twostraws/Swift-Agent-Skills

| Skill | Use for | Source |
|---|---|---|
| `swiftui-pro` | Reviewing/writing SwiftUI: modern API, data flow, HIG, accessibility, performance | Paul Hudson, twostraws/SwiftUI-Agent-Skill |
| `swiftui-design-principles` | Spacing grid, typography, color restraint, native components | arjitj2/swiftui-design-principles |
| `swiftui-ui-patterns` | Component patterns (lists, sheets, navigation, haptics, async state) | Thomas Ricouard, Dimillian/Skills |
| `swiftui-liquid-glass` | iOS 26 Liquid Glass adoption with fallbacks | Thomas Ricouard, Dimillian/Skills |
| `ios-accessibility` | VoiceOver, Dynamic Type, Voice Control, testing | Daniel Devesa, dadederk/iOS-Accessibility-Agent-Skill |
| `writing-for-interfaces` | UI copy: voice, errors, empty states, buttons | Andrew Gleave, andrewgleave/skills |
| `swift-concurrency-pro` | Swift 6 concurrency review | Paul Hudson, twostraws/Swift-Concurrency-Agent-Skill |
| `security-audit` | Multi-phase security audit with verified, machine-readable findings (backend + core) | Cloudflare, cloudflare/security-audit-skill |
| `ig-reel`, `ig-caption`, `ig-human`, `ig-plan`, `ig-carousel`, `ig-story`, `ig-repurpose`, `ig-audit`, `ig-profile`, `ig-viral`, `ig-comment`, `ig-reply`, `ig-dm` | Instagram content for marketing (reel scripts, hooks, captions, weekly plans). They write content only; nothing posts. Their voice file is `marketing/voice.md` (use it wherever a skill says `~/.claude/instagram/voice.md`). | Jake Schincariol, Jakeschincariol/instagram-agent-skill |

Note: some skills assume iOS 26/27 and newer Xcode. This app targets iOS 17: gate newer APIs with
`#available` (and `#if compiler(>=6.2)` for iOS 26 SDK symbols) and keep a fallback.
