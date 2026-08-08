# Deploy Approval Gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Fly's branch-watch auto-deploy with a GitHub Actions workflow that deploys `guarzo/zoo` to Fly only after a green test suite and an explicit human approval, then tags the deployed commit.

**Architecture:** One workflow (`.github/workflows/zoo-deploy.yml`) with a single gated job. It triggers on the `🧪 Test Suite` workflow succeeding on `guarzo/zoo`, waits on the `production-deploy` GitHub Environment for approval, verifies the commit is still current, runs `flyctl deploy`, and only then tags the SHA and moves `guarzo/release` to it as a bookmark. Fly's own GitHub integration is disconnected — the workflow replaces it rather than running alongside it.

**Tech Stack:** GitHub Actions, GitHub Environments (deployment protection rules), GitHub repository rulesets, Fly.io (`flyctl`), Docker build on Fly remote builders.

**Spec:** `docs/superpowers/specs/2026-08-07-deploy-approval-gate-design.md`

## Global Constraints

- **Repository:** `guarzo/wanderer`. Default branch is `guarzo/zoo`, which is regularly rebased onto upstream and has commits squashed.
- **Fly app name:** `wanderer`. Never `wanderer-*`; the other Fly apps (`kills`, `route-builder`) are separate services and must not be touched.
- **Exactly one machine.** `fly.toml:1-11` documents this as an architectural constraint: map state lives in node-local Cachex tables and a node-local Registry. Do not add autoscaling, raise machine counts, or change `[deploy].strategy` from `rolling`. Every deploy is a full restart with a user-visible gap.
- **Tag format:** `v$(date +%Y%m%d%H%M%S)` — matches the tags the deleted `release.yml` produced (e.g. `v20260805165448`). Do not switch to semver.
- **Deploy credential:** `FLY_API_TOKEN` is an **environment** secret on `production-deploy`, never a repository secret.
- **Pin every third-party action to a full commit SHA** with the version in a trailing comment. This matches the deleted `release.yml` and the surviving workflows.
- **Never cancel a running deploy.** `cancel-in-progress` must be `false` on the deploy job.
- **Do not modify** `.github/workflows/test.yml`, `build.yml`, `build-develop.yml`, `advanced-test.yml`, `release_actions.yml`, or `flaky-test-detection.yml`. The last four are upstream's.

## A note on verification in this plan

Most of this plan is CI configuration and GitHub/Fly settings, not application code, so there is no unit-test cycle to drive it. Verification is therefore **observation of real effects** — API queries against GitHub, `flyctl` output, and one deliberate production deploy — rather than assertions in a test file. Every task still ends with a concrete, checkable deliverable. Where a step's outcome cannot be verified without deploying, the plan says so instead of implying coverage it does not have.

## File Structure

| File | Status | Responsibility |
|---|---|---|
| `.github/workflows/zoo-deploy.yml` | Create | The entire deploy pipeline: trigger, gate, staleness guard, deploy, tag, bookmark |
| `docs/ZOO-FORK.md` | Modify | Document the deploy process so it stops being tribal knowledge |

No application code changes. No migrations.

## Task Sequence and Why It Is Ordered This Way

1. **Task 1 — operator prerequisites** (manual). Must precede everything: the workflow references an environment and a secret that must already exist, and Fly's integration must be disconnected before the workflow can deploy without double-deploying.
2. **Task 2 — the workflow file**, merged to `guarzo/zoo`. Both `workflow_run` and `workflow_dispatch` only see workflow files on the default branch, so the file must be merged before any run is possible.
3. **Task 3 — validation deploy** via `workflow_dispatch`. Proves the gate, the credential, the deploy, the tag, and the ruleset bypass.
4. **Task 4 — trigger validation** via a real push. Proves the part `workflow_dispatch` cannot exercise: that a deploy run appears only after a green suite.
5. **Task 5 — documentation.**

---

### Task 1: Operator prerequisites

**This task is performed by a human in the GitHub and Fly web UIs.** An agent cannot complete it — it requires dashboard access and secret material. An agent executing this plan should present these steps to the operator and wait, then run the verification steps.

**Files:** none — this is configuration in GitHub and Fly.

