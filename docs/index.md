# docs

Supporting material that doesn't belong inline in the README or CONTRIBUTING.md:

- [`faq.md`](faq.md) — answers to questions the code comments point back to by name (grep for
  "see docs/faq.md" in `modules/` and `pkgs/` — every hit has a matching heading here).
- [`rationale.md`](rationale.md) — numbered design decisions with their reasoning, referenced
  by number from code comments and from the README's "Design decision" section.

For the provider contract itself (stdin/env/exit-code), see [`../CONTRIBUTING.md`](../CONTRIBUTING.md)
— it's the canonical copy; nothing here duplicates it.

For the project's own open questions and past write-ups, see [`../experiments/`](../experiments/README.md)
and [`../studies/`](../studies/README.md).
