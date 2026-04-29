# Potential issues — defensive-code self-review

Honest catalog of code that handles cases that probably can't happen, swallows errors that should bubble, or adds layers of defense without justification. Sorted by severity.

Each entry: file:line, what it does, why it's defensive, suggested fix.

---

## Tier 1 — Genuinely hides failures from the user

### 1. `mods_save` / `mods_upload` swallow restart errors

**`admin/app/main.py:1352`** and **`admin/app/main.py:1440`**

```python
try:
    podman("restart", "-t", "90", DST_CONTAINER, timeout=120)
except subprocess.SubprocessError:
    pass
```

User clicks "Save and restart DST", restart fails (container gone, podman socket dead, timeout), the page redirects to `/` and looks like everything worked. User then wonders why mods didn't apply — no signal that the restart half of "Save and restart" failed.

**Fix:** propagate the failure as a 500 with the captured stderr, OR redirect to a status page that surfaces the failure as a banner.

---

### 2. `read_active_cluster_settings` returns defaults on parse error

**`admin/app/main.py:376`**

```python
try:
    cp.read(ini_path, encoding="utf-8")
except (configparser.Error, OSError):
    return out
```

If `cluster.ini` is malformed (typo somewhere), the wizard silently shows `WIZARD_DEFAULTS` instead of the live settings. User edits, hits submit, overwrites the live cluster's actual config with the defaults. Data loss possible.

**Fix:** log the parse error to stderr at minimum. Better: pass a `parse_error: str | None` to the template so the wizard can render a banner ("cluster.ini has a parse error: …; submitting will overwrite with these defaults").

---

## Tier 2 — Minor noise / hides smaller bugs

### 3. `_flatten_single_top_dir` swallows `OSError` on `inner.rmdir()`

**`admin/app/main.py:67`** (approx, in the helper near the top)

```python
try:
    inner.rmdir()
except OSError:
    pass
```

After moving every entry out of `inner`, if rmdir fails it means we missed something during the move loop — a logic bug, not an environmental one. Letting it raise would surface it.

**Fix:** drop the try/except; let the OSError propagate. If we ever see it in the wild, it's actually informative.

---

### 4. `summarize_mods` double-defense on file reads

**`admin/app/main.py:340`** and **`admin/app/main.py:348`**

```python
try:
    workshop_ids.update(_WORKSHOP_ID_RE.findall(setup.read_text("utf-8", errors="ignore")))
except OSError:
    pass
```

`errors="ignore"` AND a try/except — both swallow problems on a file we wrote ourselves moments earlier. Belt-and-suspenders for non-existent threats.

**Fix:** keep one or the other. `errors="ignore"` is enough if the file is guaranteed to exist (we check `is_file()` above). Drop the OSError catch.

---

### 5. `os.environ.copy()` in `r2_rclone_env`

**`admin/app/main.py:656`**

```python
out = os.environ.copy()
out.update({...})
```

Copies every env var rclone could possibly need plus everything else. Reflexive defensive copying — rclone needs `PATH`, `HOME`, and the `RCLONE_CONFIG_R2_*` we set. That's it.

**Fix:** build the dict explicitly:
```python
out = {"PATH": os.environ.get("PATH", ""),
       "HOME": os.environ.get("HOME", "/tmp"),
       **{... rclone-specific ...}}
```

Marginal improvement; not worth churning for on its own.

---

### 6. `run_backup` filters `ARCHIVE_JUNK` from the active cluster zip

**`admin/app/main.py:713`**

```python
for fp in cd.rglob("*"):
    if fp.name in ARCHIVE_JUNK:
        continue
    if fp.is_file():
        zf.write(...)
```

The active cluster shouldn't have `__MACOSX/` or `.DS_Store` in it — if it does, the bug is upstream (something didn't strip on extract). Filtering on backup hides that condition.

**Fix:** drop the filter. If we ever zip junk into a backup, that's actually informative; we'd want to see it on the next restore.

---

### 7. Dead code in `do_r2_restore_once`

**`entrypoint.sh:190`**

```bash
local tmp="/tmp/restore.${newest##*-}"   # any unique suffix - we'll dispatch on extension
tmp="/tmp/restore-$$.${newest##*.}"
if [[ "$newest" == *.tar.gz ]]; then tmp="/tmp/restore-$$.tar.gz"; ext="tar.gz"; fi
```

Line 1 is computed and immediately overwritten on the next two lines. Defensive accumulation of "alternatives I tried while wiring this up".

**Fix:** keep the conditional only:
```bash
local ext="zip" tmp="/tmp/restore-$$.zip"
if [[ "$newest" == *.tar.gz ]]; then tmp="/tmp/restore-$$.tar.gz"; ext="tar.gz"; fi
```

---

### 8. `autowire.sh` `2>/dev/null` on `podman exec`

**`monitoring/autowire.sh:118, 127`**

```bash
if cand=$(podman exec beszel cat "$path" 2>/dev/null); then
```

Hides the difference between "file doesn't exist at this path" (expected during fallback walk) and "container down / permission denied / podman socket broken" (you'd want to see).

**Fix:** for the per-path probe loop, leave it — it's a known fallback chain. For the wide-find call (line 127), redirect stderr to a debug log so the operator can `tail` it on weird failures:
```bash
if found=$(podman exec beszel sh -c '... 2>>/tmp/autowire-debug.log'); then
```

---

## Actually fine even though they look defensive

These look defensive at first glance but are correct error handling. Documented here so a future audit doesn't "fix" them and break things.

- **`try: tmp.unlink() except FileNotFoundError`** in finally blocks (`run_backup`, `fetch_r2_cluster_to`). Correct cleanup — `tmp` may not have been created if an earlier step failed.
- **`shutil.rmtree(dest, ignore_errors=True)`** on cleanup-after-extraction-failure (`cluster_upload`, `cluster_r2_park`, `cluster_r2_restore`, `mods_upload`). Partial trees can have permission weirdness; ignoring errors is right when the goal is "best effort to leave the slot reusable on retry".
- **`_strip_archive_junk`'s `except OSError: pass`** per-file. Concurrent rglob iteration over a tree we're modifying; transient races are real.

---

## Notes for future audits

If you find something that looks defensive, ask first: **what specific scenario does this protect against, and is that scenario actually possible?** If the answer is "I'm not sure, just being safe", that's defensive code — let the original failure mode bubble up.

Trust internal code and framework guarantees. Only validate at system boundaries (user input from forms, external APIs like rclone/podman, archive contents).
