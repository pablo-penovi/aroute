# Design

The Zig rewrite of the `aroute` bash script. Terms are defined in [GLOSSARY.md](../GLOSSARY.md).

## Scope

Full parity with the bash script first: the TUI plus `--list`, `--profiles`, `--save NAME`, `--load NAME [--force]` and `--help`. Profiles (`${XDG_CONFIG_HOME:-~/.config}/aroute/profiles/<name>.conf`) and the `aliases` file keep their exact format, so existing files keep working. Anything not covered below behaves as in the script: menu keys (`Esc`, `1`–`5`), colours, the "(modified)" marker, the 1-second refresh on the home screen, the save prompt and overwrite check, the missing-device confirmation on load, the Delete screen staying open, `AROUTE_SHOW_ALL`, and alias substitution.

The binary replaces `~/.local/bin/aroute`. The original script is kept locally as `legacy/aroute.sh` (git-ignored) as the behavioural reference.

## Picking items

The script assigns `a`–`z`, `A`–`Z` to every pickable item. Past 52 items, rows are left without a letter (or, for profiles, not listed at all). When the screen is too short, rows are cut off but keep their letters, so a key can act on something not visible. The rewrite replaces this:

- **Letters only go to rows on screen.** They always start at `a` from the top. `PgUp`/`PgDn` page through the list and the letters are reassigned to the new rows. A page is as many rows as fit on screen, at most 52.
- **One focused column.** Only the focused column has letters, paging and search; the other column is shown dimmed. In the first Connect step focus starts on FROM and `Tab` switches to TO; in the second step focus moves to the other column automatically.
- **Unpickable rows are hidden** from the focused column (e.g. Destinations of the wrong Kind or already connected), so every row on a page has a letter. The unfocused column shows everything.
- **Page indicator**: when there is more than one page, the column header shows it (`FROM  2/3`) and the menu lists `PgUp/PgDn`.

## Search

Available only while picking (Connect, Disconnect, Load, Delete), never on the home screen.

- `/` opens a search field. Every key narrows the focused list live and the letters are reassigned from page 1, as if paging.
- Matching ignores case, matches anywhere in the displayed name (after aliases), and treats several words as all required: `mini out` matches "MiniFuse 1 Main Output L/R".
- On Disconnect it matches either side of a Connection; on Load/Delete it matches the profile name.
- `Enter` stops typing and keeps the filter, so letters pick again; with exactly one match, `Enter` picks it.
- `Esc` while typing cancels the search. With a filter active, `Esc` clears it; a second `Esc` goes back.
- `Backspace` on an empty field closes it. No matches shows `(no matches)`.
- A filter only lives while its column has focus: `Tab` or moving to the next step clears it.

## Screens

- **Home**: both columns and the connection list. When it doesn't fit, `PgUp`/`PgDn` scroll it (no letters, no search).
- **Connect**: the connection list is replaced by a one-line summary ("7 connections") so the columns get the full height.

## Graph state

- The graph is re-read every second on the home screen only. While picking, the list is frozen so letters don't move.
- Just before acting, the graph is re-read and the pick checked; if it is gone, the status shows "✗ … is gone" instead of acting on something else.
- The graph is read and changed through `pw-dump`, `pw-link` and `aconnect` ([ADR 0001](adr/0001-shell-out-to-pipewire-and-alsa-tools.md)). Running the tools is kept separate from turning their output into Endpoints and Connections, which is tested against captured `pw-dump`/`aconnect` output.

## Build

A standard `zig build` project requiring Zig 0.17, with no third-party dependencies (terminal handling is hand-written). Install with:

```sh
zig build -Doptimize=ReleaseSafe -p ~/.local
```
