library(tidyverse)
library(gt)
library(gtExtras)
library(ggrepel)
library(webshot2)
library(lubridate)
library(cropcircles)
library(ggimage)

# --- automation shims --------------------------------------------------------
# Every subtitle is driven from the date the *page* reports, not from the clock.
# Previously this script mixed today() - 1 with Sys.Date(), so three of the five
# images carried a date one day ahead of the data they described. The fallback
# keeps a standalone local run working if the scraper has not been run.
through <- tryCatch(
  as.Date(readLines(file.path("out", "page_date.txt"))[1]),
  error = function(e) {
    message("out/page_date.txt not found; falling back to yesterday's date")
    Sys.Date() - 1
  }
)

# Headless Chrome (webshot2 -> chromote) needs these when it runs as root or in
# a container. Harmless on a GitHub runner and on macOS.
if (nzchar(Sys.getenv("CI"))) {
  chromote::set_chrome_args(unique(c(
    tryCatch(chromote::default_chrome_args(), error = function(e) character()),
    "--no-sandbox", "--disable-dev-shm-usage"
  )))
}

dir.create("out", showWarnings = FALSE, recursive = TRUE)
# -----------------------------------------------------------------------------

standings <- read_csv("standings.csv")
standings <- standings %>% slice_head(n = 24)
teamnos <- read_csv("data/teamnos.csv")
standings <- standings %>% left_join(teamnos, by = c("No" = "No"))
standings <- standings %>%
  mutate(pythag = (R...20^1.83) / (R...20^1.83 + R...12^1.83))
standings <- standings %>% mutate(eW = pythag * (W + L))
standings <- standings %>% mutate(eL = (1 - pythag) * (W + L))
standings <- standings %>% mutate(pW = (162 - (W + L)) * pythag + W)
standings <- standings %>% mutate(pL = 162 - pW)
standings <- standings %>%
  group_by(Div) %>%
  mutate(divrank = rank(desc(W), ties.method = "average"))
wildAL <- standings %>%
  ungroup() %>%
  arrange(desc(W)) %>%
  filter(Lg == "AL" & divrank > 1) %>%
  mutate(wcrank = rank(desc(W), ties.method = "min"))
if (wildAL$wcrank[[1]] == wildAL$wcrank[[2]]) {
  countAL <- 3.6
} else {
  countAL <- 2.6
}

wildAL <- filter(wildAL, wcrank < countAL)

wildNL <- standings %>%
  ungroup() %>%
  arrange(desc(W)) %>%
  filter(Lg == "NL" & divrank > 1) %>%
  mutate(wcrank = rank(desc(W), ties.method = "min"))
if (wildNL$wcrank[[1]] == wildNL$wcrank[[2]]) {
  countNL <- 3.6
} else {
  countNL <- 2.6
}

wildNL <- filter(wildNL, wcrank < countNL)

standings <- standings %>%
  group_by(Lg) %>%
  mutate(wGB = if_else(Lg == "AL", min(wildAL$W) - W, min(wildNL$W) - W)) %>%
  mutate(wGB = na_if(wGB, 0)) %>%
  mutate(wGB = replace_na(as.character(wGB), "-"))