**Interfaces:**
- Produces: GitHub Environment `production-deploy` with a required reviewer; environment secret `FLY_API_TOKEN` scoped to it; a repository ruleset on `guarzo/release`; Fly app `wanderer` with no GitHub integration.

- [ ] **Step 1: Record the current deploy state, so a revert is possible**

Run:

```bash
flyctl releases -a wanderer | head -3
git rev-parse origin/guarzo/release
```

Write both down. If this task needs reverting, these are the values to return to.

- [ ] **Step 2: Disconnect Fly's GitHub integration**

In the Fly dashboard: app `wanderer` → Settings → find the GitHub integration/repository connection → disconnect.

This is **first** deliberately. Until Task 2 lands there is no CI deploy path, and `flyctl deploy` from a workstation is the interim one. Doing it last instead would mean the first workflow run deploys twice — two full restarts of the single machine for one release.

- [ ] **Step 3: Verify no push-triggered deploy remains**

Push any trivial commit to `guarzo/release` (or simply wait for the next one) and confirm no new Fly release appears:

```bash
flyctl releases -a wanderer | head -3
```

Expected: the release counter is unchanged from Step 1.

If a new release appears, the integration is still connected — stop and resolve that before continuing. Everything downstream assumes exactly one system deploys.

- [ ] **Step 4: Create the `production-deploy` environment**

GitHub → repository Settings → Environments → New environment → name it exactly `production-deploy`.

Do **not** reuse the existing `production` environment. It was created 2026-08-05, most likely by Fly's integration for its own deployment records, and the interaction is untested.

Enable **Required reviewers** and add yourself.

- [ ] **Step 5: Verify the environment exists with protection**

Run:

```bash
gh api repos/guarzo/wanderer/environments/production-deploy \
  --jq '{name, protection_rules: [.protection_rules[].type]}'
```

Expected: `{"name":"production-deploy","protection_rules":["required_reviewers"]}`

If `protection_rules` is empty, the reviewer was not saved — the gate would not gate anything.

- [ ] **Step 6: Create the Fly deploy token**

Run:

```bash
flyctl tokens create deploy -a wanderer
```

Copy the full output token, including the `FlyV1 ` prefix.

Deploy-scoped, not a personal org token: a compromised runner must not be able to reach `kills`, `route-builder`, or anything else in the org.

- [ ] **Step 7: Store it as an environment secret**

GitHub → Settings → Environments → `production-deploy` → **Environment secrets** → Add secret → name `FLY_API_TOKEN`, value from Step 6.

**Environment secret, not repository secret.** A repository secret is readable by any workflow on a trusted branch; an environment secret is released only to a job that has cleared the approval gate. The whole premise is that nothing reaches production without approval, and the credential is part of "nothing".

- [ ] **Step 8: Verify the secret is scoped to the environment, not the repo**

Run:

```bash
gh api repos/guarzo/wanderer/environments/production-deploy/secrets --jq '.secrets[].name'
gh api repos/guarzo/wanderer/actions/secrets --jq '.secrets[].name'
```

Expected: `FLY_API_TOKEN` appears in the **first** output and **not** in the second.

If it appears in the second, it was created as a repository secret — delete it there and redo Step 7.

- [ ] **Step 9: Add the `guarzo/release` ruleset with a bypass for Actions**

GitHub → Settings → Rules → Rulesets → New branch ruleset:

- Name: `guarzo/release protected`
- Enforcement: Active
- Target branches: include `refs/heads/guarzo/release`
- Rules: enable **Restrict updates** (blocks direct pushes)
- **Bypass list: add the `GitHub Actions` bypass actor** (Repository role / integration `GitHub Actions`), mode **Always**

The bypass is load-bearing. Without it the workflow's own push at the final step is rejected — *after* a successful production deploy, leaving production changed but untagged and unbookmarked. Verified for real in Task 3, because it cannot be verified any other way.

- [ ] **Step 10: Verify the ruleset and its bypass**

Run:

```bash
gh api repos/guarzo/wanderer/rulesets --jq '.[] | {id, name, enforcement}'
```

Note the id of `guarzo/release protected`, then:

```bash
gh api repos/guarzo/wanderer/rulesets/<ID> \
  --jq '{conditions: .conditions.ref_name.include, bypass: [.bypass_actors[] | {actor_type, bypass_mode}], rules: [.rules[].type]}'
```

