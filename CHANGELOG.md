# Changelog

## [0.1.0] — 2026-04-30

Initial Orbit Dictation release. Forked from [Whispur](https://github.com/sophiie-ai/whispur) at v0.13.4.

### Branding

* Application name: Orbit Dictation
* Bundle identifier: `team.yourorbit.OrbitDictation`
* App icon, menu bar glyph, and Settings/About surfaces rebranded for Orbit
* Application Support directory and Keychain service rescoped under the Orbit identifier so installations do not collide with upstream Whispur

### Cleanup prompt

* New default cleanup prompt: strict text-post-processor contract that refuses to act on the transcript content even when it reads like an instruction
* Adds proper-noun preservation, sentence-boundary inference, English-first language scope, sharper number-normalization rules, hallucination guard for repeated-sentence STT artefacts, list rule that requires three or more items, and explicit "no Markdown unless dictated" rule

### Distribution

* Sparkle update channel points to GitHub Releases on this fork
* Distributed from the Orbit Downloads page on get.yourorbit.team
