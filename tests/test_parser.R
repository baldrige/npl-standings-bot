#!/usr/bin/env Rscript
#
# Parser regression tests. Run from the repo root:
#   Rscript tests/test_parser.R
#
# The load-bearing test is the first one: the scraper's output must be
# indistinguishable, as read by readr, from the standings.csv that was produced
# by hand for the same page. That includes the duplicate-name repair
# (R...12 / R...20) that npl_league_stats.R indexes by.

suppressPackageStartupMessages({
  library(readr)
  library(purrr)
  library(stringr)
})

REPO <- normalizePath(".")
SCRAPER <- file.path(REPO, "R", "scrape_standings.R")
FIXTURE <- file.path(REPO, "tests", "fixtures", "page_2026-07-26.html")
EXPECTED <- file.path(REPO, "tests", "fixtures", "standings_expected_2026-07-26.csv")

failures <- 0L
ok <- function(what) message("  ok   - ", what)
bad <- function(what, detail = "") {
  failures <<- failures + 1L
  message("  FAIL - ", what, if (nzchar(detail)) paste0("\n         ", detail) else "")
}

# Run the scraper in a scratch directory so it cannot touch the repo's own
# standings.csv, and hand back what it wrote.
run_scraper <- function(fixture) {
  dir <- file.path(tempdir(), paste0("npl-", as.integer(runif(1, 1e6, 9e6))))
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  old <- setwd(dir)
  on.exit(setwd(old), add = TRUE)
  out <- suppressWarnings(system2(
    "Rscript", c(shQuote(SCRAPER), shQuote(fixture)),
    stdout = TRUE, stderr = TRUE
  ))
  list(
    status = attr(out, "status") %||% 0L,
    log = paste(out, collapse = "\n"),
    csv = file.path(dir, "standings.csv"),
    date = file.path(dir, "out", "page_date.txt")
  )
}
`%||%` <- function(x, y) if (is.null(x)) y else x

# Build a fixture with `drop` batting data rows removed, to prove the validator
# refuses to hand a short table downstream.
mutate_fixture <- function(pattern, drop_offsets) {
  lines <- read_lines(FIXTURE)
  i <- which(str_detect(lines, pattern))[1]
  stopifnot(!is.na(i))
  path <- tempfile(fileext = ".html")
  write_lines(lines[-(i + drop_offsets)], path)
  path
}

message("\n[1] scraper output matches the hand-pasted standings.csv")
r <- run_scraper(FIXTURE)
if (r$status != 0L) {
  bad("scraper exited cleanly", r$log)
} else {
  a <- read_csv(r$csv, show_col_types = FALSE)
  b <- read_csv(EXPECTED, show_col_types = FALSE)
  b <- b[seq_len(24), ]

  if (identical(dim(a), dim(b))) ok(sprintf("dimensions %d x %d", nrow(a), ncol(a)))
  else bad("dimensions", sprintf("got %s, want %s",
                                 paste(dim(a), collapse = "x"),
                                 paste(dim(b), collapse = "x")))

  if (identical(names(a), names(b))) ok("column names, including R...12 / R...20 repair")
  else bad("column names", paste(setdiff(names(a), names(b)), collapse = ", "))

  ca <- map_chr(a, \(x) class(x)[1])
  cb <- map_chr(b, \(x) class(x)[1])
  if (identical(ca, cb)) ok("column classes")
  else bad("column classes", paste(names(a)[ca != cb], collapse = ", "))

  if (identical(names(a), names(b))) {
    diffs <- map(names(a), \(n) {
      x <- a[[n]]
      y <- b[[n]]
      idx <- if (is.numeric(x) && is.numeric(y)) {
        which(abs(x - y) > 1e-9 | xor(is.na(x), is.na(y)))
      } else {
        which(as.character(x) != as.character(y))
      }
      if (length(idx)) sprintf("%s row %d: %s vs %s", n, idx,
                               as.character(x[idx]), as.character(y[idx]))
    }) |> compact() |> unlist()
    if (length(diffs) == 0) ok("all 24 x 43 values identical")
    else bad(sprintf("%d value mismatch(es)", length(diffs)),
             paste(head(diffs, 10), collapse = "\n         "))
  }

  if (identical(read_lines(r$date), "2026-07-26")) ok("page date parsed from <h1>")
  else bad("page date", paste(read_lines(r$date), collapse = ""))
}

message("\n[2] validator refuses a truncated batting block")
r2 <- run_scraper(mutate_fixture("^\\s*<u><span class='heading'>\\s*AB\\s+R\\s+H", 1:2))
if (r2$status != 0L && str_detect(r2$log, "expected 24 rows, got 22")) {
  ok("non-zero exit with a diagnostic naming the row count")
} else {
  bad("should have failed with 'expected 24 rows, got 22'",
      sprintf("status=%s log=%s", r2$status, str_trunc(r2$log, 300)))
}

message("\n[3] validator refuses a missing division block")
r3 <- run_scraper(mutate_fixture("Say Hey K Standings, Pitching", 0))
if (r3$status != 0L && str_detect(r3$log, "found 5")) {
  ok("non-zero exit naming the block count")
} else {
  bad("should have failed with 'found 5'",
      sprintf("status=%s log=%s", r3$status, str_trunc(r3$log, 300)))
}

message("")
if (failures > 0L) {
  message(failures, " failure(s)")
  quit(status = 1L)
}
message("all tests passed")