Expected: the include list contains `refs/heads/guarzo/release`, `bypass` contains an entry with `"actor_type":"Integration"` (or `RepositoryRole`) and `"bypass_mode":"always"`, and `rules` contains `update`.

- [ ] **Step 11: Confirm a direct push is now refused**

Run:

```bash
git push origin origin/guarzo/zoo:guarzo/release --force
```

Expected: **rejected** by the ruleset, with a message naming the rule.

This is the point of the ruleset: the old hard-reset-and-push habit now fails loudly instead of silently doing nothing. A push that *succeeds* here means the ruleset is not protecting the branch — fix it before continuing.

---

### Task 2: The deploy workflow

**Files:**
- Create: `.github/workflows/zoo-deploy.yml`

**Interfaces:**
- Consumes: environment `production-deploy`, environment secret `FLY_API_TOKEN`, and the `guarzo/release` ruleset bypass from Task 1.
- Produces: a workflow named `🚀 Zoo Deploy` triggerable by `workflow_dispatch` (with an optional `ref` input) and by the `🧪 Test Suite` workflow completing on `guarzo/zoo`.

- [ ] **Step 1: Resolve the action SHAs to pin**

Every third-party action is pinned to a full commit SHA. Two are needed:

```bash
gh api repos/actions/checkout/git/ref/tags/v4 --jq '.object.sha'
gh api repos/superfly/flyctl-actions/git/ref/tags/master --jq '.object.sha'
```

If `superfly/flyctl-actions` has no `master` ref, list what it does have:

```bash
gh api repos/superfly/flyctl-actions/git/refs --jq '.[].ref'
```

Use the resolved SHAs in Step 2 in place of `<CHECKOUT_SHA>` and `<FLYCTL_SHA>`, keeping the trailing version comment.

- [ ] **Step 2: Write the workflow**

Create `.github/workflows/zoo-deploy.yml`:

