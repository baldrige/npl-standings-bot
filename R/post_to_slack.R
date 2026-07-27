#!/usr/bin/env Rscript
#
# Post the five weekly images to Slack as a single message.
#
# Slack retired files.upload, so this uses the v2 external-upload flow:
#   1. files.getUploadURLExternal  -> a one-shot upload URL per file
#   2. POST the raw bytes to that URL
#   3. files.completeUploadExternal with ALL file ids in ONE call, which is what
#      makes them land as a single message rather than five.
#
# Environment:
#   SLACK_BOT_TOKEN    xoxb-... with the files:write and chat:write scopes
#   SLACK_CHANNEL_ID   e.g. C0123456789
#   NPL_DRY_RUN        if set to a truthy value, validate and print, post nothing
#
# The bot must be a member of the channel. If it is not, Slack returns
# ok:false / not_in_channel and nothing is uploaded - fix with /invite @yourbot.

suppressPackageStartupMessages({
  library(httr2)
})

SLACK_API <- "https://slack.com/api"

# Order matters: this is the order they appear in the Slack message.
IMAGES <- list(
  list(file = "out/exstandings.png",  title = "Actual, Expected & Projected Standings"),
  list(file = "out/wildcard.png",     title = "Wild Card Standings"),
  list(file = "out/unlucky.png",      title = "Unluckiest Teams"),
  list(file = "out/teampitchhit.png", title = "Team Hitting and Pitching"),
  list(file = "out/rsra.png",         title = "Runs Scored and Allowed")
)

truthy <- function(x) tolower(trimws(x)) %in% c("1", "true", "yes", "y", "on")

# Slack answers HTTP 200 with ok:false, so every response needs checking.
slack <- function(method, ..., token) {
  resp <- request(file.path(SLACK_API, method)) |>
    req_auth_bearer_token(token) |>
    req_timeout(120) |>
    req_retry(max_tries = 3) |>
    req_body_form(...) |>
    req_error(is_error = \(r) FALSE) |>
    req_perform() |>
    resp_body_json()
  if (!isTRUE(resp$ok)) {
    stop(sprintf("Slack %s failed: %s", method,
                 resp$error %||% "unknown error (no error field returned)"))
  }
  resp
}
`%||%` <- function(x, y) if (is.null(x)) y else x

upload_one <- function(img, token) {
  size <- file.size(img$file)
  if (is.na(size) || size == 0) stop("missing or empty file: ", img$file)

  # `length` must be the exact byte count or Slack rejects the completion.
  res <- slack("files.getUploadURLExternal",
               filename = basename(img$file),
               length = format(size, scientific = FALSE),
               token = token)

  request(res$upload_url) |>
    req_timeout(300) |>
    req_retry(max_tries = 3) |>
    req_body_file(img$file, type = "image/png") |>
    req_perform()

  message(sprintf("  uploaded %-24s %7.1f KB  id=%s",
                  basename(img$file), size / 1024, res$file_id))
  list(id = res$file_id, title = img$title)
}

main <- function() {
  dry <- truthy(Sys.getenv("NPL_DRY_RUN", ""))

  through <- tryCatch(
    readLines(file.path("out", "page_date.txt"))[1],
    error = function(e) stop("out/page_date.txt not found; run the scraper first")
  )

  missing <- vapply(IMAGES, \(i) !file.exists(i$file), logical(1))
  if (any(missing)) {
    stop("image(s) not generated: ",
         paste(vapply(IMAGES[missing], \(i) i$file, character(1)), collapse = ", "))
  }

  comment <- sprintf(":baseball: *NPL weekly report* - through games of %s", through)

  if (dry) {
    message("DRY RUN - not posting. Would post to Slack:")
    message("  ", comment)
    for (i in IMAGES) {
      message(sprintf("  %-24s %7.1f KB  %s",
                      basename(i$file), file.size(i$file) / 1024, i$title))
    }
    return(invisible(NULL))
  }

  token <- Sys.getenv("SLACK_BOT_TOKEN", "")
  channel <- Sys.getenv("SLACK_CHANNEL_ID", "")
  if (!nzchar(token)) stop("SLACK_BOT_TOKEN is not set")
  if (!nzchar(channel)) stop("SLACK_CHANNEL_ID is not set")

  message("Uploading ", length(IMAGES), " images...")
  uploaded <- lapply(IMAGES, upload_one, token = token)

  # One completion call for all five => one message.
  slack("files.completeUploadExternal",
        channel_id = channel,
        initial_comment = comment,
        files = jsonlite::toJSON(
          data.frame(
            id = vapply(uploaded, \(u) u$id, character(1)),
            title = vapply(uploaded, \(u) u$title, character(1)),
            stringsAsFactors = FALSE
          ),
          auto_unbox = TRUE
        ),
        token = token)

  message("Posted to Slack channel ", channel, " (through ", through, ")")
}

main()
