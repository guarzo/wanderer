# Deploy Approval Gate — Design

**Date:** 2026-08-07
**Status:** Approved (brainstorming session)
**Replaces:** Fly GitHub integration auto-deploying on push to `guarzo/release`
**Related:** `docs/superpowers/specs/2026-08-02-flyio-migration-design.md`, `ce58765b` (ci: drop the VM release pipeline)

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
| Trigger | Push to `guarzo/zoo` opens a deploy run that waits for approval |
| Gate | GitHub Environment `production-deploy` with required reviewer |
| Who talks to Fly | The workflow, via `flyctl deploy` with a scoped token |
| Fly GitHub integration | Disconnected — replaced, not run alongside |
| Tag timing | **After** a verified-healthy deploy, never before |
| `guarzo/release` | Retained as a CI-owned bookmark of what is in production |
| Preconditions | `Test Suite` must be green on the SHA before approval is offered |
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

## Architecture

One new workflow, `.github/workflows/zoo-deploy.yml`. The deleted `release.yml`
(recoverable at `ce58765b^`) is the starting point — it already carries the
tag-and-push logic, SHA-pinned actions, and a concurrency group.

### Trigger and gate

```yaml
on:
  push:
    branches: [guarzo/zoo]
  workflow_dispatch:
    inputs:
      ref:
        description: 'Tag or SHA to deploy (defaults to guarzo/zoo HEAD)'
        required: false
```

- **`concurrency: {group: zoo-deploy, cancel-in-progress: true}`.** Merging
  three PRs before approving leaves one pending approval for the newest SHA, not
  three stale runs queued in order. Deploying an intermediate commit that was
  already superseded is never the intent.
- **`environment: production-deploy`** on the deploying job. Nothing runs until
  approved. GitHub holds a pending run for 30 days, so a run may wait as long as
  needed. The repository is public, so environment protection rules are
  available at no cost, and GitHub permits a reviewer to approve their own
  deployment run.
- **Precondition:** the `Test Suite` check must be green on the exact SHA before
  approval is offered. Approval is a judgment about timing, not about whether
  the code works. `test.yml` already runs on every push to `guarzo/zoo`.

### Post-approval sequence

Strictly linear; each step runs only if the previous one succeeded. That
ordering is what makes the tag trustworthy.

1. **Checkout the approved SHA** with `fetch-depth: 0` (annotated tagging needs
   full history).
2. **`flyctl deploy --app wanderer`** authenticated with `FLY_API_TOKEN`. Fly
   runs `release_command` first (`fly.toml:29` — migrations against
   `DIRECT_DATABASE_URL`), so a failed migration fails the deploy before new
   code serves traffic.
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
2. **Create a deploy-scoped token** — `fly tokens create deploy -a wanderer` —
   stored as repository secret `FLY_API_TOKEN`. Deploy-scoped rather than a
   personal org token, so a compromised runner cannot reach `kills`,
   `route-builder`, or other apps in the org.
3. **Create environment `production-deploy`** with the repository owner as
   required reviewer.
4. **Add a ruleset on `guarzo/release`** restricting direct pushes.

Then land `.github/workflows/zoo-deploy.yml`.

### Validation

First run is a `workflow_dispatch` against current `guarzo/zoo` HEAD. Approve
it, then confirm:

- the Fly release counter increments,
- `/health` passes and the machine stays up,
- a `v2026...` tag exists pointing at the expected SHA,
- `guarzo/release` has moved to that SHA.

This costs one deliberate restart to prove the pipeline, which is preferable to
discovering a broken pipeline during a real change.

### Reverting the whole design

Reconnect Fly's GitHub integration and delete the ruleset. `guarzo/release`
still tracks the same commits, so the current process resumes unchanged.

## Assumptions and unresolved risks

- **Unverified: interaction between the existing `production` environment and
  the new `production-deploy`.** A `production` environment exists (created
  2026-08-05, no protection rules), most likely by Fly's integration for its own
  deployment records. Using a separate name is the mitigation; the interaction
  itself has not been tested.
- **Unverified: whether disconnecting the GitHub integration affects anything
  else on the Fly app.** It is understood to be a build trigger rather than
  runtime configuration, but this has not been confirmed.
- **Assumed: `flyctl deploy` exits non-zero when the release fails its health
  check.** Steps 4 and 5 depend on this. To be confirmed during validation; if
  it does not hold, an explicit `flyctl status` / `/health` poll is needed
  before tagging.
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