```yaml
name: 🚀 Zoo Deploy

# Deploys are gated on a green test suite, so the trigger is the test workflow
# finishing — not the push itself. An environment gate does not wait for another
# workflow's checks, so `on: push` would offer approval while the suite is still
# running, and a red commit could be approved and shipped.
on:
  workflow_run:
    workflows: ["🧪 Test Suite"]
    types: [completed]
    branches: [guarzo/zoo]
  workflow_dispatch:
    inputs:
      ref:
        description: 'Tag or SHA to deploy (defaults to guarzo/zoo HEAD)'
        required: false
        type: string

# Default token is read-only; the job scopes itself up because it pushes a tag
# and moves a branch.
permissions:
  contents: read

jobs:
  deploy:
    name: Deploy to Fly
    # Any conclusion other than success — failure, cancelled, timed_out,
    # skipped — produces no deploy run at all. Silence means "not shippable",
    # never "shipped without checking".
    if: >-
      github.event_name == 'workflow_dispatch' ||
      github.event.workflow_run.conclusion == 'success'
    runs-on: ubuntu-latest

    # The gate AND the work live in one job on purpose. A protected environment
    # gates every job that references it, so splitting them would prompt twice;
    # and FLY_API_TOKEN is an environment secret, readable only by a job inside
    # the environment. Secrets cannot be passed between jobs.
    environment: production-deploy

    permissions:
      contents: write

    # NEVER set cancel-in-progress: true here. Cancellation applies to running
    # jobs, not just to runs awaiting approval: a merge landing mid-deploy would
    # kill this job while Fly's builder keeps going, changing production with no
    # tag and no bookmark. That is the exact failure this workflow exists to
    # prevent. `false` also serializes deploys onto the single machine.
    concurrency:
      group: zoo-deploy-run
      cancel-in-progress: false

    steps:
      - name: Resolve the ref to deploy
        id: resolve
        env:
          EVENT_NAME: ${{ github.event_name }}
          DISPATCH_REF: ${{ inputs.ref }}
          RUN_SHA: ${{ github.event.workflow_run.head_sha }}
        run: |
          set -euo pipefail
          if [ "$EVENT_NAME" = "workflow_dispatch" ]; then
            REF="${DISPATCH_REF:-guarzo/zoo}"
          else
            # NOT github.ref: under workflow_run that resolves to the default
            # branch tip at trigger time, which may not be the tested commit.
            REF="$RUN_SHA"
          fi
          echo "ref=$REF" >> "$GITHUB_OUTPUT"
          echo "Resolved deploy ref: $REF"

      - name: Check out the ref
        uses: actions/checkout@<CHECKOUT_SHA> # v4
        with:
          ref: ${{ steps.resolve.outputs.ref }}
          # Annotated tagging needs full history.
          fetch-depth: 0

      # Runs AFTER approval, which is the entire point: a run may sit pending
      # for hours while guarzo/zoo moves on. Because runs are never cancelled,
      # this is what stops an old approval from shipping a superseded commit.
      - name: Guard against a superseded commit
        id: guard
        env:
          EVENT_NAME: ${{ github.event_name }}
        run: |
          set -euo pipefail
          if [ "$EVENT_NAME" = "workflow_dispatch" ]; then
            echo "workflow_dispatch: staleness guard skipped — deploying a ref that is not the branch tip is what rollback is for."
            echo "proceed=true" >> "$GITHUB_OUTPUT"
            exit 0
          fi
          git fetch --quiet origin guarzo/zoo
          TIP="$(git rev-parse origin/guarzo/zoo)"
          HERE="$(git rev-parse HEAD)"
          if [ "$TIP" != "$HERE" ]; then
            echo "::notice title=Superseded::guarzo/zoo has moved to ${TIP}; this run was approved for ${HERE}. Nothing was deployed."
            echo "proceed=false" >> "$GITHUB_OUTPUT"
          else
            echo "proceed=true" >> "$GITHUB_OUTPUT"
          fi

      - name: Set up flyctl
        if: steps.guard.outputs.proceed == 'true'
        uses: superfly/flyctl-actions/setup-flyctl@<FLYCTL_SHA> # v1

      # Fly runs release_command first (fly.toml:29 — migrations against
      # DIRECT_DATABASE_URL), so a failed migration fails the deploy before new
      # code serves traffic. Under strategy = 'rolling' (fly.toml:30) this
      # blocks on the /health check (fly.toml:84-88).
      - name: Deploy to Fly
        if: steps.guard.outputs.proceed == 'true'
        id: deploy
        env:
          FLY_API_TOKEN: ${{ secrets.FLY_API_TOKEN }}
        run: |
          set -euo pipefail
          flyctl deploy --app wanderer --remote-only
          # Recorded in the tag message so a tag can be matched to a Fly release
          # without the dashboard. Best-effort: a lookup failure must not fail a
          # deploy that already succeeded.
          VERSION="$(flyctl releases --app wanderer --json | jq -r '.[0].version' || echo unknown)"
          echo "version=${VERSION}" >> "$GITHUB_OUTPUT"

      # Everything below runs only after a healthy deploy. That ordering is what
      # makes the tag mean "this commit served production traffic".
      - name: Tag the deployed commit
        if: steps.guard.outputs.proceed == 'true'
        id: tag
        run: |
          set -euo pipefail
          TAG="v$(date +%Y%m%d%H%M%S)"
          SHA="$(git rev-parse --short HEAD)"
          git config user.name "github-actions"
          git config user.email "github-actions@github.com"
          # Idempotent: a workflow_dispatch re-run recovering from a failed
          # bookmark push must converge, not error.
          if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
            echo "Tag ${TAG} already exists; leaving it alone."
          else
            git tag -a "${TAG}" -m "Deployed ${SHA} to Fly app wanderer (release v${{ steps.deploy.outputs.version }})"
            git push origin "${TAG}"
          fi
          echo "tag=${TAG}" >> "$GITHUB_OUTPUT"
          echo "Tagged ${SHA} as ${TAG}"

      # Force-push: guarzo/zoo is rebased regularly, so this is not a
      # fast-forward. Requires the ruleset bypass from Task 1 Step 9.
      - name: Move the guarzo/release bookmark
        if: steps.guard.outputs.proceed == 'true'
        run: |
          set -euo pipefail
          git push --force origin "HEAD:refs/heads/guarzo/release"
          echo "guarzo/release now points at $(git rev-parse HEAD)"

      - name: Summarize
        if: steps.guard.outputs.proceed == 'true'
        run: |
          {
            echo "### Deployed"
            echo ""
            echo "- commit: \`$(git rev-parse HEAD)\`"
            echo "- tag: \`${{ steps.tag.outputs.tag }}\`"
            echo "- app: \`wanderer\`"
          } >> "$GITHUB_STEP_SUMMARY"
```