exstandings <- standings %>%
  group_by(Lg, Div) %>%
  arrange(desc(W), .by_group = TRUE) %>%
  mutate(GB = W[1] - W) %>%
  mutate(GB = na_if(GB, 0)) %>%
  mutate(GB = replace_na(as.character(GB), "-")) %>%
  select(Logo, Team, Mascot, Div, W, L, GB, eW, eL, pW, pL, pythag) %>%
  mutate(eW = round(eW, 1)) %>%
  mutate(eL = round(eL, 1)) %>%
  mutate(pythag = round(pythag, 3)) %>%
  mutate(pW = round(pW, 1)) %>%
  mutate(pL = round(pL, 1)) %>%
  gt() |>
  tab_header(
    title = "NPL Actual, Expected & Projected Standings",
    subtitle = paste0("Through Games of ", through)
  ) |>
  gt_theme_nytimes() |>
  gt_img_rows(columns = c("Logo"), img_source = "web", height = 30) |>
  tab_style(cell_text(align = "center"), locations = cells_row_groups()) |>
  tab_options(
    data_row.padding = px(1),
    table.font.size = 16,
    heading.subtitle.font.size = 18,
    column_labels.font.size = 14,
    row_group.font.weight = "bold"
  ) |>
  cols_label(
    Logo = "",
    Team = "Team",
    W = "W",
    L = "L",
    eW = "EW",
    eL = "EL",
    pW = "PW",
    pL = "PL",
    pythag = "Pythag"
  ) |>
  gt_color_rows(pythag, palette = c("blue", "white", "red")) |>
  gt_color_rows(pW, palette = c("blue", "white", "red")) |>
  cols_width(Team ~ px(150), pythag ~ px(25)) |>
  gt_merge_stack(
    Team,
    Mascot,
    palette = c("black", "black"),
    small_cap = FALSE,
    font_size = c("16px", "16px"),
    font_weight = c("normal", "bold")
  ) |>
  cols_align(align = "center", columns = c(Logo))

unlucky <- standings %>%
  ungroup() %>%
  select(Logo, Team, Mascot, W, L, eW, eL) %>%
  mutate(eW = round(eW, 1)) %>%
  mutate(eL = round(eL, 1)) %>%
  mutate(delta = eW - W) %>%
  arrange(desc(delta)) %>%
  gt() |>
  tab_header(
    title = "Unluckiest Teams in NPL",
    subtitle = paste0("Through Games of ", through)
  ) |>
  gt_theme_nytimes() |>
  tab_options(
    data_row.padding = px(1),
    table.font.size = 16,
    heading.subtitle.font.size = 18,
    column_labels.font.size = 16,
    row_group.font.weight = "bold"
  ) |>
  gt_img_rows(columns = c("Logo"), img_source = "web", height = 30) |>
  gt_merge_stack(
    Team,
    Mascot,
    palette = c("black", "black"),
    small_cap = FALSE,
    font_size = c("16px", "16px"),
    font_weight = c("normal", "bold")
  ) |>
  cols_width(Team ~ px(150)) |>
  cols_label(
    Logo = "",
    Team = "Team",
    W = "W",
    L = "L",
    eW = "EW",
    eL = "EL",
    delta = "Delta"
  ) |>
  gt_color_rows(delta, palette = c("red", "white", "blue")) |>
  cols_align(align = "center", columns = c(Logo))

wildcard <- standings %>%
  group_by(Lg) %>%
  filter(divrank > 1) %>%
  select(Logo, Team, Mascot, W, L, wGB, eW, eL, pW, pL, pythag) %>%
  mutate(eW = round(eW, 1)) %>%
  mutate(eL = round(eL, 1)) %>%
  mutate(pythag = round(pythag, 3)) %>%
  mutate(pW = round(pW, 1)) %>%
  mutate(pL = round(pL, 1)) %>%
  arrange(desc(W)) %>%
  gt() |>
  tab_header(
    title = "NPL Wild Card Standings",
    subtitle = paste0("Through Games of ", through)
  ) |>
  gt_theme_nytimes() |>
  tab_style(cell_text(align = "center"), locations = cells_row_groups()) |>
  tab_options(
    data_row.padding = px(1),
    table.font.size = 16,
    heading.subtitle.font.size = 18,
    column_labels.font.size = 16,
    row_group.font.weight = "bold"
  ) |>
  gt_img_rows(columns = c("Logo"), img_source = "web", height = 30) |>
  cols_label(
    Logo = "",
    Team = "Team",
    W = "W",
    L = "L",
    wGB = "GB",
    eW = "EW",
    eL = "EL",
    pW = "PW",
    pL = "PL",
    pythag = "Pythag"
  ) |>
  gt_color_rows(pythag, palette = c("blue", "white", "red")) |>
  cols_width(Team ~ px(150), pythag ~ px(25)) |>
  gt_merge_stack(
    Team,
    Mascot,
    palette = c("black", "black"),
    small_cap = FALSE,
    font_size = c("16px", "16px"),
    font_weight = c("normal", "bold")
  ) |>
  cols_align(align = "center", columns = c(Logo)) |>
  gt_highlight_rows(
    rows = (wGB < 0.1),
    font_weight = "normal",
    fill = "lightgreen",
    target_col = wGB
  )

