---
name: project-rules
description: "Mai's own rules for code, checks, and reviews. Read whenever writing, changing, or reviewing code in this repo; where these and mgstack's rules differ, these hold."
---

# Project rules

- Break rules for `break-it` are the ast-grep rules in `references/breaks/`, each with a `fix` that is the break.
- Every `xcodebuild` test run in this repo, `break-it`'s included, passes `-collect-test-diagnostics never`, except when chasing a crash or simulator fault with no known cause (`scripts/snapshot-test.swift --diagnostics`).
- Typesetting math that needs neither UIKit nor SwiftUI goes in `Packages/Typesetting`, a package of its own beside `Packages/Modules`, and its tests there, where `swift test` runs them on the Mac. A test that starts from a `DynamicTypeSize` or a font stays in `FeaturesTests`.
