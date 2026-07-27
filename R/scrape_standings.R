#!/usr/bin/env Rscript
#
# Scrape the Scoresheet "BL National Pastime" summary page into standings.csv,
# replacing the weekly copy-and-paste.
#
# Writes:
#   standings.csv      43 columns. Duplicate headers (R, H, BA, BB, K appear in
#                      both the pitching and batting halves) are preserved
#                      verbatim, so readr reproduces the R...12 / R...20 names
#                      that npl_league_stats.R indexes by. Keeping the file
#                      byte-compatible with the hand-pasted version means the
#                      stats script needs no column changes, and you can still
#                      paste into it by hand if this ever breaks.
#   out/page_date.txt  The page's own "through" date, ISO. Every image subtitle
#                      is driven from this rather than from the clock.
#
# Usage:
#   Rscript R/scrape_standings.R                  # fetch live
#   Rscript R/scrape_standings.R path/to.html     # parse a saved fixture
#   NPL_FIXTURE=path/to.html Rscript R/scrape_standings.R

suppressPackageStartupMessages({
  library(rvest)
  library(httr2)
  library(stringr)
  library(purrr)
})

URL <- "https://www.scoresheet.com/FOR_WWW/BL_National_Pastime.htm"
UA <- "Mozilla/5.0 (compatible; NPLStandingsBot/1.0)"

N_TEAMS <- 24

# The page emits pitching as six per-division blocks, then batting and fielding
# together in one block. Splicing them gives the 43-column layout.
PITCH_COLS <- c(
  "W", "L", "pct.", "GB", "ERA", "CG", "ShO", "RS", "Sv",
  "IP", "R", "ER", "H", "BA", "BB", "K", "WP"
)
BAT_COLS <- c(
  "AB", "R", "H", "D", "T", "HR", "RBI", "BB", "K", "BA", "OBA", "SlgA",
  "SH", "F", "SF", "GDP", "SB", "CS", "LOB", "OP", "DP", "E", "OSB", "OCS", "PB"
)
GB_INDEX <- match("GB", PITCH_COLS)

# Matches 65, .613, 946.1, -3. Deliberately strict: anything else in a stat
# column means the page shape changed and we should stop rather than post
# nonsense to Slack.
NUM_RE <- "^-?[0-9]*\\.?[0-9]+$"

toks <- function(x) str_split(str_trim(x), "\\s+")[[1]]

read_page <- function(fixture) {
  if (nzchar(fixture)) {
    message("Reading fixture: ", fixture)
    if (!file.exists(fixture)) stop("fixture not found: ", fixture)
    return(read_html(fixture))
  }
  message("Fetching ", URL)
  html <- request(URL) |>
    req_user_agent(UA) |>
    req_timeout(60) |>
    req_retry(max_tries = 4) |>
    req_perform() |>
    resp_body_string()
  read_html(html)
}

# "BL National Pastime Summary through 7-26-26" -> 2026-07-26
page_date <- function(doc) {
  h1 <- html_text2(html_element(doc, "h1"))
  if (length(h1) != 1 || is.na(h1)) {
    stop("no <h1> on the page; cannot determine the data date")
  }
  tok <- str_extract(h1, "[0-9]{1,2}-[0-9]{1,2}-[0-9]{2}")
  if (is.na(tok)) stop("no M-D-YY date found in <h1>: ", h1)
  d <- as.Date(tok, format = "%m-%d-%y")
  if (is.na(d)) stop("could not parse date token '", tok, "' from <h1>: ", h1)
  d
}

parse_pitching <- function(lines) {
  hdr <- which(str_detect(lines, "Standings, Pitching"))
  if (length(hdr) != 6) {
    stop("expected 6 division pitching blocks, found ", length(hdr))
  }
  rows <- unlist(map(hdr, \(i) lines[(i + 1):(i + 4)]))

  # Team names vary in width and contain spaces, so anchor on the ends: first
  # token is the team number, the last 17 are the stats, the middle is the name
  # (discarded - divisions come from teamnos.csv, not from the page).
  map(rows, \(ln) {
    t <- toks(ln)
    if (length(t) < length(PITCH_COLS) + 2) {
      stop("pitching row too short to hold a team name plus ",
           length(PITCH_COLS), " stats: ", str_trim(ln))
    }
    stats <- tail(t, length(PITCH_COLS))
    ok <- str_detect(stats, NUM_RE)
    # GB is "-" for a division leader.
    ok[GB_INDEX] <- ok[GB_INDEX] || identical(stats[GB_INDEX], "-")
    if (!all(ok)) {
      stop("non-numeric pitching field(s) [",
           paste(PITCH_COLS[!ok], collapse = ", "), "] in: ", str_trim(ln))
    }
    c(t[1], stats)
  }) |> do.call(what = rbind)
}

parse_batting <- function(lines) {
  hdr <- which(str_detect(lines, "^\\s*AB\\s+R\\s+H\\s+D\\s+T\\s+HR\\s+RBI"))
  if (length(hdr) != 1) {
    stop("expected exactly 1 batting/fielding header, found ", length(hdr))
  }

  # Bound this block by row *shape*, not by a row count: the weekly
  # results-by-owner section immediately below also begins with a team number,
  # so ~300 further lines would otherwise look like candidates.
  out <- list()
  for (ln in lines[(hdr + 1):length(lines)]) {
    if (!nzchar(str_trim(ln))) next # blank lines separate the six divisions
    t <- toks(ln)
    if (length(t) != length(BAT_COLS) + 1 || !all(str_detect(t, NUM_RE))) break
    out[[length(out) + 1]] <- t
  }
  do.call(rbind, out)
}

check_block <- function(m, what) {
  if (is.null(m) || nrow(m) != N_TEAMS) {
    stop(sprintf("%s: expected %d rows, got %d", what, N_TEAMS,
                 if (is.null(m)) 0L else nrow(m)))
  }
  no <- suppressWarnings(as.integer(m[, 1]))
  # length is already N_TEAMS, so set equality also rules out duplicates.
  if (anyNA(no) || !setequal(no, seq_len(N_TEAMS))) {
    stop(sprintf("%s: team numbers are not exactly 1..%d (got %s)",
                 what, N_TEAMS, paste(sort(no), collapse = ",")))
  }
  m[order(no), , drop = FALSE]
}

main <- function() {
  argv <- commandArgs(trailingOnly = TRUE)
  fixture <- if (length(argv) >= 1) argv[1] else Sys.getenv("NPL_FIXTURE", "")

  doc <- read_page(fixture)
  through <- page_date(doc)
  message("Page data date: ", format(through))

  pre <- html_element(doc, "pre")
  if (inherits(pre, "xml_missing")) stop("no <pre> block found on the page")
  lines <- str_split(html_text(pre), "\n")[[1]]

  pit <- check_block(parse_pitching(lines), "pitching")
  bat <- check_block(parse_batting(lines), "batting/fielding")

  if (!identical(as.integer(pit[, 1]), as.integer(bat[, 1]))) {
    stop("pitching and batting halves disagree on team numbering")
  }

  hdr <- c("No", PITCH_COLS, BAT_COLS)
  body <- cbind(pit, bat[, -1, drop = FALSE])
  stopifnot(ncol(body) == length(hdr))

  dir.create("out", showWarnings = FALSE, recursive = TRUE)
  writeLines(
    c(paste(hdr, collapse = ","), apply(body, 1, paste, collapse = ",")),
    "standings.csv"
  )
  writeLines(format(through), "out/page_date.txt")

  message(sprintf("Wrote standings.csv (%d rows x %d cols) and out/page_date.txt",
                  nrow(body), ncol(body)))
}

main()
