# articles/ — drafts, not the published posts

**The published posts live in `web/src/content/blog/`. That directory is the source of truth.**

These files are the drafts each post started from. Several have since diverged from what was
published, and 14 still describe setup paths that never worked — "any Postgres", Neon, local
Docker, `psql < schema.sql`, `HEALTHKIT_USER_ID` as "any string" (measured 2026-09-12, register
D353). The published copies were corrected or carry a setup notice; these drafts were not.

**Do not copy a draft from here over a published post**, and do not publish a new post from a
draft without checking it against `docs/SETUP.md`. Supabase is the only supported backend.