- [ ] **Step 3: Verify the YAML parses**

Run:

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/zoo-deploy.yml')); print('parses OK')"
```

Expected: `parses OK`

A YAML error here would otherwise surface as a workflow that silently never appears in the Actions tab.

- [ ] **Step 4: Verify no action is left unpinned**

Run:

```bash
grep -n "uses:" .github/workflows/zoo-deploy.yml
```

Expected: every line has a 40-character hex SHA and a trailing `# v…` comment. No `@v4`, no `@master`, and no literal `<CHECKOUT_SHA>` / `<FLYCTL_SHA>` placeholders left from Step 2.

- [ ] **Step 5: Verify the two invariants that carry the most risk**

Run:

```bash
grep -n -A2 "concurrency:" .github/workflows/zoo-deploy.yml
grep -n "environment:" .github/workflows/zoo-deploy.yml
```

Expected: `cancel-in-progress: false`, and exactly one `environment: production-deploy` line.

`cancel-in-progress: true` here would let a merge kill a running deploy. A second `environment:` line would mean a second approval prompt.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/zoo-deploy.yml
git commit -m "ci: gated deploy workflow for guarzo/zoo

Triggers on a successful Test Suite run, waits on the production-deploy
environment for approval, then deploys to Fly and tags the commit only after
the release is healthy. Replaces Fly's branch-watch integration on
guarzo/release, which now becomes a CI-owned bookmark of what is in production."
```

- [ ] **Step 7: Open a PR and merge to `guarzo/zoo`**

```bash
git push -u origin HEAD
gh pr create --base guarzo/zoo --fill
```

Merge once `Test Suite` is green.

**This merge is a hard prerequisite for Task 3.** Both `workflow_run` and `workflow_dispatch` only see workflow files that exist on the default branch. Until this is merged, the workflow cannot be triggered at all — it will not even appear in the Actions tab.

- [ ] **Step 8: Verify the workflow is registered**

Run:

```bash
gh workflow list | grep -i "Zoo Deploy"
```

Expected: one row, state `active`.

If it does not appear, the file is not on `guarzo/zoo` or the YAML failed to parse server-side.

---

### Task 3: Validation deploy

Proves the pipeline end to end with a deliberate release. This costs one restart of the single machine — cheaper than discovering a broken pipeline during a real change.

**Files:** none.

**Interfaces:**
- Consumes: the merged workflow from Task 2 and all configuration from Task 1.
- Produces: confirmation that self-approval works, the credential resolves, the deploy succeeds, and the ruleset bypass permits the bookmark push.

- [ ] **Step 1: Record the pre-deploy state**

```bash
flyctl releases -a wanderer | head -3
git fetch origin --tags
git for-each-ref --sort=-creatordate --format='%(creatordate:iso) %(refname:short)' refs/tags | head -3
git rev-parse origin/guarzo/release origin/guarzo/zoo
```

Note the Fly release number, the newest tag, and both branch SHAs.

- [ ] **Step 2: Trigger the workflow**

```bash
gh workflow run "🚀 Zoo Deploy"
```

Then find the run:

```bash
gh run list --workflow "🚀 Zoo Deploy" --limit 1
```

- [ ] **Step 3: Verify it is waiting for approval, and approve it**

Expected: status `waiting`, not `in_progress` or `completed`.

If it ran straight through without waiting, the environment protection is not attached — stop, and recheck Task 1 Step 5.

Approve it in the GitHub UI (Actions → the run → Review deployments → Approve and deploy).

**This is the first thing to confirm and the most consequential.** If GitHub refuses to let you approve a run you triggered, the gate is unopenable with a single required reviewer, and the design needs a second reviewer or a different protection rule. Everything else is moot if this fails.

- [ ] **Step 4: Watch the run**

```bash
gh run watch
```

Expected: all steps green. Note in particular that `Guard against a superseded commit` reports the `workflow_dispatch` skip message rather than a staleness comparison.

- [ ] **Step 5: Verify the deploy actually happened**

```bash
flyctl releases -a wanderer | head -3
flyctl status -a wanderer
```

Expected: the release counter incremented by one from Step 1; the machine is `started` and passing health checks.

- [ ] **Step 6: Verify the tag**

```bash
git fetch origin --tags
git for-each-ref --sort=-creatordate --format='%(creatordate:iso) %(refname:short)' refs/tags | head -3
git rev-parse "$(git for-each-ref --sort=-creatordate --format='%(refname:short)' refs/tags | head -1)"
```

Expected: a new `v2026…` tag exists, newer than the one recorded in Step 1, pointing at the SHA that was deployed.

- [ ] **Step 7: Verify the bookmark moved — the step most likely to fail**

```bash
git fetch origin
git rev-parse origin/guarzo/release origin/guarzo/zoo
```

Expected: both print the same SHA.

**If the run failed at `Move the guarzo/release bookmark`,** the ruleset bypass from Task 1 Step 9 is misconfigured. Note that production is *already deployed* at this point — this is the partial-failure state the spec describes. Fix the bypass, then recover by re-running:

```bash
gh workflow run "🚀 Zoo Deploy" -f ref="$(git rev-parse origin/guarzo/zoo)"
```

and approving it. The tag step is idempotent and the deploy is a no-op change, at the cost of one more restart.

- [ ] **Step 8: Verify the app is actually serving**

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://wanderer.fly.dev/health
```

