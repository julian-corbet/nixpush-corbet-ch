# experiments

Throwaway trials: spikes, one-off scripts, things tried and abandoned or not yet worth
writing up. Nothing here is guaranteed to work, be maintained, or survive the next cleanup
pass.

If something in here turns out to matter, distill the actual finding into
[`../studies/`](../studies/README.md) and let the experiment stay disposable (or delete it).

See the main [README](../README.md) for the project itself.

## Open questions worth an experiment, not yet run

Recorded here so they aren't lost, even though nothing has been measured yet — nixpush v1 is
a fresh scaffold; every claim below is reasoned, not tested.

- **Provider startup overhead at scale.** Each `nixpush send` execs a fresh provider process
  (a `curl`+`jq` script, for ntfy). For a single alert this is noise; for a caller firing many
  sends in a tight loop (a batch job reporting per-item failures, say), process-spawn +
  interpreter-startup overhead per send has not been measured against, e.g., a provider
  written as a compiled binary instead of a shell script. Unmeasured; no evidence yet that it
  matters for nixpush's actual target caller shape (occasional alerts, not bulk notification).
- **`doctor`'s false-FAILED rate for real community providers.** `check-settings` is optional
  in the contract (see `docs/faq.md`); once real third-party providers exist, worth checking
  how many actually implement it versus how often `doctor` reports a spurious FAILED for one
  that doesn't.
