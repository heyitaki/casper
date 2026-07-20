# Sidebar footer trimmed to a settings entry point

Register index: [`docs/casper-fork.md`](../casper-fork.md).

- Files (upstream files modified):
  - `Sources/ContentView.swift` (`SidebarFooter` / `SidebarFooterButtons` / `SidebarHelpMenuButton` reduced to a single gear button with a two-item popover; `VerticalTabsSidebar` drops `onSendFeedback` parameter)
  - `cmuxTests/InactivePaneFirstClickFocusTests.swift` (drops `onSendFeedback` from `VerticalTabsSidebar` initializer)
  - `cmuxUITests/SidebarHelpMenuUITests.swift` (removed `testHelpMenuCheckForUpdatesTriggersSidebarUpdatePill` / `testHelpMenuSendFeedbackOpensComposerSheet`; `testCmdOptionFWorksWithHiddenSidebar` now polls `SidebarSettingsMenuButton`/`Settings` instead of `SidebarHelpMenuButton`/`Help`)
- Summary:
  - Removes the "Development" label and `UpdatePill` from the sidebar footer; the only remaining footer element is the gear button.
  - Replaces the question-mark help button with a gear-shape settings button (`accessibilityIdentifier: "SidebarSettingsMenuButton"`); the popover keeps only "Keyboard Shortcuts" and "Import Browser Data…". All other entries (Welcome, Send Feedback, Docs, Changelog, GitHub, GitHub Issues, Discord, Check for Updates) are dropped from this surface — the Cmd+Opt+F feedback shortcut and command-palette Check-for-Updates still work.
- Deletion condition:
  - Delete if upstream cmux replaces the help button with an equivalent compact settings affordance.
