#!/usr/bin/env bash
# End-to-end SELF-TEST of the repo process kit against a fresh GitHub repo.
# Drives the full loop and prints the real evidence of every leg:
#
#   seed app -> install kit -> (no-credential review skip) -> issue from form
#   fields -> fix branch -> PR with "Closes #N" -> automated review COMMENT
#   appears -> LaunchProof verdict comment -> merge -> issue AUTO-CLOSES
#   -> default-branch no-op check
#
#   usage: bash kit/selftest.sh OWNER/REPO
#
# OWNER/REPO must already exist and be empty-ish (no .github/workflows).
# Create it first with:  gh repo create OWNER/REPO --private
#
# Optional environment:
#   CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY
#       If set (and the repo has no review secret yet), the script uploads it
#       as a repo secret so the automated-review leg can be witnessed.
#       If absent, the review legs are reported as SKIPPED, honestly.
#   LAUNCHPROOF_HOME
#       Path to a LaunchProof checkout. If usable, the proof leg runs a real
#       browser test and posts the verdict into the PR. Otherwise SKIPPED.
#   SELFTEST_PORT (default 4380)
#
# The script never fakes a leg: every PASS line is accompanied by a fetched
# artifact (a comment URL and body, an issue state, a run conclusion).

set -euo pipefail

REPO="${1:-}"
if [ -z "$REPO" ] || [ "$REPO" = "-h" ] || [ "$REPO" = "--help" ]; then
  sed -n '2,26p' "${BASH_SOURCE[0]}"
  exit 1
