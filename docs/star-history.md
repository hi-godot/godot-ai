# Star history chart

The README's star-history chart is rendered by
[`script/generate-star-history`](../script/generate-star-history) and published
by [`.github/workflows/star-history.yml`](../.github/workflows/star-history.yml)
to the dedicated `star-history` branch, which the README embeds by raw URL.

Publishing off `main` keeps chart refreshes out of `main`'s history, lets the
job run daily, and stops it conflicting with PRs (#818, #819).

## Data sources, in preference order

1. **Exact history** — `GET /repos/{repo}/stargazers` with
   `Accept: application/vnd.github.star+json`, which returns a `starred_at`
   timestamp per stargazer. This rebuilds the entire curve from scratch and
   corrects any drift, so it is used whenever it is reachable.
2. **Accumulated series** — `star-history.json` on the `star-history` branch,
   a list of `[date, count]` points. When the stargazers endpoint refuses the
   request, the run keeps this history and appends one point from
   `GET /repos/{repo}` → `stargazers_count`, which needs only `metadata=read`.

The series is the chart's memory. A run that cannot reach either source fails
loudly rather than drawing an invented curve.

## The 2026-07-24 outage

Daily runs began failing `403` on 2026-07-24 even though `STAR_HISTORY_TOKEN`
was set and healthy. Probing all three credential classes against the same repo
in the same minute (workflow run 30161903920 / 30161955416):

| Credential | `GET /repos/{repo}` | stargazers (plain) | stargazers (`star+json`) |
| --- | --- | --- | --- |
| Fine-grained PAT (repo admin) | 200 | 403 | 403 |
| Workflow `GITHUB_TOKEN` (App) | 200 | 403 | 403 |
| No `Authorization` header | — | 401 | 401 |

The 403s carry `x-accepted-github-permissions: 'metadata=read; contents=write'`
and `message: Resource not accessible by personal access token`.

What that establishes:

- **The token is fine.** It authenticates (`/user` → 200), has a 5,000/hr
  limit, and reads `/repos/{repo}` on `metadata=read` alone.
- **It is not about the timestamps.** The plain stargazer list — public data —
  fails identically to the `star+json` variant, so this is not the
  admins-and-collaborators restriction that motivated #750.
- **The demanded permission is incoherent.** Reading a public list cannot
  legitimately require *write* access to repository contents.
- **It is not specific to us.** A GitHub App token fails the same way, which no
  org policy or token grant can explain.

Do **not** grant `contents=write` to work around this: it is repository write
access in exchange for a README image, and it would be pointless privilege once
GitHub corrects the mapping. The fallback path above keeps the chart current
with the permissions the token already has.

When the endpoint recovers, no change is needed — source 1 is tried first on
every run and will silently resume, rebuilding the exact curve.

## Local use

```bash
# Offline, from explicit points — no network, no token.
script/generate-star-history --seed "2026-04-12:0,2026-07-16:1009" --out /tmp/chart.svg

# Against the live API.
STAR_HISTORY_TOKEN=... script/generate-star-history --repo owner/name
```

Rendering is deterministic for a given (repo, data, date) — the starfield is
seeded from the repo name — so unchanged data produces byte-identical output.
