#!/usr/bin/env bash
# Post a LaunchProof verdict into a GitHub PR as a comment.
#
#   bash "$LAUNCHPROOF_HOME/kit/post-proof.sh" <pr-number> <run-dir> [--proof-url URL] [--repo OWNER/NAME]
#
#   <pr-number>   the PR to comment on
#   <run-dir>     a LaunchProof run directory containing result.json
#                 (e.g. .launchproof/runs/20260709-172508-funnel-red)
#   --proof-url   optional public proof page or evidence link to include
#   --repo        optional owner/name; defaults to the current directory's repo
#
# The comment carries the verdict (WORKING / BROKEN / INCONCLUSIVE), what the
# test proves, the per-step outcomes, and where the recorded evidence lives.
# Run directories are local and gitignored by design, so the comment records
# the run id and machine path; pass --proof-url when a hosted proof page exists.

set -euo pipefail

PR=""
RUN_DIR=""
PROOF_URL=""
REPO_FLAG=()

while [ $# -gt 0 ]; do
  case "$1" in
    --proof-url) [ $# -ge 2 ] || { echo "error: --proof-url needs a value" >&2; exit 1; }
                 PROOF_URL="$2"; shift 2 ;;
    --repo)      [ $# -ge 2 ] || { echo "error: --repo needs a value (OWNER/NAME)" >&2; exit 1; }
                 REPO_FLAG=(-R "$2"); shift 2 ;;
    -h|--help) sed -n '2,17p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)
      if [ -z "$PR" ]; then PR="$1"
      elif [ -z "$RUN_DIR" ]; then RUN_DIR="$1"
      else echo "error: unexpected argument $1" >&2; exit 1
      fi
      shift ;;
  esac
done

if [ -z "$PR" ] || [ -z "$RUN_DIR" ]; then
  echo "usage: post-proof.sh <pr-number> <run-dir> [--proof-url URL] [--repo OWNER/NAME]" >&2
  exit 1
fi
for dep in gh python3; do
  command -v "$dep" >/dev/null 2>&1 || { echo "error: '$dep' is required but not on PATH" >&2; exit 1; }
done
if [ ! -f "$RUN_DIR/result.json" ]; then
  echo "error: $RUN_DIR/result.json not found (is this a LaunchProof run directory?)" >&2
  echo "hint: run the LaunchProof test first; if this repo has no LaunchProof setup," >&2
  echo "      state your proof (or \"docs-only\") in the PR body instead." >&2
  exit 1
fi

BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT

RUN_DIR="$RUN_DIR" PROOF_URL="$PROOF_URL" python3 - > "$BODY_FILE" <<'PYEOF'
import json, os

run_dir = os.environ["RUN_DIR"]
proof_url = os.environ.get("PROOF_URL", "")
r = json.load(open(os.path.join(run_dir, "result.json")))

verdict = r.get("verdict", "UNKNOWN")
badge = {"WORKING": "🟢", "BROKEN": "🔴", "INCONCLUSIVE": "🟡"}.get(verdict, "⚪")

lines = []
lines.append(f"## LaunchProof: {badge} **{verdict}**")
lines.append("")
lines.append(f"**Test:** `{r.get('test', '?')}` — {r.get('title', '')}")
if r.get("meaning"):
    lines.append(f"**If this breaks:** {r['meaning']}")
lines.append(f"**Target:** `{r.get('target', '?')}` · **Run:** `{r.get('runId', '?')}` · {r.get('durationMs', 0)/1000:.1f}s")
lines.append("")
lines.append("| # | Step | Status |")
lines.append("|---|------|--------|")
for s in r.get("steps", []):
    icon = "✅" if s.get("status") == "passed" else "❌"
    lines.append(f"| {s.get('index', '?')} | {s.get('name', '?')} | {icon} {s.get('status', '?')} |")
    if s.get("error"):
        first = str(s["error"]).strip().splitlines()[0][:200]
        lines.append(f"| | ↳ `{first}` | |")
lines.append("")
if proof_url:
    lines.append(f"**Proof page:** {proof_url}")
arts = r.get("artifacts", {}) or {}
art_bits = [k for k in ("video", "videoSeekable", "trace") if arts.get(k)]
evid = f"video + trace + per-step shots/DOM in `{run_dir}`" if art_bits else f"per-step artifacts in `{run_dir}`"
lines.append(f"**Recorded evidence (local, gitignored by design):** {evid}")
lines.append("")
lines.append("<sub>Posted by launchproof/kit/post-proof.sh from a real browser run.</sub>")
print("\n".join(lines))
PYEOF

# ${arr[@]+...} form: macOS ships bash 3.2, where "${arr[@]}" on an empty
# array trips `set -u`. The + expansion is safe on every bash.
gh pr comment "$PR" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --body-file "$BODY_FILE"
echo "Posted LaunchProof verdict to PR #$PR."
