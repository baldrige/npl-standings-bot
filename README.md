# NPL weekly standings bot

Replaces the Monday routine of pasting Scoresheet's fixed-width standings into
`standings.csv`, running the stats script, and posting five images to Slack.

Every Monday the workflow polls the
[BL National Pastime summary page](https://www.scoresheet.com/FOR_WWW/BL_National_Pastime.htm),
waits until the page's own "through" date advances, then scrapes, renders, and
posts all five images as a single Slack message.

## How it works

```
cron (every 20 min, Monday 11:00-22:00 UTC)
  └─ gate job: curl page -> <h1> date -> compare to state/last_posted.txt
       ├─ unchanged -> stop (the common case; ~20s, no toolchain installed)
       └─ newer ↓
          report job:
            tests/test_parser.R      regression tests against a saved fixture
            R/scrape_standings.R  -> standings.csv + out/page_date.txt
            R/npl_league_stats.R  -> out/*.png  (5 images)
            R/post_to_slack.R     -> one Slack message, five attachments
            commit standings.csv + state/last_posted.txt
```

The gate runs before any toolchain is installed, which is what makes 20-minute
polling affordable. Because it is idempotent, the workflow needs no DST guard —
it covers a wide UTC window and lets the page's date decide when to fire.

## Layout

| Path | Purpose |
| --- | --- |
| `R/scrape_standings.R` | Page → `standings.csv` (43 cols) + `out/page_date.txt` |
| `R/npl_league_stats.R` | `standings.csv` → the five PNGs in `out/` |
| `R/post_to_slack.R` | Uploads all five as one Slack message |
| `data/teamnos.csv` | Team names, mascots, divisions, leagues, logo URLs |
| `state/last_posted.txt` | The last page date posted. This is the idempotency key. |
| `tests/test_parser.R` | Parser regression tests |
| `tests/fixtures/` | A saved page plus the hand-pasted CSV it must reproduce |

### Why `standings.csv` keeps its duplicate headers

`R`, `H`, `BA`, `BB`, and `K` each appear twice — once for pitching, once for
batting. `readr` repairs those to `R...12` / `R...20` and so on, and
`npl_league_stats.R` indexes columns by those repaired names. The scraper writes
the header row verbatim so the file stays byte-compatible with the hand-pasted
version: the stats script needed no column changes, and you can still paste into
it by hand if the scraper ever breaks.

## Running it locally

```sh
Rscript tests/test_parser.R                              # regression tests
Rscript R/scrape_standings.R                             # live fetch
Rscript R/scrape_standings.R tests/fixtures/page_2026-07-26.html   # or a fixture
Rscript R/npl_league_stats.R                             # writes out/*.png
NPL_DRY_RUN=true Rscript R/post_to_slack.R               # validate, post nothing
```

`npl_league_stats.R` falls back to yesterday's date if `out/page_date.txt` is
absent, so it still works standalone.

## Slack setup

1. Create a Slack app, add the bot scopes **`files:write`** and **`chat:write`**,
   install it to the workspace, and copy the `xoxb-` token.
2. **Invite the bot to the channel**: `/invite @yourbot`. Without this Slack
   returns `not_in_channel` and nothing uploads — it is the most common failure.
3. Get the channel ID from *View channel details* (bottom of the dialog).
4. In this repo: add secret **`SLACK_BOT_TOKEN`** and variable
   **`SLACK_CHANNEL_ID`**.

Slack retired `files.upload`, so this uses the v2 flow:
`files.getUploadURLExternal` → POST bytes → `files.completeUploadExternal` with
all five file IDs in **one** call, which is what makes them a single message.

## Rollout

1. **Fidelity check.** Run the workflow manually with `force=true` and
   `dry_run=true`. Download the artifact and compare against the macOS-rendered
   images. Nothing reaches Slack.
2. **Live test.** `force=true`, `dry_run=false`, pointed at a scratch channel.
3. **Arm it.** Leave `state/last_posted.txt` at the last week you posted by hand
   and let the Monday cron take over.

### If the dry-run images don't match

`gt_theme_nytimes()` fetches Source Sans Pro and Libre Franklin from Google
Fonts at screenshot time, so the table titles, column labels, and body cells are
identical across platforms. Only three things resolve against the OS instead:
the gt **subtitle**, the **division row-group labels**, and text in `rsra.png`
(drawn by a graphics device, not Chrome).

To pin those too, add `opt_table_font(font = google_font("Source Sans Pro"))` to
each table and `base_family = "Source Sans Pro"` to the plot's `theme_minimal()`.
That makes both platforms identical by construction rather than by coincidence,
and also fixes the subtitle/body font mismatch that exists today. The workflow
already installs the fonts locally — note Google ships the successor family as
**Source Sans 3**, so match that name when registering it for the plot.

## Source of truth

`R/npl_league_stats.R` and `data/teamnos.csv` are copies of files that also live
in the `r scripts/npl` OneDrive folder. **This repo is canonical** — edit here
and copy back, or they will drift. `teamnos.csv` looks like a Google Sheets
export; re-export and commit it when a team's logo, mascot, or division changes.

## Known limitations

- **Logos are hot-linked.** Both `gt_img_rows(img_source = "web")` and
  `circle_crop()` fetch from imgur at render time, so an imgur outage degrades
  the images. If that becomes a nuisance, vendor the 24 logos into `data/logos/`
  and repoint `teamnos.csv`.
- **The projections assume a 162-game season**
  (`pW = (162 - (W + L)) * pythag + W`). Once the regular season ends the page
  date stops advancing, so the gate simply never fires again — it fails safe.
