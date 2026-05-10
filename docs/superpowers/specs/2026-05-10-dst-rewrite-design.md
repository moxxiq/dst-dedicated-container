# DST + admin + bootstrap rewrite — design

**Status:** approved by user 2026-05-10. Implementation plan to follow via `superpowers:writing-plans`.

**Goal:** rewrite the DST dedicated-server appliance — container, admin panel, and Vultr bootstrap — from the spec in `CREATE/CREATE.md`, using `CREATE/old/` as reference but not copy. Avoid all rakes catalogued in `CREATE/CREATE.md §7` and fix the latent issues in `CREATE/potential_issues.md`. Reduce complexity, allow step-by-step debug.

**Out of scope:** Beszel monitoring. Deferred to a future rewrite phase.

---

## Locked decisions

| Decision | Pick |
| --- | --- |
| Scope | DST container + admin panel + bootstrap (no Beszel) |
| Agent model | Specialist roles: one role end-to-end per component |
| Philosophy | Avoid all known rakes; fix all latent issues; structural improvements where they cut complexity; tests at boundaries |
| Role count | 3 — `dst-container`, `admin-panel`, `bootstrap` |
| Test approach | pytest at boundaries (Python), shellcheck on all `.sh`, VPS smoke per role |
| Branch | `re-create`. Single PR to `master` after all three roles green + cross-role smoke. |

---

## Execution order

Bottom-up. Each role unblocks the next via smoke checkpoint.

```
1. dst-container  ── independent. Smoke: podman run + --env-file → steamcmd update + clean exit
       │
       ▼
2. admin-panel    ── needs dst-container running + podman socket. Smoke: podman start dst, hit :8080, status JSON populates
       │
       ▼
3. bootstrap      ── orchestrates both. Smoke: fresh VPS → curl + run → working stack
```

Cross-role smoke after all three green: full bootstrap → admin UI → upload cluster zip → activate → DST reaches `Sim paused` → R2 history shows first backup.

---

## Module boundaries

### dst-container

```
Dockerfile
entrypoint.sh         ← lifecycle orchestrator (steamcmd update, mods sync, cluster wait, FIFO setup, launch, poll loop, graceful stop)
lib/r2.sh             ← R2 helpers (r2_configured, r2_rclone_env, r2_require, do_backup, do_r2_restore_once)
                        — sourced by entrypoint.sh, no namespace overlap
run-dst.sh            ← production launcher (podman run with --userns=keep-id, ports, volumes)
```

Bash splits limited to `lib/r2.sh` because R2 helpers run in 3 distinct flows (backup, restore, list-newest). FIFO/poll/backup-trigger stay in `entrypoint.sh` — each is single-use.

### admin-panel

```
admin/Dockerfile
admin/docker-compose.yml
admin/requirements.txt
admin/app/main.py         ← FastAPI app, route definitions, dependency wiring. Routes thin; logic lives in modules below.
admin/app/cluster.py      ← cluster_dir, cluster_is_ready, shard_status, list_parked, read_active_cluster_settings, WIZARD_DEFAULTS
admin/app/r2.py           ← r2_env_ready, r2_rclone_env (with NO_CHECK_BUCKET=true), list_r2_clusters, list_r2_history, read_r2_mods_sidecar, fetch_r2_cluster_to, run_backup, _newest_history_key, _history_path
admin/app/archive.py      ← ARCHIVE_JUNK constant, _strip_archive_junk, _flatten_single_top_dir, magic-byte detect, extract_archive (dispatching zip vs tar.gz with traversal guards)
admin/app/mods.py         ← _WORKSHOP_ID_RE, summarize_mods (workshop IDs from setup + modoverrides, sideloaded folder list)
admin/app/templates/index.html
admin/app/static/style.css
admin/tests/
  conftest.py             ← fixtures: tmp_path fake project root, mocked subprocess.run for rclone+podman returning canned JSON
  test_archive.py         ← magic-byte detection (zip/tar.gz/garbage), junk strip, flatten, traversal escape, single-wrapper-dir hoist
  test_cluster.py         ← parked invalid, parked valid, read_active_cluster_settings defaults vs live, malformed cluster.ini behavior
  test_r2.py              ← path constants, history sort lex, day-NNNN- prefix vs iso-ts, sidecar pair detection, missing R2 env returns []
  test_mods.py            ← workshop-ID extract, sideload tree walk, junk filter
```

