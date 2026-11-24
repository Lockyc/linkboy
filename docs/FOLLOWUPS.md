---
type: roadmap
links:
  - rel: see-also
    to: CLAUDE.md
    note: architecture and conventions
---
# Follow-ups

Deliberately deferred work. Remove an entry when it ships.

- **Per-feed filtering.** The scope switcher lists categories only, so a single feed can't be read
  on its own. Unlock: list feeds
  from `/v1/feeds` in the scope switcher alongside the categories.
- **Pruning the local cache.** Every pull upserts every changed entry and nothing deletes rows, and
  `Store.entryIDs(matching:)` filters on `status`, which has no index. It waits because a re-take
  over a cache of a few thousand rows takes about a millisecond. Unlock: re-takes slow enough to
  notice; then prune read, unstarred entries older than N days and index `status`.
