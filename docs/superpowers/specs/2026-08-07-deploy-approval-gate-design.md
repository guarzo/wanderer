# Deploy Approval Gate — Design

**Date:** 2026-08-07
**Status:** Approved (brainstorming session)
**Replaces:** Fly GitHub integration auto-deploying on push to `guarzo/release`
**Related:** `docs/superpowers/specs/2026-08-02-flyio-migration-design.md`, `ce58765b` (ci: drop the VM release pipeline)

## Amendment — 2026-08-07, during implementation

**`guarzo/release` is retired, not retained as a CI-owned bookmark.** Everything
below describing the workflow force-pushing that branch as its final step no
longer holds. The workflow deploys and tags; the newest `v20*` tag is the sole
record of what is in production, and `guarzo/release` is frozen by a ruleset with
an empty bypass list.

Two things forced the change:

1. **The Actions bypass actor is unavailable on user-owned repositories.**
   `guarzo/wanderer` is owned by a user, not an org. Creating the ruleset with
   `{"actor_type": "Integration", "actor_id": 15368}` returns HTTP 422:
   *"Actor GitHub Actions integration must be part of the ruleset source or
   owner organization."* This invalidates the section *Permissions and the
   `guarzo/release` ruleset* below, whose open question — whether a bypass actor
   can force-push — turns out to be unanswerable as posed. A `DeployKey` bypass
   actor **is** accepted (verified against a disposable probe ruleset), but it
   costs a long-lived SSH key with write access to every branch, stored beside
   the Fly deploy token.
2. **Given that, the bookmark was not worth its own credential.** Its only
   consumers were `git diff guarzo/release..guarzo/zoo` and human reassurance —
   both of which the tag already serves. Retiring it removes a ref that is
   authoritative-looking but only conditionally accurate, and removes the last
   thing in the design that needed write access beyond `GITHUB_TOKEN`.

**What this costs:** `git diff guarzo/release..guarzo/zoo` is replaced by
`git diff "$(git tag -l 'v20*' | sort | tail -1)"..guarzo/zoo`.

**What it does not cost:** tag reachability across rebases — the original reason
tags matter — was always the tag's job, never the branch's. The section *A failed
deploy produces no tag and does not move the bookmark* still holds with the
bookmark clause dropped; the partial-failure window narrows from three steps to
two.

The runbook in `docs/ZOO-FORK.md` and the plan at
`docs/superpowers/plans/2026-08-07-deploy-approval-gate.md` reflect the amended
design. Where they disagree with the text below, they govern.

## Problem

Two problems, discovered together.

**1. Promotion is a silent manual step.** Work merges to `guarzo/zoo`. Production
only moves when `guarzo/release` is hard-reset to `guarzo/zoo` and pushed, which
Fly's GitHub integration watches. Forgetting the reset produces no signal
anywhere — the merge succeeds, CI is green, and production quietly keeps serving
the old commit until someone notices a shipped change missing.

**2. Deploy tags stopped being created.** `.github/workflows/release.yml` created
a `v$(date +%Y%m%d%H%M%S)` tag on every promotion. It was deleted on 2026-08-05
in `ce58765b` along with the rest of the VM release pipeline, because it also
built and SSH-deployed to a host that no longer serves traffic. Deleting it
removed the tagging as collateral damage.

Evidence the tagging is gone:

| Event | Timestamp (UTC) |
|---|---|
| Last tag created (`v20260805165448`) | 2026-08-05 16:54 |
| `release.yml` deleted (`ce58765b`) | 2026-08-05 17:09 |
| Fly release v9 | 2026-08-07 18:02 — no tag |
| Fly release v10 | 2026-08-07 18:17 — no tag |

This matters more on this fork than it would elsewhere. `guarzo/zoo` is
regularly rebased onto upstream and has commits squashed, so a deployed commit
with nothing pointing at it becomes unreachable. Since 2026-08-05 the only
record of what is in production has been a Fly image ref
(`registry.fly.io/wanderer:deployment-<hash>`), which is not checkout-able and
does not survive a rewrite.

## Goal

Make promotion to production a **deliberate, single-click decision** that cannot
be silently forgotten, and restore an immutable tag on every deploy — where the
tag means *"this commit served production traffic"*, not merely *"this commit
was promoted"*.