Each module ≤ 400 LOC target. Main.py route handlers stay slim — call into modules.

### bootstrap

```
bootstrap/vultr-bootstrap.sh        ← single shell script, idempotent, 3 running modes (interactive, --vars file, Vultr Startup wrapper invocation)
bootstrap/vultr-startup-script.sh   ← thin wrapper for Vultr Startup-Script feature (vars filled inline, calls main script)
bootstrap/bootstrap.vars.example
bootstrap/README.md                 ← matches CREATE/CREATE.md §3 with VPS-specific commands
```

Bootstrap stays single-file (411 lines in old/). Splitting bash bootstrap into libs gains nothing — every step runs once, in order.

---

## Test scaffolding

### Python (pytest)

Pytest at boundaries. No mocks of own code. Subprocess mocked globally so no real `rclone`/`podman` calls. Coverage targets per module:

| Module | Test file | Test count target |
| --- | --- | --- |
| `archive.py` | `test_archive.py` | 7–9 |
| `cluster.py` | `test_cluster.py` | 5–7 |
| `r2.py` | `test_r2.py` | 5–7 |
| `mods.py` | `test_mods.py` | 4–5 |

Total ≥ 22 tests. Run: `pytest admin/tests/ -v`.

### Bash (shellcheck)

`shellcheck` on every `.sh`. Run: `find . -name '*.sh' -not -path './CREATE/*' -exec shellcheck {} +`. Exit 0 required. No bash unit tests (bats overhead not justified at this scope).

### VPS smoke

Per-role acceptance criteria run on a real Vultr Ubuntu 24.04 VPS. Exact commands listed in **Definition of Done** below. Mac/local cannot run Steam binaries (`CREATE/AGENTS.md → ARM Mac limitations`).

---

## Definition of Done per role

### dst-container

1. File manifest complete: `Dockerfile`, `entrypoint.sh`, `lib/r2.sh`, `run-dst.sh` (all at repo root).
2. `shellcheck **/*.sh` exit 0.
3. `podman build --platform=linux/amd64 -t local/dst:latest .` succeeds.
4. **Smoke 1**: `podman run --rm local/dst:latest steamcmd +quit` → exit 0; log contains `App '343050' fully installed.`.
5. **Smoke 2** (VPS, real `.env`): `./run-dst.sh start` → within 10 minutes log reaches `Sim paused` (full cluster present) OR `still waiting for cluster` (empty saves).

### admin-panel

1. File manifest complete: see Module Boundaries above.
2. `pytest admin/tests/ -v` all pass, ≥ 22 tests.
3. No module file > 400 LOC.
4. `podman build -t local/dst-admin:latest admin` succeeds.
5. **Smoke 1**: `curl http://localhost:8080/api/status` → 401 (no auth).
6. **Smoke 2**: `curl -u dst:$ADMIN_PASSWORD http://localhost:8080/api/status` → 200, JSON with keys `dst, cluster_ready, shards, r2_ready, logs, ts`.
7. **Smoke 3** (VPS): web UI loads, status pills populate, R2 backups section lists from real R2 if configured.

### bootstrap

1. File manifest complete: see Module Boundaries above.
2. `shellcheck bootstrap/*.sh` exit 0.
3. **Smoke 1**: fresh Ubuntu 24.04 VPS → `curl -fsSL <raw URL>/bootstrap.sh -o bootstrap.sh && sudo ./bootstrap.sh --vars /root/bootstrap.vars` → exit 0.
4. **Smoke 2**: `podman ps` shows `dst` + `dst-admin` Up.
5. **Smoke 3**: `curl http://<vps>:8080` → 200 after auth.
6. **Smoke 4**: re-run `sudo ./bootstrap.sh --vars /root/bootstrap.vars` on populated VPS → exit 0, no destructive ops, mostly skip-existing reports. `podman-restart.service` enabled verified via `systemctl --user --machine=dst@.host is-enabled podman-restart.service` returns `enabled`.