Expected: `200`.

Substitute the real public hostname if the app is served from a custom domain.

---

### Task 4: Trigger validation

`workflow_dispatch` cannot exercise the trigger itself. This task proves the property the whole design rests on: a deploy run appears **only** after a green suite.

**Files:** none (uses a throwaway commit).

**Interfaces:**
- Consumes: everything from Tasks 1–3.
- Produces: confirmation that `workflow_run` fires correctly and that a red suite produces no deploy run.

- [ ] **Step 1: Push a trivial commit to `guarzo/zoo`**

Any no-op change is fine — a comment or a whitespace fix in a file that does not affect behavior. Merge it the normal way.

- [ ] **Step 2: Verify the deploy run does NOT appear immediately**

Immediately after the merge:

```bash
gh run list --workflow "🚀 Zoo Deploy" --limit 3
gh run list --workflow "🧪 Test Suite" --limit 3
```

Expected: the `Test Suite` run is `in_progress`; **no** new Zoo Deploy run yet.

A Zoo Deploy run appearing here means the trigger is wrong — likely reverted to `on: push` — and a commit could be approved before its tests finish.

- [ ] **Step 3: Verify it appears after the suite goes green**

Once `Test Suite` completes successfully:

```bash
gh run list --workflow "🚀 Zoo Deploy" --limit 1
```

Expected: a new run, status `waiting` (awaiting approval).

- [ ] **Step 4: Verify the staleness guard, then leave the run unapproved**

Push a second trivial commit to `guarzo/zoo` and let its suite finish, so two runs are now pending. Approve the **older** one.

Expected: it completes successfully **without deploying**, and the `Guard against a superseded commit` step logs the `Superseded` notice naming the newer tip. The Fly release counter must be unchanged.

This is the behavior that replaces cancellation. If the older run deploys, the guard is broken and stale approvals can ship superseded commits.

- [ ] **Step 5: Approve the newest run, or dismiss both**

Either approve the newest pending run to ship the trivial commits, or cancel the pending runs to leave production where it is. Both are valid; just do not leave the queue ambiguous.

- [ ] **Step 6: Confirm a red suite produces no deploy run**

Push a commit that fails the suite — a deliberately broken test is simplest — to a branch, open a PR, and merge only if you are willing to ship it. **Safer alternative:** verify from history instead, by finding any past `Test Suite` run on `guarzo/zoo` with a `failure` conclusion and confirming no Zoo Deploy run shares its head SHA:

```bash
gh run list --workflow "🧪 Test Suite" --branch guarzo/zoo --status failure --limit 5 \
  --json headSha,conclusion,createdAt
gh run list --workflow "🚀 Zoo Deploy" --limit 20 --json headSha,createdAt
```

Expected: no overlap between the two `headSha` sets.

Prefer the history check. Deliberately merging a broken commit to the default branch to test a guard is not worth the risk on a fork that is regularly rebased.

---

### Task 5: Document the deploy process

