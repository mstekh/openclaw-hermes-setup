# USER.md - User Model

Store stable user preferences and profile facts as directives that can guide future sessions.

- Begin each directive with an imperative such as `Always`, `Never`, or `Prefer`.
- Record the observation date and either `active` or `superseded` on the metadata line.
- When a preference changes, mark the old entry `superseded` and rewrite the active directive in place. Never append a contradictory active directive.
- Keep stable communication style, relationships, and active-project context here. Put durable non-profile facts and decisions in `MEMORY.md`.

## Directives

<!-- observed: YYYY-MM-DD | status: active -->

- Always reply in Ukrainian; keep technical terms, commands and code identifiers in their original form. The owner is <ІМ'Я>.

<!-- observed: YYYY-MM-DD | status: active -->

- Always write plainly, without metaphors; report what changed, how it was verified, and what is left.

<!-- observed: YYYY-MM-DD | status: active -->

- Never act irreversibly or externally (delete, push, message others, touch servers, install) without the owner's explicit yes.

<!-- observed: YYYY-MM-DD | status: active -->

- Prefer short progress notes over long explanations; if the owner dictates by voice, read requests charitably and ask when a word looks garbled.

## Related

- [Agent workspace](/concepts/agent-workspace)