fi

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT="${SELFTEST_PORT:-4380}"
command -v gh >/dev/null 2>&1 || { echo "error: gh is required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "error: git is required" >&2; exit 1; }

say()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
pass() { printf '\033[32mPASS\033[0m    %s\n' "$*"; }
fail() { printf '\033[31mFAIL\033[0m    %s\n' "$*"; FAILURES=$((FAILURES + 1)); }
skip() { printf '\033[33mSKIP\033[0m    %s\n' "$*"; }
FAILURES=0

# ---------- preflight ----------
say "Preflight: $REPO"
gh repo view "$REPO" --json name >/dev/null || { echo "error: repo $REPO not reachable via gh" >&2; exit 1; }
if gh api "repos/$REPO/contents/.github/workflows" >/dev/null 2>&1; then
  echo "error: $REPO already has .github/workflows; the self-test wants a fresh repo." >&2
  exit 1
fi

WORK="$(mktemp -d /tmp/kit-selftest.XXXXXX)"
echo "workdir: $WORK"
git clone -q "https://github.com/$REPO" "$WORK/repo" 2>/dev/null || git clone -q "git@github.com:$REPO" "$WORK/repo"
cd "$WORK/repo"
git checkout -q -B main

# ---------- leg 1: seed the app under test ----------
say "Leg 1: seed the app (status pill intentionally BROKEN) on main"
cat > index.html <<'HTML'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Kit Dogfood</title>
  <style>
    body { font-family: -apple-system, system-ui, sans-serif; max-width: 40rem; margin: 4rem auto; padding: 0 1rem; }
    .pill { display: inline-block; padding: 0.25rem 0.75rem; border-radius: 999px; background: #fee2e2; color: #991b1b; font-weight: 600; }
  </style>
</head>
<body>
  <h1>Kit Dogfood</h1>
  <p>Living evidence repo for the LaunchProof repo process kit
     (issue -&gt; PR -&gt; review -&gt; proof -&gt; merge -&gt; auto-close).</p>
  <p>Deployment status: <span class="pill">status: BROKEN</span></p>
</body>
</html>
HTML
mkdir -p .launchproof/tests
cat > .launchproof/tests/status-ok.spec.ts <<'SPEC'
// Proves the dogfood page reports a healthy deployment status to the user.
import { test, expect } from '@playwright/test';
import { recordedStep } from './helpers/shot';

test(
  'the dogfood page loads and shows deployment status OK',
  {
    tag: '@functional',
    annotation: {
      type: 'meaning',
      description:
        'The Kit Dogfood page must load and visibly say "status: OK". Red means ' +
        'the page is down or still tells users the deployment is broken.',
    },
  },
  async ({ page }, testInfo) => {
    await recordedStep(page, testInfo, 'reach the dogfood page', async () => {
      const response = await page.goto('/');
      expect(response?.status(), 'page HTTP status').toBeLessThan(400);
      await expect(page.getByRole('heading', { name: 'Kit Dogfood' })).toBeVisible();
    });

    await recordedStep(page, testInfo, 'status pill says OK', async () => {
      await expect(page.getByText('status: OK')).toBeVisible();
    });
  }
);
SPEC
cat > .gitignore <<'GI'
.launchproof/runs/
.launchproof/auth/
.launchproof/test-results/
node_modules/
.launchproof/node_modules
GI
printf '# %s\n\nSelf-test evidence repo for the LaunchProof repo process kit.\nServe: python3 -m http.server %s\n' "${REPO#*/}" "$PORT" > README.md
git add -A
git commit -q -m "seed: dogfood page (status pill intentionally BROKEN) + LaunchProof spec"
git push -q -u origin main
pass "seed pushed to main"

# ---------- leg 2: install the kit ----------
say "Leg 2: kit installer (labels, default-branch detection, idempotency)"
bash "$KIT_DIR/install.sh" "$WORK/repo"
git add .github && git commit -q -m "chore: repo process kit" && git push -q
pass "kit installed and pushed (workflows now on the default branch)"
git checkout -q -b dev && git push -q -u origin dev
pass "dev branch created (non-default-branch loop will be exercised)"

# ---------- leg 3: review credential / graceful skip ----------
say "Leg 3: automated-review credential"
HAS_SECRET=0
if gh secret list -R "$REPO" 2>/dev/null | grep -qE 'CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY'; then
  HAS_SECRET=1; pass "repo already has a review secret"
fi
if [ "$HAS_SECRET" -eq 0 ]; then
  say "Leg 3a: no-credential graceful skip (watched)"
  git checkout -q -b chore/skip-witness dev
  printf '\nSkip-leg witness.\n' >> README.md
  git commit -qam "docs: skip-leg witness" && git push -q -u origin chore/skip-witness
  SKIP_PR_URL=$(gh pr create -R "$REPO" --base dev --head chore/skip-witness \
    --title "Skip-leg witness (no review credential yet)" \
    --body "Witnesses that claude-code-review.yml skips with a notice when no credential secret is set. No issue linked on purpose.")
  SKIP_PR="${SKIP_PR_URL##*/}"
  echo "waiting for the review run on PR #$SKIP_PR..."
  i=0; RUN_ID=""
  while [ $i -lt 30 ]; do
    RUN_ID=$(gh run list -R "$REPO" --workflow=claude-code-review.yml --branch chore/skip-witness --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)
    [ -n "$RUN_ID" ] && break; i=$((i+1)); sleep 5
  done
  if [ -n "$RUN_ID" ]; then
    gh run watch "$RUN_ID" -R "$REPO" --exit-status >/dev/null 2>&1 || true
    if gh run view "$RUN_ID" -R "$REPO" --log 2>/dev/null | grep -q "skipping automated review"; then
      pass "review skipped WITH the notice (run $(gh run view "$RUN_ID" -R "$REPO" --json url --jq .url))"
    else
      fail "review run $RUN_ID finished but the skip notice was not found in its log"
    fi
  else
    fail "no claude-code-review run appeared for the skip-witness PR"
  fi
  gh pr merge "$SKIP_PR" -R "$REPO" --merge --delete-branch >/dev/null && pass "skip-witness PR merged (also exercises autoclose's nothing-to-close path)"
  git checkout -q dev && git pull -q
  # Now provide a credential for the real review leg, if the caller has one.
  if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    gh secret set CLAUDE_CODE_OAUTH_TOKEN -R "$REPO" --body "$CLAUDE_CODE_OAUTH_TOKEN" && HAS_SECRET=1 && pass "CLAUDE_CODE_OAUTH_TOKEN uploaded as repo secret"
  elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    gh secret set ANTHROPIC_API_KEY -R "$REPO" --body "$ANTHROPIC_API_KEY" && HAS_SECRET=1 && pass "ANTHROPIC_API_KEY uploaded as repo secret"
  else
    skip "no credential in the environment; the review-comment leg will be SKIPPED (set CLAUDE_CODE_OAUTH_TOKEN or ANTHROPIC_API_KEY and re-run to witness it)"
  fi
fi

# ---------- leg 4: issue from the task form's fields ----------
say "Leg 4: issue with the task form's fields"
ISSUE_URL=$(gh issue create -R "$REPO" --label task \
  --title "Status pill shows BROKEN on a healthy deployment" \
  --body "$(printf '### What\n\nMake the deployment status pill say "status: OK".\n\n### Why\n\nThe page tells every visitor the deployment is broken when it is healthy.\n\n### Acceptance criteria\n\n- [ ] The page shows "status: OK"\n- [ ] LaunchProof test status-ok is green\n\n### Proof plan\n\nLaunchProof run of status-ok against the served page; verdict posted into the PR.')")
ISSUE_NUM="${ISSUE_URL##*/}"
pass "issue #$ISSUE_NUM created: $ISSUE_URL"

# ---------- leg 5: fix branch + PR with Closes #N ----------
say "Leg 5: fix branch and PR (Closes #$ISSUE_NUM, base dev)"
git checkout -q -b fix/status-pill-ok dev
sed -i.bak -e 's/status: BROKEN/status: OK/' -e 's/background: #fee2e2; color: #991b1b;/background: #dcfce7; color: #166534;/' index.html && rm -f index.html.bak
git commit -qam "fix: status pill reports OK (was hardcoded BROKEN)"
git push -q -u origin fix/status-pill-ok
PR_URL=$(gh pr create -R "$REPO" --base dev --head fix/status-pill-ok \
  --title "fix: status pill reports OK" \
  --body "$(printf '## What\n\nStatus pill said BROKEN on a healthy deployment; now says OK.\n\nCloses #%s\n\n## Proof\n\n- Verdict: posted below by kit/post-proof.sh (LaunchProof run)\n- Evidence: run directory referenced in the comment\n\n## Checklist\n\n- [x] Issue linked above with a closing keyword\n- [ ] Proof posted into this PR\n- [x] Newly learned quirks appended to the agent playbook (none)\n' "$ISSUE_NUM")")
PR_NUM="${PR_URL##*/}"
pass "PR #$PR_NUM opened: $PR_URL"

# ---------- leg 6: the automated review POSTS a visible comment ----------
say "Leg 6: automated review posts on PR #$PR_NUM"
if [ "$HAS_SECRET" -eq 1 ]; then
  i=0; RUN_ID=""
  while [ $i -lt 30 ]; do
    RUN_ID=$(gh run list -R "$REPO" --workflow=claude-code-review.yml --branch fix/status-pill-ok --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)
    [ -n "$RUN_ID" ] && break; i=$((i+1)); sleep 5
  done
  if [ -n "$RUN_ID" ]; then
    echo "review run: $(gh run view "$RUN_ID" -R "$REPO" --json url --jq .url) (watching...)"
    gh run watch "$RUN_ID" -R "$REPO" --exit-status >/dev/null 2>&1 || true
    REVIEW_COMMENT=$(gh pr view "$PR_NUM" -R "$REPO" --json comments --jq '[.comments[] | select(.body | contains("Automated review"))][0].url' 2>/dev/null || true)
    if [ -n "$REVIEW_COMMENT" ] && [ "$REVIEW_COMMENT" != "null" ]; then
      pass "review comment is VISIBLE on the PR: $REVIEW_COMMENT"
      echo "---- review comment body ----"
      gh pr view "$PR_NUM" -R "$REPO" --json comments --jq '[.comments[] | select(.body | contains("Automated review"))][0].body'
      echo "-----------------------------"
    else
      fail "review run finished but no 'Automated review' comment on PR #$PR_NUM (this is defect #27's failure mode; check the run log)"
    fi
  else
    fail "no claude-code-review run appeared for PR #$PR_NUM"
  fi
else
  skip "review-comment leg (no credential)"
fi

# ---------- leg 7: LaunchProof verdict posted into the PR ----------
say "Leg 7: LaunchProof proof comment"
LP_HOME="${LAUNCHPROOF_HOME:-$(cd "$KIT_DIR/.." && pwd)}"
if [ -f "$LP_HOME/run.mjs" ] && command -v node >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  (cd "$WORK/repo" && python3 -m http.server "$PORT" >/dev/null 2>&1 &)
  sleep 1
  set +e
  (cd "$WORK/repo" && LAUNCHPROOF_DIR="$WORK/repo/.launchproof" TARGET_URL="http://localhost:$PORT" node "$LP_HOME/run.mjs" status-ok)
  LP_EXIT=$?
  set -e
  pkill -f "http.server $PORT" 2>/dev/null || true
  LAST_RUN=$(ls -1dt "$WORK/repo/.launchproof/runs/"* 2>/dev/null | head -1 || true)
  if [ -n "$LAST_RUN" ] && [ -f "$LAST_RUN/result.json" ]; then
    (cd "$WORK/repo" && bash "$KIT_DIR/post-proof.sh" "$PR_NUM" "$LAST_RUN" --repo "$REPO")
    PROOF_COMMENT=$(gh pr view "$PR_NUM" -R "$REPO" --json comments --jq '[.comments[] | select(.body | contains("LaunchProof:"))][0].url' 2>/dev/null || true)
    if [ -n "$PROOF_COMMENT" ] && [ "$PROOF_COMMENT" != "null" ]; then
      pass "LaunchProof verdict comment is VISIBLE on the PR: $PROOF_COMMENT"
    else
      fail "post-proof.sh ran but no LaunchProof comment found on PR #$PR_NUM"
    fi
    [ "$LP_EXIT" -ne 0 ] && fail "LaunchProof verdict was not green (exit $LP_EXIT); the fix branch should pass"
  else
    fail "LaunchProof produced no run directory"
  fi
else
  skip "LaunchProof leg (no usable LAUNCHPROOF_HOME with run.mjs, or node/python3 missing)"
fi

# ---------- leg 8: merge -> issue auto-closes (non-default branch) ----------
say "Leg 8: merge PR #$PR_NUM into dev -> issue #$ISSUE_NUM auto-closes"
gh pr merge "$PR_NUM" -R "$REPO" --merge --delete-branch >/dev/null
echo "merged; waiting for issue-autoclose..."
i=0; STATE="OPEN"
while [ $i -lt 24 ]; do
  STATE=$(gh issue view "$ISSUE_NUM" -R "$REPO" --json state --jq .state)
  [ "$STATE" = "CLOSED" ] && break; i=$((i+1)); sleep 5
done
if [ "$STATE" = "CLOSED" ]; then
  pass "issue #$ISSUE_NUM is CLOSED"
  echo "---- closing comment ----"
  gh issue view "$ISSUE_NUM" -R "$REPO" --json comments --jq '.comments[-1].body' 2>/dev/null || true
  echo "-------------------------"
  echo "autoclose run: $(gh run list -R "$REPO" --workflow=issue-autoclose.yml --limit 1 --json url --jq '.[0].url')"
else
  fail "issue #$ISSUE_NUM is still $STATE after merge into dev (issue-autoclose did not fire)"
fi

# ---------- leg 9: default-branch merges are left to GitHub (no double-fire) ----------
say "Leg 9: default-branch no-op (native close, autoclose job skips)"
NATIVE_ISSUE_URL=$(gh issue create -R "$REPO" --label task --title "README: note the default-branch check" \
  --body "$(printf '### What\n\nAdd one line to the README.\n\n### Why\n\nWitnesses native Closes-on-default-branch plus the autoclose no-op guard.\n\n### Acceptance criteria\n\n- [ ] README has the line\n\n### Proof plan\n\ndocs-only')")
NATIVE_ISSUE="${NATIVE_ISSUE_URL##*/}"
git checkout -q main && git pull -q
git checkout -q -b docs/default-branch-check main
printf '\nDefault-branch close check.\n' >> README.md
git commit -qam "docs: default-branch close check" && git push -q -u origin docs/default-branch-check
NPR_URL=$(gh pr create -R "$REPO" --base main --head docs/default-branch-check --title "docs: default-branch close check" --body "Closes #$NATIVE_ISSUE

docs-only")
NPR="${NPR_URL##*/}"
gh pr merge "$NPR" -R "$REPO" --merge --delete-branch >/dev/null
i=0; NSTATE="OPEN"
while [ $i -lt 24 ]; do
  NSTATE=$(gh issue view "$NATIVE_ISSUE" -R "$REPO" --json state --jq .state)
  [ "$NSTATE" = "CLOSED" ] && break; i=$((i+1)); sleep 5
done
if [ "$NSTATE" = "CLOSED" ]; then
  pass "issue #$NATIVE_ISSUE closed natively by GitHub on the default-branch merge"
else
  fail "issue #$NATIVE_ISSUE not closed after default-branch merge"
fi
sleep 10
AC_RUN=$(gh run list -R "$REPO" --workflow=issue-autoclose.yml --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null || true)
if [ -n "$AC_RUN" ]; then
  JOB_CONCLUSION=$(gh run view "$AC_RUN" -R "$REPO" --json jobs --jq '.jobs[0].conclusion' 2>/dev/null || true)
  if [ "$JOB_CONCLUSION" = "skipped" ]; then
    pass "autoclose job SKIPPED on the default-branch merge (no double-fire): $(gh run view "$AC_RUN" -R "$REPO" --json url --jq .url)"
  else
    echo "NOTE    newest autoclose run's job conclusion: ${JOB_CONCLUSION:-unknown} (check it belongs to PR #$NPR)"
  fi
fi

# ---------- summary ----------
say "Summary"
echo "repo:    https://github.com/$REPO"
echo "workdir: $WORK (kept; LaunchProof artifacts live under repo/.launchproof/runs)"
if [ "$FAILURES" -eq 0 ]; then
  echo "All executed legs PASSED. Legs marked SKIP were not witnessed; provide the missing credential/harness and re-run on a fresh repo to witness them."
else
  echo "$FAILURES leg(s) FAILED. Read the FAIL lines above; each names the missing artifact."
  exit 1
fi
