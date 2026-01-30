# Scripts

## fetch-data.sh

Fetches GitHub activity data (PRs and commits) for the authenticated user using the `gh` CLI.

### Prerequisites

- [GitHub CLI](https://cli.github.com/) (`gh`) installed and authenticated
- `python3` available on PATH

### Usage

```bash
# Fetch data for a specific date range
./scripts/fetch-data.sh 2026-01-17 2026-01-30

# Fetch data for the last 2 full weeks (Monday-Sunday)
./scripts/fetch-data.sh
```

### Output

- Data is saved to `data/YYYY-MM-DD_to_YYYY-MM-DD.json`
- `data/index.json` is updated with the new period entry

### Data structure

```json
{
  "user": "github-username",
  "period_start": "YYYY-MM-DD",
  "period_end": "YYYY-MM-DD",
  "generated_at": "ISO timestamp",
  "pull_requests": [
    {
      "title": "PR title",
      "html_url": "...",
      "additions": 10,
      "deletions": 5,
      "changed_files": 3,
      "merged": true,
      ...
    }
  ],
  "commits": {
    "owner/repo": [
      {
        "sha": "...",
        "message": "...",
        "date": "ISO timestamp",
        "url": "..."
      }
    ]
  }
}
```
