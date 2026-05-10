# Defensive-code rules

Forbidden patterns plus current violations. Each rule: shape to avoid, why bad, where it occurs, replacement.

Decision rule before any new try/except, swallow, or filter: **"what specific scenario does this protect against, is it actually possible?"** If answer is "not sure, just being safe": strip it.

---

## Rule 1 — Don't swallow restart failures behind a redirect

User-facing action that chains "do X then restart container" must surface a failed restart. Silent failure looks identical to success in the browser.

**Forbidden:**
```python
try:
    podman("restart", "-t", "90", DST_CONTAINER, timeout=120)
except subprocess.SubprocessError:
    pass
```

**Violations:** `admin/app/main.py:1352` (`mods_save`), `admin/app/main.py:1440` (`mods_upload`).

**Required:** propagate as 500 with captured stderr, OR redirect to status page rendering a failure banner.

---

## Rule 2 — Don't return defaults on config parse error

Parser exception on a user-edited file is signal, not noise. Returning `WIZARD_DEFAULTS` lets the user submit a form that overwrites live config with defaults — silent data loss.

**Forbidden:**
```python
try:
    cp.read(ini_path, encoding="utf-8")
except (configparser.Error, OSError):
    return out
```

**Violations:** `admin/app/main.py:376` (`read_active_cluster_settings`).

**Required:** log to stderr at minimum. Pass `parse_error: str | None` to the template; render a banner ("cluster.ini has parse error: …; submitting will overwrite with these defaults") before the user can submit.

---

## Rule 3 — Don't `try/except: pass` on rmdir-after-drain

If every entry was just moved out of a directory and `rmdir` still fails, that's a logic bug in the move loop, not an environment issue. Catching it hides bugs.

**Forbidden:**
```python
try:
    inner.rmdir()
except OSError:
    pass
```

**Violations:** `admin/app/main.py:67` (`_flatten_single_top_dir`).

**Required:** drop the try/except. Let `OSError` propagate.

---

## Rule 4 — One layer of defense per concern, not two

`errors="ignore"` AND `except OSError: pass` on a file we wrote ourselves moments earlier is belt-and-suspenders for non-existent threats. Pick one.

**Forbidden:**
```python
try:
    workshop_ids.update(_WORKSHOP_ID_RE.findall(setup.read_text("utf-8", errors="ignore")))
except OSError:
    pass
```

**Violations:** `admin/app/main.py:340`, `admin/app/main.py:348` (`summarize_mods`).

**Required:** keep `errors="ignore"` (file existence already checked via `is_file()`). Drop the `OSError` catch.

---

## Rule 5 — Don't `os.environ.copy()` when 2–3 keys would do

Subprocess env is an explicit dict of what the command needs. Copying the full process env is reflexive, not informed.

**Forbidden:**
```python
out = os.environ.copy()
out.update({...})
```

**Violations:** `admin/app/main.py:656` (`r2_rclone_env`).

**Required:**
```python
out = {"PATH": os.environ.get("PATH", ""),
       "HOME": os.environ.get("HOME", "/tmp"),
       **{... rclone-specific ...}}
```

(Marginal impact alone; ride along with adjacent edits.)

---

## Rule 7 — Delete dead-code accumulation

Lines from "alternatives I tried while wiring this up" that are immediately overwritten on the next line. Keep only the path that actually runs.

**Forbidden:**
```bash
local tmp="/tmp/restore.${newest##*-}"   # any unique suffix - we'll dispatch on extension
tmp="/tmp/restore-$$.${newest##*.}"
if [[ "$newest" == *.tar.gz ]]; then tmp="/tmp/restore-$$.tar.gz"; ext="tar.gz"; fi
```

**Violations:** `entrypoint.sh:190` (`do_r2_restore_once`).

**Required:**
```bash
local ext="zip" tmp="/tmp/restore-$$.zip"
if [[ "$newest" == *.tar.gz ]]; then tmp="/tmp/restore-$$.tar.gz"; ext="tar.gz"; fi
```

---

## Rule 8 — `2>/dev/null` only where stderr genuinely is noise

Per-path probe loop: stderr is "file not found", expected, suppressing it is fine. Wide-find: stderr can mean container down / socket broken / permission denied. Suppressing both with the same flag conflates the two.

**Forbidden (wide-find case):**
```bash
if found=$(podman exec beszel sh -c '... 2>/dev/null'); then
```

**Violations:** `monitoring/autowire.sh:118` (probe loop — OK as-is), `monitoring/autowire.sh:127` (wide-find — needs fix).

**Required (line 127):** redirect stderr to a debug log so the operator can `tail` it on weird failures:
```bash
if found=$(podman exec beszel sh -c '... 2>>/tmp/autowire-debug.log'); then
```

---

## Exemptions — patterns that LOOK defensive but are correct

Do not "fix" these. Each has a real concurrent or partial-state reason.

- **`try: tmp.unlink() except FileNotFoundError`** in `finally` blocks (`run_backup`, `fetch_r2_cluster_to`). Cleanup; the temp may not have been created if an earlier step failed.
- **`shutil.rmtree(dest, ignore_errors=True)`** on cleanup-after-extraction-failure (`cluster_upload`, `cluster_r2_park`, `cluster_r2_restore`, `mods_upload`). Partial trees can have permission weirdness; goal is best-effort cleanup so the slot is reusable on retry.
- **`_strip_archive_junk`'s `except OSError: pass`** per-file. Concurrent `rglob` over a tree being modified; transient races are real.
