# Belay — Commit Plan

One commit = one reviewable step. Every commit leaves `main` green.

## Conventions

- **Format:** [Conventional Commits](https://www.conventionalcommits.org) — `type(scope): summary`
- **Types:** `feat`, `fix`, `test`, `docs`, `chore`, `refactor`
- **Test-first:** write the spec, watch it fail locally, then implement. Spec and implementation land in the **same commit** so `main` never has a red build. (If you want the red step visible in history, do it on the feature branch and squash-merge.)
- **Branches:** `phase-N/<short-name>` per commit or small group, merged to `main`. Phase 0 lives on `spike/resume` and is **never merged**.
- **README rule:** any commit that changes public API updates `README.md` in the same commit.
- **Tags:** tag the last commit of each phase, e.g. `phase-1-complete`.

Checkbox each line as it lands. Paste the unchecked tail into `STATUS.md` when starting a new chat.

---

## Phase 0 — Spike (branch `spike/resume`, throwaway)

Goal: prove that a run killed with `kill -9` resumes at the right step. No gem, no DSL.

- [ ] `chore(spike): generate bare Rails 7.1 app with Postgres`
- [ ] `feat(spike): add minimal runs and steps tables`
- [ ] `feat(spike): hardcoded three-step executor that checkpoints each step`
- [ ] `feat(spike): write started row before the step call`
- [ ] `test(spike): script that kills executor mid-step and restarts it`
- [ ] `docs(spike): record findings` → the only thing cherry-picked to `main` (as `docs: add phase 0 spike findings to DECISIONS.md`)

**Done when:** killing at every boundary and restarting always finishes with each step checkpointed exactly once.

---

## Phase 1 — Core runtime (3–4 weeks)

### 1a. Skeleton
- [ ] `chore: scaffold belay gem (Ruby 3.2+, Rails 7.1+, MIT)`
- [ ] `chore: add RSpec, RuboCop and GitHub Actions CI with Postgres service`
- [ ] `chore: add spec/dummy Rails app for integration specs`
- [ ] `docs: add README skeleton with target API`
- [ ] `feat(config): add Belay.configure with defaults`

### 1b. Persistence
- [ ] `feat(generator): add belay:install generator creating belay_runs migration`
- [ ] `feat(generator): add belay_steps migration with unique [run_id, position, attempt]`
- [ ] `feat(models): add Belay::Run with status enum and guarded transitions`
- [ ] `feat(models): add Belay::Step with kind and status enums`

### 1c. Workflow DSL
- [ ] `feat(dsl): add Belay::Workflow with input and step declarations`
- [ ] `feat(dsl): compute workflow_version from step names, kinds and order`
- [ ] `feat(context): add Belay::Context exposing input and prior step outputs`

### 1d. Providers
- [ ] `feat(providers): define provider interface and response value object`
- [ ] `feat(providers): add FakeProvider with scripted responses`

### 1e. Executor
- [ ] `feat(executor): execute steps in order and checkpoint outputs`
- [ ] `feat(executor): persist started row in its own transaction before calling out`
- [ ] `feat(executor): skip steps whose output is already checkpointed`
- [ ] `feat(executor): support retries: with one row per attempt`
- [ ] `feat(idempotency): expose stable step_idempotency_key (run_id + position)`
- [ ] `feat(executor): retry orphaned started steps only when idempotent: true`
- [ ] `feat(executor): mark non-idempotent orphaned steps needs_review`
- [ ] `feat(runs): add Workflow.start with idempotency_key deduplication`

### 1f. Leases & scheduling
- [ ] `feat(leases): acquire run lease via conditional UPDATE`
- [ ] `feat(leases): heartbeat lease while a step is in flight`
- [ ] `feat(jobs): add ResumeRunJob`
- [ ] `feat(jobs): add JanitorJob to reclaim expired leases`

### 1g. Real provider
- [ ] `feat(providers): add Anthropic provider recording tokens, cost and latency`
- [ ] `feat(llm): add llm helper with schema validation of structured output`

### 1h. Credibility tests
- [ ] `test(crash): kill executor at every step boundary and assert resume`
- [ ] `test(concurrency): assert only one of two workers advances a run`
- [ ] `test(property): any crash point converges to the same final state`

### 1i. Close out
- [ ] `docs: document delivery guarantees (at-least-once, exactly-once for idempotent)`
- [ ] `chore(release): bump version to 0.1.0.pre1` → tag `phase-1-complete`

---

## Phase 2 — Gates & dashboard (2 weeks)

- [ ] `feat(dsl): add gate declaration with when: condition`
- [ ] `feat(executor): checkpoint gate as skipped when condition is false`
- [ ] `feat(generator): add belay_approvals migration`
- [ ] `feat(models): add Belay::Approval`
- [ ] `feat(executor): pause run on gate, release lease and exit cleanly`
- [ ] `feat(runs): add pending_gate`
- [ ] `feat(runs): add approve! and reject! that enqueue ResumeRunJob`
- [ ] `feat(runs): support approve! with edited payload`
- [ ] `feat(engine): add mountable Belay::Engine with authentication hook`
- [ ] `feat(dashboard): runs index with status and workflow filters`
- [ ] `feat(dashboard): run page with step timeline, prompt, response, tokens and cost`
- [ ] `feat(dashboard): approve, reject and edit actions for pending gates`
- [ ] `feat(dashboard): surface needs_review steps with resolve actions`
- [ ] `docs: document gates, approvals and mounting the dashboard` → tag `phase-2-complete`

---

## Phase 3 — Replay (2 weeks)

- [ ] `feat(generator): add replay_of_id to belay_runs`
- [ ] `feat(replay): add Run#replay(model:) creating a shadow run`
- [ ] `feat(replay): serve tool and non-LLM steps from recorded outputs by default`
- [ ] `feat(replay): reuse recorded gate decisions in shadow runs`
- [ ] `feat(replay): refuse or warn on workflow_version mismatch`
- [ ] `feat(replay): compute per-step output diff`
- [ ] `feat(dashboard): side-by-side replay diff view`
- [ ] `docs: document replay and its side-effect policy` → tag `phase-3-complete`

---

## Phase 4 — Cost reduction (2–3 weeks)

- [ ] `feat(generator): add belay_cache_entries migration`
- [ ] `feat(cache): derive cache key from model, prompt, schema and params`
- [ ] `feat(cache): opt-in exact-match cache for decision steps only`
- [ ] `feat(cache): record cache hits on step rows at zero cost`
- [ ] `feat(cache): TTL expiry and hit counters`
- [ ] `feat(generator): add belay_rules migration`
- [ ] `feat(rules): check learned rules before any provider call`
- [ ] `feat(rules): learn rule after N consistent approved decisions`
- [ ] `feat(dashboard): chart of API calls per 100 runs over time`
- [ ] `docs: document caching and rules, including what is never cached` → tag `phase-4-complete`

---

## Phase 5 — Ship (2 weeks)

- [ ] `docs: README with crash-and-resume GIF`
- [ ] `docs: add docs site`
- [ ] `chore: add CHANGELOG and complete gemspec metadata`
- [ ] `chore(release): release 0.1.0 to RubyGems` → tag `v0.1.0`
- Demo invoice app lives in its own repo (`belay-demo`) with its own history.