Explicitly **not** a goal: continuous deployment. "Deploy is a decision" is a
desired property, not a limitation to remove.

## Decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Trigger | A **successful `Test Suite` run** on `guarzo/zoo` opens a deploy run that waits for approval (`workflow_run`, not `push`) |
| Gate | GitHub Environment `production-deploy` with required reviewer |
| Who talks to Fly | The workflow, via `flyctl deploy` with a scoped token |
| Fly GitHub integration | Disconnected — replaced, not run alongside |
| Tag timing | **After** a verified-healthy deploy, never before |
| `guarzo/release` | Retained as a CI-owned bookmark of what is in production |
| Concurrency | One non-cancellable deploy job (`cancel-in-progress: false`); stale approvals are neutralized by a post-approval staleness guard, not by cancellation |
| Deploy credential | Stored as an **environment** secret on `production-deploy`, not a repository secret |
| Rollback | `workflow_dispatch` with a `ref` input (tag or SHA) |

### Rejected alternatives

- **Gate promotes `guarzo/release`, Fly's webhook still deploys.** Smaller
  change, but the workflow hands off to a webhook and never learns whether the
  deploy succeeded — so the tag would still only mean "approved". It also
  depends on Fly's integration firing on a force-push, which is unverified and
  becomes necessary the moment `guarzo/zoo` is rebased.
- **`workflow_dispatch`-only, no push trigger.** Simplest, but does not solve
  problem 1: it remains an action that can be forgotten. The pending-approval
  run appearing after every merge is precisely what makes this work.
- **Auto-deploy every merge to `guarzo/zoo`.** Removes the failure mode
  entirely, but discards the "deploy is a decision" property, which is wanted.
- **`on: push` trigger with the test suite as a stated precondition.** This was
  the first draft of this design. It does not work: an environment gate does not
  wait on another workflow's checks, so the approval prompt appears while the
  suite is still running, and a red commit can be approved and shipped. Replaced
  by the `workflow_run` trigger.
- **A single concurrency group with `cancel-in-progress: true`.** Also from the
  first draft. It correctly coalesces pending approvals but also cancels a run
  that is mid-deploy, which changes production without tagging or bookmarking
  it. Replaced by a non-cancellable job plus a staleness guard.
- **Two jobs: a gate job and a separate deploy job.** Proposed while applying
  the review findings, then rejected: a protected environment gates every job
  referencing it (two approval prompts), and the environment-scoped
  `FLY_API_TOKEN` cannot be read by a job outside the environment or passed in
  from one. Replaced by a single gated job.

## Architecture

One new workflow, `.github/workflows/zoo-deploy.yml`. The deleted `release.yml`
(recoverable at `ce58765b^`) is the starting point — it already carries the
tag-and-push logic, SHA-pinned actions, and a concurrency group.

### Trigger and gate

The deploy workflow is **not** triggered by the push directly. It is triggered by
the test workflow finishing successfully on `guarzo/zoo`:

```yaml
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
```

with `if: github.event.workflow_run.conclusion == 'success'` on the first job,
and the deployed commit taken from `github.event.workflow_run.head_sha` rather
than from `github.ref`.

**Why not `on: push`.** An environment gate does not wait for another workflow's
checks. `Test Suite` is a separate workflow (`.github/workflows/test.yml`) whose
`gate` job is named `Test Suite` (`test.yml:334-335`) and is wired to the
`guarzo/zoo` ruleset for pull requests — nothing connects it to a push-triggered
deploy run. On a plain `push` trigger the approval prompt would appear
immediately, and a commit whose tests were still running, or already red, could
be approved and shipped. `workflow_run` makes the dependency real: a red suite
can never reach the approval prompt.

`workflow_run` evaluates its workflow file from the default branch, which is
`guarzo/zoo` — the branch being deployed — so this trigger works without extra
configuration.

**Failure and cancellation of the test run** are handled by the job's `if:`
condition: any conclusion other than `success` (`failure`, `cancelled`,
`timed_out`, `skipped`) skips the job.

Note precisely what this does and does not do. `workflow_run` offers **no
conclusion filter on the trigger itself**, so GitHub creates a deploy run for
*every* completion of the test suite, red or green. The `if:` condition operates
one level down: it skips the single job, so no environment is referenced, no
approval is requested, and the deploy credential is never released.

