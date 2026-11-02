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

- `/` opens a search field on the status line (`/mini out`). Every key narrows the focused list live and the letters are reassigned from page 1, as if paging.
- Matching ignores case, matches anywhere in the displayed name (after aliases), and treats several words as all required: `mini out` matches "MiniFuse 1 Main Output L/R".
- On Disconnect each word can match either side of a Connection; on Load/Delete it matches the profile name.
- `Enter` stops typing and keeps the filter, so letters pick again; with exactly one match, `Enter` picks it.
- `Esc` while typing cancels the search. With a filter active, `Esc` clears it; a second `Esc` goes back.
- `Backspace` on an empty field closes it. No matches shows `(no matches)`.
- A filter only lives while its column has focus: `Tab` or moving to the next step clears it.

## Screens

- **Home**: both columns and the connection list. When it doesn't fit, `PgUp`/`PgDn` scroll it (no letters, no search), and a row at the top and bottom says how many lines are left out (`↑ 4 more (PgUp)`, `↓ 12 more (PgDn)`).
- **Connect**: the connection list is replaced by a one-line summary ("7 connections") so the columns get the full height.

## Graph state

- The graph is re-read every second on the home screen only. While picking, the list is frozen so letters don't move.
- Just before acting, the graph is re-read and the pick checked; if it is gone, the status shows "✗ … is gone" instead of acting on something else.
- PipeWire is changed through `pw-link`, and read through `pw-dump` ([ADR 0001](adr/0001-shell-out-to-pipewire-and-alsa-tools.md)): the TUI keeps one `pw-dump --monitor` running and folds the changes it writes into the graph, the command-line commands run `pw-dump` once ([ADR 0003](adr/0003-read-pipewire-in-the-tui-through-pw-dump-monitor.md)). After Connect, Disconnect and Load, the TUI waits until the monitor shows the Links made or undone, at most a second, before re-reading. If `pw-dump` exits, the graph is unreadable until it runs again; it is started again at most once a second. ALSA MIDI is read and changed through the kernel's sequencer interface on `/dev/snd/seq` directly, with the same rules as `aconnect` ([ADR 0002](adr/0002-talk-to-the-alsa-sequencer-through-the-kernel.md)). Reading is kept separate from turning what was read into Endpoints and Connections, which is tested against captured `pw-dump` and `pw-dump --monitor` output and a sequencer listing.

## Other differences from the script

Besides picking and search above, these are deliberate; everything else matches the script.

- **`--help`** lists `aroute --help` among the commands, and says MIDI between two ALSA Ports is wired through the ALSA sequencer directly, not with `aconnect` ([ADR 0002](adr/0002-talk-to-the-alsa-sequencer-through-the-kernel.md)); the rest of the text is the script's.
- **`--list`** indents every snapshot line (the script indents only the first) and exits 0 when there are no Connections.
- **`--save`** with no Connections saves an empty Profile, says `Saved …` and exits 0 (the script writes it too, but exits 1 without a word). **`--profiles`** also lists names starting with `.`.
- **Fitting the screen**: nothing wraps. Names, the title, the menu and the profiles directory in the PROFILES header are cut with `…` by display width, so wide characters and combining marks line up. A home screen that doesn't fit scrolls (see Screens) instead of ending in `… N more (enlarge the terminal)`, and so does the missing-Devices screen on Load.
- **No limit of 52**: every Connection, Profile and pickable Endpoint can be reached by paging.
- **`Esc` in the second Connect step** goes back to the first step; a second `Esc` goes home.
- **Re-reading the graph**: Save re-reads it just before saving, and `y` on the missing-Devices screen re-reads it and plans the load again. If the graph can't be re-read on the home screen, the last one stays up and the status line says `✗ cannot read the PipeWire graph (is PipeWire running?)` until a read works.
- **After answering a Delete question** the search is cleared, so the status line shows what happened.
- **Prompts** (Save, the overwrite and Delete questions, `/` search) draw their own reverse-video cursor at the end of the field and keep the terminal's cursor hidden.

## Build

A standard `zig build` project requiring Zig 0.17, with no third-party dependencies (terminal handling is hand-written). Install with:

```sh
zig build -Doptimize=safe -p ~/.local
```
