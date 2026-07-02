# Traffic digest workflow

`.github/workflows/traffic-digest.yml` posts a daily "skill traffic digest" for
this repo to a Slack incoming webhook, so the maintainer can see clones, views,
stars, and forks without opening the GitHub Insights tab.

## What it does

Once a day at 07:00 UTC (and on demand via the Actions "Run workflow" button) it:

1. Calls the GitHub REST API for repository traffic:
   - `GET /repos/TeemuSo/launchguard-skill/traffic/clones`
   - `GET /repos/TeemuSo/launchguard-skill/traffic/views`
   - `GET /repos/TeemuSo/launchguard-skill` (for stars and forks)
2. Computes yesterday's numbers (the most recent complete day in the daily
   breakdown, since today's bucket is still partial), the rolling 14-day totals,
   and the current star and fork counts.
3. Posts a compact one-line summary to Slack, for example:

   ```
   :package: launchguard-skill daily — clones: 4 yesterday (3 unique), 14d: 41 (22 unique) | views: 60 (18 unique) | :star: 12 | forks: 2
   ```

To keep the channel quiet, scheduled runs are skipped when yesterday had zero
clones and zero views. Manual runs (via "Run workflow") always post, so you can
confirm the wiring works.

The workflow fails loudly (non-zero exit) if `TRAFFIC_PAT` is missing or
unauthorized, so a bad or expired token is noticed. A missing
`SLACK_PULSE_WEBHOOK_URL` is treated as a warning and the run exits cleanly.

## Repo secrets to configure

Add both under Settings > Secrets and variables > Actions > Repository secrets:

- **`TRAFFIC_PAT`** — a personal access token that can read this repo's traffic.
  The default `GITHUB_TOKEN` cannot read the `/traffic` endpoints, so a PAT is
  required. Use either:
  - a fine-grained PAT scoped to only `TeemuSo/launchguard-skill` with
    `Administration: Read-only` permission, or
  - a classic PAT with the `repo` scope.
- **`SLACK_PULSE_WEBHOOK_URL`** — a Slack incoming webhook URL for the channel
  that should receive the digest.

## Note on the data window

GitHub traffic data only covers a rolling 14-day window. Days older than 14 days
are not available from the API, so the digest can only ever report on the last
two weeks. Long-term trends need to be captured elsewhere (for example by
recording each daily post).