The observable consequence is that the Actions tab accumulates **skipped** deploy
runs after failed suites. That is the mechanism working. The invariant is "a red
commit cannot reach the approval prompt", not "a red commit produces no run" —
the latter is not achievable with this trigger, and any validation written
against it would fail on a correct implementation.

### Concurrency: one non-cancellable job, with a staleness guard

A **single** `deploy` job carries both the environment gate and all the work,
with job-level `concurrency: {group: zoo-deploy-run, cancel-in-progress: false}`.

**Why not split gate and deploy into two jobs.** Two reasons compound:

1. A protected environment gates **every job that references it**, so a
   `await-approval` job plus a `deploy` job produces two approval prompts per
   release.
2. `FLY_API_TOKEN` is an environment secret (see Rollout), readable only by a
   job declaring `environment: production-deploy`. The deploy job must therefore
   reference the environment — it cannot delegate the gate to a predecessor.
   Secrets cannot be passed between jobs via outputs.

The approval-scoped credential is what forces the deploy work inside the gated
job. Accepting two prompts to keep a tidy job graph is the wrong trade.

**Why `cancel-in-progress: false`.** GitHub's cancellation applies to *running*
jobs, not only to runs waiting on approval. A merge landing mid-`flyctl deploy`
would cancel the workflow while Fly's builder continues remotely — production
changes, and the tag and bookmark steps never run. That is precisely the failure
this design exists to prevent, reintroduced by the mechanism meant to tidy the
approval queue. `false` also serializes deploys: a second approved run queues
behind the first rather than racing it onto the single machine.

**Staleness guard replaces cancellation.** Because runs are never cancelled,
approving an old pending run would otherwise deploy a superseded commit. The
first step after approval compares the resolved SHA against the current
`origin/guarzo/zoo` tip and **exits successfully without deploying** when they
differ. Approving a stale run is then a no-op rather than a regression.

The guard applies to `workflow_run` runs only. Under `workflow_dispatch` it is
skipped entirely — deploying a ref that is *not* the branch tip is exactly what
rollback is for.

**Accepted cost:** stale pending approvals accumulate in the Actions tab instead
of auto-cancelling, and are dismissed manually. In exchange: one approval per
deploy, and no cancellation path into a running deploy.


### The approval gate

**`environment: production-deploy`** on the deploying job. Nothing runs until
approved. The repository is public, so environment protection rules are
available at no cost.

**Pending runs expire after 30 days** and are then marked failed. This is a real
bound, not "wait as long as you like". It is acceptable rather than mitigated: a
run that has sat unapproved for 30 days is itself a signal, and any subsequent
push to `guarzo/zoo` opens a fresh run against a newer SHA. No expiry-renewal
mechanism is specified, deliberately.

**Self-approval must be confirmed, not assumed.** GitHub is understood to permit
a reviewer to approve a run they triggered, but with a single required reviewer
this is load-bearing — if it does not hold, the gate is unopenable. Verify
before relying on it (see Validation).


### Post-approval sequence

Strictly linear; each step runs only if the previous one succeeded. That
ordering is what makes the tag trustworthy.

1. **Checkout the approved SHA** — `github.event.workflow_run.head_sha` for
   `workflow_run` runs, or the `ref` input for `workflow_dispatch` — with
   `fetch-depth: 0` (annotated tagging needs full history). Never `github.ref`:
   under `workflow_run` that resolves to the default branch's tip at trigger
   time, not the tested commit.
2. **`flyctl deploy --app wanderer`** authenticated with the `FLY_API_TOKEN`
   environment secret. Fly runs `release_command` first (`fly.toml:29` —
   migrations against `DIRECT_DATABASE_URL`), so a failed migration fails the
   deploy before new code serves traffic.
3. **Wait for healthy.** Under `strategy = 'rolling'` (`fly.toml:30`),
   `flyctl deploy` blocks on the `/health` check (`fly.toml:84-88`;
   route at `lib/wanderer_app_web/router.ex:391`). An unhealthy machine fails
   the step.
4. **Tag the SHA** — `v$(date +%Y%m%d%H%M%S)`, annotated, message recording the
   short SHA and the Fly release version. Push the tag.
5. **Move `guarzo/release`** to that SHA. This is a force-push: a `guarzo/zoo`
   rebase makes the update non-fast-forward, and the branch is a mirror by
   definition.