Reboot recovery (manual, post-deploy) documented in `CREATE/CREATE.md §11` and README ops cheatsheet — not part of DoD because it requires a real `sudo reboot` and 90s wait.

### Cross-role (after all 3 green)

1. Full fresh-VPS bootstrap → 10 min wait.
2. Web UI at `:8080` → upload a cluster zip → Activate → wait.
3. DST shards reach `Sim paused` → admin UI shows live/live shard pills.
4. Wait ≥1 in-game day OR trigger empty-server condition → R2 history shows new `day-NNNN-*.zip` + `.mods.json` sidecar.

---

## Role brief shape

Each agent receives one self-contained brief with these sections:

1. **Component overview** — 1 paragraph what + why. Cross-link to `CREATE/CREATE.md §N` (architecture + data flow).
2. **File manifest** — exact paths to create or modify. No globs.
3. **Hard rules** — cross-link to `CREATE/AGENTS.md` invariants that bind this component (R2 mandatory, keep-id, no `:U` shared, FIFO O_RDWR, etc).
4. **Anti-patterns** — cross-link to relevant items in `CREATE/potential_issues.md` and `CREATE/CREATE.md §7` rakes. Explicit do-not-repeat list.
5. **Reference implementation** — `CREATE/old/<file>` as starting point for understanding intent, **not** to copy verbatim. Improvements expected per philosophy decision.
6. **Acceptance criteria** — exact smoke commands + expected output + exit codes from the relevant DoD section above.
7. **Out of scope** — what NOT to build (Beszel routes, monitoring integration, etc.).

---

## Error handling policy

Per `CREATE/AGENTS.md → "Working with the agent — anti-defensive prompting"` and `CREATE/potential_issues.md`:

- **No defensive code without justification.** If unsure whether a guard is needed, leave it out. Real failures bubble up.
- **Restart-failure path** (`mods_save`, `mods_upload`): propagate as 500 with captured stderr, not silent redirect. Fixes latent #1.
- **cluster.ini parse error** (`read_active_cluster_settings`): log + render banner in wizard template, do not silently fall back to defaults. Fixes latent #2.
- **Archive extraction**: path-traversal guards mandatory (rejected entries → 400). `ARCHIVE_JUNK` strip mandatory after extraction. Partial extract on validation failure → `shutil.rmtree(dest, ignore_errors=True)` then re-raise.
- **Subprocess wrappers**: return `(returncode, stdout, stderr)` tuples. Callers decide policy. No silent catches in the wrapper itself.
- **R2 calls**: `RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true` mandatory. Without it, scoped tokens 403 on bucket probe. Rake from `CREATE/CREATE.md §7`.

---

## Branch and commit strategy

- All work on `re-create` branch (already current).
- Commit cadence: per-capability within each role. Each Python commit = test added + code makes test pass. Each bash commit = file added + shellcheck clean.
- Conventional Commits format (`feat:`, `fix:`, `refactor:`, `chore:`, `docs:`). Body explains "why" when not obvious.
- Single PR `re-create → master` after cross-role smoke green. No sub-branches per role — would add ceremony without payoff given bottom-up dependency.

---

## What this design omits (handled by writing-plans phase)

- Exact ordering of capabilities within each role (test-first sequence).
- Per-capability code excerpts for the implementation plan.
- Per-capability commit message templates.
- Mock fixture content for `conftest.py`.

Those land in the implementation plan document produced next.

---

## References

- **`CREATE/CREATE.md`** — full architecture + data flow + tech matrix + rakes + invariants. Reader entry point.
- **`CREATE/AGENTS.md`** — decision history + corrections log + anti-defensive prompting rules.
- **`CREATE/potential_issues.md`** — currently latent bugs with severity + fix sketches.
- **`CREATE/old/`** — reference implementation (Dockerfile, entrypoint.sh, run-dst.sh, vultr-bootstrap.sh, etc.) for intent only. Not for copy.
