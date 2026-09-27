# Native UI performance investigation — 2026-09-27

Observed on the installed App with 54 records, capture paused.

The old implementation decoded ImageIO thumbnails synchronously from SwiftUI body evaluation. Its custom Layout called sizeThatFits for every card twice (measurement and placement); an enclosing LazyVStack only made sections lazy. Conditional branches recreated the preview tree on detail open/close. Each two-second snapshot unconditionally published topics, records, status and events.

Two 15-second `sample` captures around detail switching were inspected. Before the fix, main-thread stacks included WaterfallLayout.positions, CGImageSourceCreateThumbnailAtIndex and repeated Note.dateLabel parsing. None of those calls appeared in the post-fix main-thread sample. Sampling is diagnostic evidence, not a controlled frame-rate or latency benchmark; no percentage speedup is claimed.

Changes:
- LazyVStack columns materialize visible cards and a prefetch area; no eager measurement of every card.
- Keep one preview hierarchy when opening/closing the detail pane.
- Decode screenshots on a serial background actor; thumbnail/detail/original caches have independent memory budgets.
- Decode snapshots outside the UI actor and publish only changed fields.
- Bounded timestamp and display-label caches.

Verification:
- Native compile and ad-hoc signature verification passed.
- Native context/grouping/filter tests passed.
- Performance tests: 200 unchanged snapshot applications cause no extra record publications; a heartbeat updates status only; changed records still publish; ImageIO asserts it is off the main thread; warm requests reuse the decoded object; preview loading retains the thumbnail cache; missing and unsafe paths return nil.
- Installed App: open/close detail by clicking the same card, scroll to later cards, show a full image, and switch to hour grouping all verified.