### Failure semantics

A failed deploy produces no tag and does not move the bookmark. `guarzo/release`
and the newest tag both continue to point at the last commit that actually
served traffic.

This is a real improvement over the current process, where `guarzo/release` is
moved *before* Fly attempts anything — so a failed deploy leaves the branch
asserting a success that never happened.

#### Partial failure after a successful deploy

Steps 2–5 are **not atomic**. If the deploy succeeds and step 4 or 5 then fails,
production has moved while the tag or bookmark has not — the one state that
contradicts the invariant this design is built on. It cannot be prevented, only
made recoverable and loud:

- **Bounded blast radius.** Only the tag/bookmark steps can fail this way. They
  are pure git operations against a known SHA, with no dependency on Fly.
- **Idempotent recovery.** Re-running the workflow via `workflow_dispatch` with
  `ref` set to the deployed SHA must converge rather than error. The tag name is
  generated from the clock, so a re-run would otherwise mint a *second* tag for
  the same commit. The tag step therefore looks for an existing `v*` tag
  pointing at HEAD and reuses it if present, creating a new one only when the
  commit is genuinely untagged. The bookmark force-push is idempotent by
  construction.
- **Loud, not silent.** A failure here fails the run, so the red run is the
  signal. The recovery is the `workflow_dispatch` re-run above; it redeploys the
  same SHA, which on this app costs one restart.

#### Permissions and the `guarzo/release` ruleset

The workflow needs `contents: write`, scoped to the deploy job only — the
default token is read-only, and the approval-gate job has no reason to hold
write access.

**The ruleset restricting pushes to `guarzo/release` will reject the workflow's
own push unless a bypass actor is configured for it.** This is the design's
sharpest self-inflicted failure mode: it surfaces at step 5, *after* a
successful production deploy, in exactly the partial-failure state described
above. The bypass must also permit **force-push** (non-fast-forward), since a
`guarzo/zoo` rebase guarantees the bookmark update is not a fast-forward.

Both behaviors — bypass actor and force-push permission — are verified during
validation rather than assumed, because the cost of getting them wrong is paid
in production.


### `guarzo/release` becomes CI-owned

It stops being the deploy trigger and becomes the answer to "what is in
production right now". A repository ruleset restricts direct pushes to the
workflow's actor, so the existing hard-reset-and-push habit is **refused** rather
than silently accepted and ignored — the loud failure that was missing. A
ruleset already exists on `guarzo/zoo`, so this follows an established pattern.

### Rollback

`workflow_dispatch` with `ref: v20260805165448`, approved, deploys that exact
tag. This capability does not currently exist: since 2026-08-05 no deployed
commit has had a checkout-able reference, so a bad deploy following a
`guarzo/zoo` rebase could strand the previous good commit as an orphan.

## Rollout

Order matters. Fly's integration is disconnected **first** so that no window
exists in which both it and the workflow deploy — on this app a deploy is a full
restart of the single machine with a user-visible gap (see the constraint
comment at the top of `fly.toml`), so a double-deploy is two outages for one
release. During the gap, `flyctl deploy` from a workstation remains a working
deploy path.

Manual steps, in order:

1. **Disconnect Fly's GitHub integration** for app `wanderer` (Fly dashboard →
   app → Settings).
2. **Create environment `production-deploy`** with the repository owner as
   required reviewer.
3. **Create a deploy-scoped token** — `fly tokens create deploy -a wanderer` —
   stored as an **environment secret on `production-deploy`**, not a repository
   secret. A repository secret is readable by any workflow running on a trusted
   branch; an environment secret is released only to a job that has cleared the
   approval gate. The design's whole premise is that nothing reaches production
   without approval, and the credential is part of "nothing". Deploy-scoped
   rather than a personal org token, so a compromised runner cannot reach
   `kills`, `route-builder`, or other apps in the org.
4. **Add a ruleset on `guarzo/release`** restricting direct pushes, with a
   bypass actor for the deploy workflow that permits force-push (see
   *Permissions and the `guarzo/release` ruleset*).

Then land `.github/workflows/zoo-deploy.yml`.

Step 2 precedes step 3 because the environment must exist before a secret can be
attached to it.

### Validation

