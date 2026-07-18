//
//  BuildInfo.swift
//  Lyklabord
//
//  Build-time stamp of the engine git commit, embedded into session manifests
//  (see RecordingStore.makeManifest) so the Mac-side aggregate can group
//  real-typing rates BY ENGINE BUILD — the anti-overcorrection instrument.
//
//  ┌─ GENERATED — DO NOT EDIT BY HAND ───────────────────────────────────────┐
//  │ The value below is rewritten on every build by the `Stamp engine commit` │
//  │ preBuildScript declared in project.yml (Lyklabord target). The           │
//  │ script runs `git rev-parse --short HEAD` before the Compile Sources      │
//  │ phase and overwrites this file IN PLACE only when the value changed, so  │
//  │ it neither churns git on every build nor triggers needless recompiles.   │
//  │                                                                          │
//  │ Because the stamp is taken at BUILD time, a build made from a clean tree │
//  │ carries the commit it was built from; a build with uncommitted changes   │
//  │ carries the last commit plus a `+dirty` marker (appended by the script). │
//  │ The committed value here is a placeholder kept in sync with HEAD so a    │
//  │ fresh checkout compiles and `git status` stays clean until HEAD moves.   │
//  └──────────────────────────────────────────────────────────────────────────┘
//

enum BuildInfo {
    /// Short git commit of the engine/app source this binary was built from.
    /// Rewritten by the project.yml preBuildScript; "unknown" if git was
    /// unavailable at build time (e.g. a source tarball with no .git).
    static let engineCommit = "dd4afc2+dirty"
}
