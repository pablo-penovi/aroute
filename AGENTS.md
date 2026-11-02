# aroute

A two-column patchbay TUI for PipeWire audio and ALSA/PipeWire MIDI, written in Zig. A rewrite of the `aroute` bash script; see `docs/design.md`.

## Pull requests

Before opening a PR, run `zig build coverage` (kcov; totals in `coverage/merged/kcov-merged/cobertura.xml`) on the branch and on `main` (e.g. in a `git worktree`). In the PR's Evidence, report line coverage `main` → branch, overall and for each changed file, and every uncovered line with why. Zig only compiles what some test reaches, so code no test calls is missing from the report rather than uncovered: a new or changed function absent from it is untested.

## Agent skills

### Issue tracker

Issues and specs live in GitHub Issues on `pablo-penovi/aroute`, managed with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five default labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