teampitchhit <- standings %>%
  ungroup() %>%
  mutate(OPS = OBA + SlgA) %>%
  mutate(OPS = round(OPS, 3)) %>%
  mutate(rOPS = min_rank(desc(OPS))) %>%
  mutate(rERA = min_rank(ERA)) %>%
  arrange(Mascot) %>%
  select(Logo, Team, Mascot, W, L, OPS, rOPS, ERA, rERA) %>%
  gt() |>
  tab_header(
    title = "NPL Team Hitting and Pitching",
    subtitle = paste0("Through Games of ", through)
  ) |>
  gt_theme_nytimes() |>
  tab_style(cell_text(align = "center"), locations = cells_row_groups()) |>
  tab_options(
    data_row.padding = px(1),
    table.font.size = 16,
    heading.subtitle.font.size = 18,
    column_labels.font.size = 16,
    row_group.font.weight = "bold"
  ) |>
  gt_img_rows(columns = c("Logo"), img_source = "web", height = 30) |>
  cols_label(
    Logo = "",
    Team = "Team",
    W = "W",
    L = "L",
    OPS = "OPS",
    rOPS = "Rank",
    ERA = "ERA",
    rERA = "Rank"
  ) |>
  gt_color_rows(OPS, palette = c("blue", "white", "red")) |>
  gt_color_rows(ERA, palette = c("red", "white", "blue")) |>
  gt_color_rows(rOPS, palette = c("red", "white", "blue"), domain = c(1, 24)) |>
  gt_color_rows(rERA, palette = c("red", "white", "blue"), domain = c(1, 24)) |>
  cols_width(Team ~ px(150)) |>
  gt_merge_stack(
    Team,
    Mascot,
    palette = c("black", "black"),
    small_cap = FALSE,
    font_size = c("16px", "16px"),
    font_weight = c("normal", "bold")
  ) |>
  cols_align(align = "center", columns = c(Logo))

exstandings |> gtsave(filename = "out/exstandings.png", expand = 30)
wildcard |> gtsave(filename = "out/wildcard.png", expand = 30)
unlucky |> gtsave(filename = "out/unlucky.png", expand = 30)
teampitchhit |> gtsave(filename = "out/teampitchhit.png", expand = 30)

min <- floor(min(min(standings$R...12), min(standings$R...20)) / 10) * 10
max <- ceiling(max(max(standings$R...12), max(standings$R...20)) / 10) * 10
plot <- standings %>%
  mutate(images_cropped = circle_crop(Logo, border_size = 1)) %>%
  ggplot(aes(R...12, R...20, label = Mascot)) +
  geom_abline(
    intercept = 0,
    slope = 1,
    color = "red",
    linetype = "dashed",
    linewidth = 0.5
  ) +
  geom_image(
    aes(R...12, R...20, image = images_cropped),
    size = 0.04,
    by = "height"
  ) +
  geom_label_repel(
    aes(lineheight = .9),
    box.padding = 0.1,
    nudge_y = -5.5,
    max.time = 5
  ) +
  labs(
    title = "NPL Runs Scored and Allowed",
    subtitle = paste0("Through Games of ", through)
  ) +
  xlab("Runs Allowed") +
  ylab("Runs Scored") +
  xlim(min, max) +
  ylim(min, max) +
  theme_minimal()

# ragg resolves fonts through systemfonts rather than the platform graphics
# device, which is what keeps this plot's text consistent between macOS and the
# Ubuntu runner.
ggsave(
  "out/rsra.png",
  plot = plot,
  width = 1800,
  height = 1800,
  units = "px",
  dpi = 200,
  bg = "white",
  device = ragg::agg_png
)
