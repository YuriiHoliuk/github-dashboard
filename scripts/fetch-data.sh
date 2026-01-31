#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DATA_DIR="$PROJECT_DIR/data"

mkdir -p "$DATA_DIR"

# --- Determine date range ---
if [[ $# -ge 2 ]]; then
  START_DATE="$1"
  END_DATE="$2"
else
  # Default: last 2 full weeks (Monday-Sunday containing the last 14 days)
  # Find the most recent Sunday (yesterday or earlier)
  if [[ "$(uname)" == "Darwin" ]]; then
    DOW=$(date +%u) # 1=Monday, 7=Sunday
    DAYS_SINCE_SUNDAY=$(( DOW % 7 ))
    if [[ $DAYS_SINCE_SUNDAY -eq 0 ]]; then
      DAYS_SINCE_SUNDAY=7
    fi
    END_DATE=$(date -v-${DAYS_SINCE_SUNDAY}d +%Y-%m-%d)
    START_DATE=$(date -v-${DAYS_SINCE_SUNDAY}d -v-13d +%Y-%m-%d)
  else
    DOW=$(date +%u)
    DAYS_SINCE_SUNDAY=$(( DOW % 7 ))
    if [[ $DAYS_SINCE_SUNDAY -eq 0 ]]; then
      DAYS_SINCE_SUNDAY=7
    fi
    END_DATE=$(date -d "-${DAYS_SINCE_SUNDAY} days" +%Y-%m-%d)
    START_DATE=$(date -d "-${DAYS_SINCE_SUNDAY} days -13 days" +%Y-%m-%d)
  fi
fi

echo "Fetching data for period: $START_DATE to $END_DATE"

# --- Get GitHub username ---
echo "Getting GitHub username..."
GH_USER=$(gh api user --jq '.login')
echo "User: $GH_USER"

# --- Fetch PRs created by user ---
echo "Fetching PRs created in date range..."
CREATED_PRS=$(gh api --paginate "search/issues?q=type:pr+author:${GH_USER}+created:${START_DATE}..${END_DATE}&per_page=100" \
  --jq '.items' 2>/dev/null || echo "[]")

# --- Fetch PRs merged by user in date range ---
echo "Fetching PRs merged in date range..."
MERGED_PRS=$(gh api --paginate "search/issues?q=type:pr+author:${GH_USER}+merged:${START_DATE}..${END_DATE}&per_page=100" \
  --jq '.items' 2>/dev/null || echo "[]")

# --- Deduplicate and extract PR details ---
echo "Deduplicating PRs and fetching details..."

OUTPUT_FILE="$DATA_DIR/${START_DATE}_to_${END_DATE}.json"


# Use a temp file approach for passing large JSON to python
TMPDIR_WORK=$(mktemp -d)
trap "rm -rf $TMPDIR_WORK" EXIT

echo "$CREATED_PRS" > "$TMPDIR_WORK/created.json"
echo "$MERGED_PRS" > "$TMPDIR_WORK/merged.json"

python3 - "$GH_USER" "$START_DATE" "$END_DATE" "$TMPDIR_WORK" "$OUTPUT_FILE" "$DATA_DIR" << 'PYEOF'
import json
import subprocess
import sys
import time
import os
from datetime import datetime, timezone

gh_user = sys.argv[1]
start_date = sys.argv[2]
end_date = sys.argv[3]
tmpdir = sys.argv[4]
output_file = sys.argv[5]
data_dir = sys.argv[6]

with open(os.path.join(tmpdir, "created.json")) as f:
    created_items = json.load(f) if os.path.getsize(os.path.join(tmpdir, "created.json")) > 2 else []

with open(os.path.join(tmpdir, "merged.json")) as f:
    merged_items = json.load(f) if os.path.getsize(os.path.join(tmpdir, "merged.json")) > 2 else []

# Handle case where API returns a single array or nested items
if isinstance(created_items, dict):
    created_items = created_items.get("items", [])
if isinstance(merged_items, dict):
    merged_items = merged_items.get("items", [])

# Flatten if paginated results produced nested arrays
def flatten(lst):
    result = []
    for item in lst:
        if isinstance(item, list):
            result.extend(item)
        else:
            result.append(item)
    return result

created_items = flatten(created_items)
merged_items = flatten(merged_items)

# Deduplicate by PR URL
seen = {}
all_prs = []
for pr in created_items + merged_items:
    url = pr.get("html_url", "")
    if url and url not in seen:
        seen[url] = True
        all_prs.append(pr)

print(f"Found {len(all_prs)} unique PRs")

# Fetch detailed info for each PR
detailed_prs = []
repos_set = set()

for idx, pr in enumerate(all_prs):
    html_url = pr.get("html_url", "")
    pull_request = pr.get("pull_request", {})
    api_url = pull_request.get("url", "") if pull_request else ""

    if not api_url:
        # Construct from html_url: https://github.com/owner/repo/pull/123
        parts = html_url.replace("https://github.com/", "").split("/")
        if len(parts) >= 4:
            owner, repo, _, number = parts[0], parts[1], parts[2], parts[3]
            api_url = f"repos/{owner}/{repo}/pulls/{number}"
        else:
            continue
    else:
        # Convert full URL to relative path for gh api
        api_url = api_url.replace("https://api.github.com/", "")

    print(f"  Fetching PR details [{idx+1}/{len(all_prs)}]: {html_url}")

    try:
        result = subprocess.run(
            ["gh", "api", api_url],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            print(f"    Warning: Failed to fetch {api_url}: {result.stderr.strip()}")
            continue

        detail = json.loads(result.stdout)

        repo_url = detail.get("base", {}).get("repo", {}).get("url", "")
        repo_full_name = detail.get("base", {}).get("repo", {}).get("full_name", "")

        if repo_full_name:
            repos_set.add(repo_full_name)

        labels = [l.get("name", "") for l in detail.get("labels", [])]

        pr_data = {
            "closed_at": detail.get("closed_at"),
            "created_at": detail.get("created_at"),
            "draft": detail.get("draft", False),
            "html_url": detail.get("html_url"),
            "labels": labels,
            "merged_at": detail.get("merged_at"),
            "number": detail.get("number"),
            "repo_url": repo_url,
            "state": detail.get("state"),
            "title": detail.get("title"),
            "updated_at": detail.get("updated_at"),
            "additions": detail.get("additions", 0),
            "changed_files": detail.get("changed_files", 0),
            "comments": detail.get("comments", 0),
            "deletions": detail.get("deletions", 0),
            "merge_commit_sha": detail.get("merge_commit_sha"),
            "merged": detail.get("merged", False),
            "review_comments": detail.get("review_comments", 0),
        }
        detailed_prs.append(pr_data)

    except subprocess.TimeoutExpired:
        print(f"    Warning: Timeout fetching {api_url}")
    except json.JSONDecodeError:
        print(f"    Warning: Invalid JSON from {api_url}")

    # Rate limiting: small sleep between requests
    if idx < len(all_prs) - 1:
        time.sleep(0.5)

# Sort PRs by created_at descending
detailed_prs.sort(key=lambda p: p.get("created_at") or "", reverse=True)

# --- Fetch commits from discovered repos ---
print(f"\nFetching commits from {len(repos_set)} repos...")
commits = {}

for repo_name in sorted(repos_set):
    print(f"  Fetching commits from {repo_name}...")
    try:
        result = subprocess.run(
            [
                "gh", "api", "--paginate",
                f"repos/{repo_name}/commits?author={gh_user}&since={start_date}T00:00:00Z&until={end_date}T23:59:59Z&per_page=100"
            ],
            capture_output=True, text=True, timeout=60
        )
        if result.returncode != 0:
            print(f"    Warning: Failed to fetch commits from {repo_name}: {result.stderr.strip()}")
            continue

        raw_commits = json.loads(result.stdout)
        if isinstance(raw_commits, dict):
            raw_commits = [raw_commits]

        repo_commits = []
        for c in flatten(raw_commits):
            commit_info = c.get("commit", {})
            author_info = commit_info.get("author", {})
            repo_commits.append({
                "date": author_info.get("date"),
                "message": commit_info.get("message", ""),
                "sha": c.get("sha"),
                "url": c.get("html_url"),
            })

        if repo_commits:
            # Sort by date descending
            repo_commits.sort(key=lambda x: x.get("date") or "", reverse=True)
            commits[repo_name] = repo_commits
            print(f"    Found {len(repo_commits)} commits")

    except subprocess.TimeoutExpired:
        print(f"    Warning: Timeout fetching commits from {repo_name}")
    except json.JSONDecodeError:
        print(f"    Warning: Invalid JSON from commits of {repo_name}")

    time.sleep(0.5)

# --- Build output ---
output = {
    "user": gh_user,
    "period_start": start_date,
    "period_end": end_date,
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "pull_requests": detailed_prs,
    "commits": commits,
}

with open(output_file, "w") as f:
    json.dump(output, f, indent=2)

print(f"\nData written to {output_file}")
print(f"  PRs: {len(detailed_prs)}")
print(f"  Repos with commits: {len(commits)}")
total_commits = sum(len(v) for v in commits.values())
print(f"  Total commits: {total_commits}")

# --- Update index.json ---
index_file = os.path.join(data_dir, "index.json")
if os.path.exists(index_file):
    with open(index_file) as f:
        index_data = json.load(f)
else:
    index_data = {"periods": []}

new_entry = {
    "start": start_date,
    "end": end_date,
    "file": f"{start_date}_to_{end_date}.json",
    "pr_count": len(detailed_prs),
    "commit_count": total_commits,
}

# Remove existing entry for same period if present
index_data["periods"] = [
    p for p in index_data["periods"]
    if not (p.get("start") == start_date and p.get("end") == end_date)
]

index_data["periods"].append(new_entry)

# Sort periods by start date descending
index_data["periods"].sort(key=lambda p: p.get("start", ""), reverse=True)

with open(index_file, "w") as f:
    json.dump(index_data, f, indent=2)
    f.write("\n")

print(f"Updated {index_file}")
PYEOF

echo "Done!"