First run is a `workflow_dispatch` against current `guarzo/zoo` HEAD. Approve
it, then confirm:

- **self-approval works** — the required reviewer can approve a run they
  triggered. If not, the gate is unopenable and a second reviewer or a different
  protection rule is needed. Check this first; everything else is moot if it
  fails.
- the Fly release counter increments,
- `/health` passes and the machine stays up,
- a `v2026...` tag exists pointing at the expected SHA,
- **`guarzo/release` has moved to that SHA** — this is the check that proves the
  ruleset bypass and force-push permission are configured correctly. It fails
  *after* a successful deploy, so verifying it deliberately here is what keeps
  it from being discovered during a real release.

Then confirm the trigger itself, which `workflow_dispatch` does not exercise:
push a trivial commit to `guarzo/zoo` and verify that no deploy run exists while
the suite is still running, that one appears in state `waiting` once it goes
green, and that a commit whose suite went red produces a **skipped** deploy run
that never reaches `waiting`.

Note also that **merging the workflow itself arms the automatic path**:
`test.yml` triggers on pushes to `guarzo/zoo` (`test.yml:6-7`), so the merge
commit's green suite opens a pending deploy run for the same SHA the validation
`workflow_dispatch` will target. The staleness guard cannot distinguish them —
both are the branch tip — so approving both would deploy one commit twice. The
automatic run is cancelled before validation begins.

This costs one deliberate restart to prove the pipeline, which is preferable to
discovering a broken pipeline during a real change.

### Reverting the whole design

**Order matters here too, in reverse.** Disable or delete
`.github/workflows/zoo-deploy.yml` **first**, then reconnect Fly's GitHub
integration, then drop the `guarzo/release` ruleset.

Reconnecting Fly while the workflow is still active recreates the double-deploy
this design removes, in a more confusing form: the workflow deploys, then pushes
`guarzo/release` as its final step, which triggers the reconnected integration
to deploy the same commit again — two restarts, the second one apparently
uncaused.

Once the workflow is gone, `guarzo/release` still tracks the same commits, so
the current process resumes unchanged.

## Assumptions and unresolved risks

- **Unverified: interaction between the existing `production` environment and
  the new `production-deploy`.** A `production` environment exists (created
  2026-08-05, no protection rules), most likely by Fly's integration for its own
  deployment records. Using a separate name is the mitigation; the interaction
  itself has not been tested.
- **Unverified: whether disconnecting the GitHub integration affects anything
  else on the Fly app.** It is understood to be a build trigger rather than
  runtime configuration, but this has not been confirmed.
- **Unverified: that GitHub permits self-approval of a deployment run.** With a
  single required reviewer this is load-bearing — if it does not hold, the gate
  cannot be opened at all. First item in the validation checklist.
- **Unverified: that a ruleset bypass actor can force-push to `guarzo/release`.**
  Required by step 5, and failing there leaves production deployed but
  unbookmarked. Also in the validation checklist.
- **Unverified: that a protected environment gates every job referencing it.**
  The single-job design assumes it does. If one approval in fact covers all jobs
  in a run, splitting gate and deploy becomes viable again — but the
  environment-scoped credential would still force the deploy work inside the
  gated job, so the single-job shape stands either way. Low-stakes to confirm.
- **Assumed: `flyctl deploy` exits non-zero when the release fails its health
  check.** Steps 4 and 5 depend on this. To be confirmed during validation; if
  it does not hold, an explicit `flyctl status` / `/health` poll is needed
  before tagging.
- **Accepted: steps 2–5 are not atomic.** See *Partial failure after a
  successful deploy*. Recovery is a `workflow_dispatch` re-run, at the cost of
  one restart.
- **Accepted: pending approvals expire after 30 days.** No renewal mechanism.
- **Not addressed: migration rollback.** `release_command` runs migrations
  forward. Deploying an older tag does not revert a schema change, so a
  destructive migration is still a manual recovery. Unchanged from today.

## Out of scope

- Staging or preview environments.
- Multi-machine or blue/green deploys — `fly.toml` documents the single-machine
  constraint, and lifting it requires cluster-aware map state.
- Changes to `test.yml` beyond consuming its result as a precondition.
- Upstream (`wanderer-industries`) workflows: `build.yml`, `build-develop.yml`,
  `advanced-test.yml`, `release_actions.yml` are untouched.