The spec does not require this. It is included because the process being undocumented is what produced the original problem — the reason for the old `guarzo/release` reset had been forgotten, and the tags disappearing went unnoticed for two days.

**Files:**
- Modify: `docs/ZOO-FORK.md`

**Interfaces:**
- Consumes: the finished pipeline from Tasks 1–4.
- Produces: no code interface.

- [ ] **Step 1: Add the section**

Insert into `docs/ZOO-FORK.md` immediately **after** the `## Upstream PR Recommendations` section (currently starting at line 207) and **before** `## Key Files Reference` (currently line 272). That position keeps the seven TOC-listed sections contiguous — `## Key Files Reference` (272) and `## Maintenance Notes` (324) sit below the TOC's range and are not listed in it.

```markdown
## Deployment

Production is the Fly app `wanderer` (single machine — see the constraint
comment at the top of `fly.toml`).

**How a change reaches production:**

1. Merge to `guarzo/zoo`.
2. `🧪 Test Suite` runs. If it fails, nothing else happens.
3. On success, `🚀 Zoo Deploy` opens a run that **waits for approval** in the
   `production-deploy` environment. GitHub emails an approval request; the run
   also shows as pending in the Actions tab.
4. Approving it deploys to Fly, then tags the commit `v<UTC timestamp>` and
   moves `guarzo/release` to that commit.

**`guarzo/release` is CI-owned.** It is a bookmark of what is in production, not
a trigger. Direct pushes are rejected by a ruleset — resetting and pushing it by
hand does nothing except fail. This is deliberate: it used to be the deploy
trigger, and the change is easy to forget.

**Nothing deploys without approval**, including a run that has been sitting
pending. Pending approvals expire after 30 days.

**To roll back**, run `🚀 Zoo Deploy` manually with `ref` set to a previous tag
and approve it. Note that migrations only run forward — a rollback does not
revert a schema change.

**Approving a stale run is safe.** If `guarzo/zoo` has moved on since the run
was created, the workflow exits without deploying and says so.
```

- [ ] **Step 2: Add it to the table of contents**

In the `## Table of Contents` list at the top of `docs/ZOO-FORK.md` (lines 12–18), add as entry 8:

```markdown
8. [Deployment](#deployment)
```

- [ ] **Step 3: Verify the anchor resolves**

Run:

```bash
grep -n "^## Deployment" docs/ZOO-FORK.md
grep -n "(#deployment)" docs/ZOO-FORK.md
```

Expected: both return exactly one line.

- [ ] **Step 4: Commit**

```bash
git add docs/ZOO-FORK.md
git commit -m "docs: describe the gated deploy process

The old process was undocumented, which is how the guarzo/release reset became
folklore and how the deploy tags going away went unnoticed."
```

---

## Rollback for the whole change

Order matters, and it is the reverse of the rollout.

1. **Disable or delete `.github/workflows/zoo-deploy.yml`** first.
2. Reconnect Fly's GitHub integration to `guarzo/release`.
3. Delete the `guarzo/release` ruleset.
4. Optionally delete the `production-deploy` environment and its secret.

Reconnecting Fly while the workflow is still active recreates double deployment in a confusing form: the workflow deploys, then pushes `guarzo/release` as its final step, which triggers the reconnected integration to deploy the same commit again — two restarts, the second apparently uncaused.

`guarzo/release` still tracks the same commits throughout, so the old process resumes unchanged.

## Known risks carried into implementation

- **`flyctl deploy` may not exit non-zero on a failed health check.** The tag and bookmark steps depend on it. If Task 3 shows a deploy reported as successful while the machine is unhealthy, add an explicit `flyctl status` / `/health` poll between the deploy and tag steps.
- **Steps 2–5 of the job are not atomic.** A failure after the deploy leaves production changed but untagged. Recovery is the idempotent `workflow_dispatch` re-run in Task 3 Step 7, at the cost of one restart.
- **Self-approval is assumed and verified in Task 3 Step 3.** If it does not hold, the design needs a second reviewer.
- **`superfly/flyctl-actions/setup-flyctl` is a new dependency** on this repo. If pinning proves awkward, installing flyctl directly (`curl -L https://fly.io/install.sh | sh`) is a viable substitute, but a piped installer is a worse supply-chain posture than a pinned action.
