"""
DST admin panel — FastAPI.

Responsibilities:
- HTTP Basic auth (single password from $ADMIN_PASSWORD).
- Start/stop/restart the DST container via `podman` (socket mounted from host).
- Park-and-pick cluster management (upload zip, activate, delete).
- Template-server wizard (writes cluster.ini / server.ini / modoverrides.lua).
- Edit adminlist.txt (KU_ IDs only).
- Manual R2 backup trigger.
- Download regenerated bootstrap (.env + install script).

Layout of paths inside this container (matches docker-compose.yml):
  /data/saves    → ./saves     (active clusters, bind-mounted into DST container)
  /data/parked   → ./parked    (park-and-pick store; not visible to DST)
  /data/mods     → ./mods      (dedicated_server_mods_setup.lua)
  /data/.env     → ./.env      (secrets, regeneratable on download)

Writes are done directly to the bind-mounted host dirs; the running DST
container sees them immediately (saves/) or on next boot (mods/).
"""

from __future__ import annotations

import configparser
import io
import json
import os
import secrets
import shutil
import subprocess
import tarfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import (
    Depends,
    FastAPI,
    File,
    Form,
    HTTPException,
    Request,
    UploadFile,
    status,
)
from fastapi.responses import HTMLResponse, PlainTextResponse, RedirectResponse, Response
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

APP_ROOT = Path(__file__).resolve().parent
TEMPLATES = Jinja2Templates(directory=str(APP_ROOT / "templates"))

# Data paths — bind-mounted from host in docker-compose.yml.
DATA = Path("/data")
SAVES_DIR = DATA / "saves"
PARKED_DIR = DATA / "parked"
MODS_DIR = DATA / "mods"
ENV_FILE = DATA / ".env"

DST_CONTAINER = os.environ.get("DST_CONTAINER", "dst")
CLUSTER_NAME = os.environ.get("CLUSTER_NAME", "qkation-cooperative")
ADMIN_USER = os.environ.get("ADMIN_USER", "dst")
ADMIN_PASSWORD = os.environ.get("ADMIN_PASSWORD", "")

# podman socket is mounted from the host so `podman` CLI in this container
# talks to the host's engine. See docker-compose.yml.
os.environ.setdefault("CONTAINER_HOST", "unix:///run/podman/podman.sock")


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

security = HTTPBasic()


def require_auth(credentials: HTTPBasicCredentials = Depends(security)) -> str:
    if not ADMIN_PASSWORD:
        # Fail closed: no password set = admin panel is locked.
        raise HTTPException(
            status_code=500,
            detail="ADMIN_PASSWORD is not set on the admin container.",
        )
    user_ok = secrets.compare_digest(credentials.username, ADMIN_USER)
    pw_ok = secrets.compare_digest(credentials.password, ADMIN_PASSWORD)
    if not (user_ok and pw_ok):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid credentials",
            headers={"WWW-Authenticate": "Basic"},
        )
    return credentials.username


# ---------------------------------------------------------------------------
# Podman helpers
# ---------------------------------------------------------------------------


def podman(*args: str, timeout: int = 120) -> tuple[int, str, str]:
    """Run podman and return (rc, stdout, stderr). Never raises."""
    try:
        proc = subprocess.run(
            ["podman", *args],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return proc.returncode, proc.stdout.strip(), proc.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", f"podman {args[0] if args else ''} timed out after {timeout}s"
    except FileNotFoundError:
        return 127, "", "podman binary not found in admin image"


def dst_status() -> dict[str, Any]:
    """Summary of the DST container state for the dashboard."""
    rc, out, err = podman("inspect", "--format", "{{json .State}}", DST_CONTAINER)
    if rc != 0:
        return {"exists": False, "state": "absent", "error": err}
    try:
        state = json.loads(out)
    except json.JSONDecodeError:
        return {"exists": True, "state": "unknown", "error": out}
    return {
        "exists": True,
        "state": state.get("Status", "unknown"),
        "started_at": state.get("StartedAt"),
        "exit_code": state.get("ExitCode"),
    }


def read_log_tail(path: Path, lines: int = 8) -> list[str]:
    """Last N non-empty lines from a text file (server_log.txt etc.)."""
    if not path.is_file():
        return []
    try:
        content = path.read_text(encoding="utf-8", errors="replace")
        return [l for l in content.splitlines() if l.strip()][-lines:]
    except OSError:
        return []


def dst_log_tail(lines: int = 8) -> list[str]:
    """Last N lines from the DST container's combined stdout+stderr (entrypoint log)."""
    # podman logs: container stdout -> process stdout, container stderr -> process stderr.
    # entrypoint log() writes to stderr; DST binary output goes to stdout.
    # Capture both, merge, return the tail.
    rc, out, err = podman("logs", "--tail", str(lines * 2), DST_CONTAINER)
    combined = "\n".join(filter(None, [out, err]))
    all_lines = [l for l in combined.splitlines() if l.strip()]
    return all_lines[-lines:]


def dst_process_status() -> dict[str, Any]:
    """Count live `dontstarve_dedicated_server` processes inside the container.

    Container "running" from `podman inspect` only means the entrypoint shell
    is alive - it can be wedged waiting for a cluster, mid-update, or even
    the DST binary could have crashed while tini kept the shell up. pgrep is
    ground truth.

    Healthy two-shard cluster: count == 2 (Master + Caves binaries).
    """
    rc, out, _ = podman(
        "exec", DST_CONTAINER, "pgrep", "-fc", "dontstarve_dedicated_server",
        timeout=10,
    )
    if rc != 0:
        # Container not running, or exec failed - can't tell.
        return {"count": 0, "expected": 2, "healthy": False}
    try:
        count = int(out.strip())
    except ValueError:
        count = 0
    return {"count": count, "expected": 2, "healthy": count == 2}


# DST writes these strings into server_log.txt once the shard has finished
# loading and once it has connected to its sibling shard, respectively.
_SHARD_READY_MARKER = "Sim paused"
_SHARD_LINKED_MARKER = "Shard link established"


def parse_shard_log_state(log_path: Path) -> dict[str, Any]:
    """Summarise the last ~32 KB of a shard's server_log.txt.

    We only read the tail because these logs grow to megabytes on long
    uptimes. 32 KB = a few minutes of idle-server output, which is plenty
    to detect "this shard booted and is currently alive".
    """
    if not log_path.is_file():
        return {"exists": False, "ready": False, "linked": False}
    try:
        size = log_path.stat().st_size
        with log_path.open("rb") as f:
            f.seek(max(0, size - 32 * 1024))
            tail = f.read().decode("utf-8", errors="replace")
    except OSError:
        return {"exists": True, "ready": False, "linked": False}
    return {
        "exists": True,
        "ready": _SHARD_READY_MARKER in tail,
        "linked": _SHARD_LINKED_MARKER in tail,
    }


def uptime_human(started_at_iso: str | None) -> str:
    """Render container uptime as 12s / 4m 2s / 2h 14m (no days - a DST
    server up for days is already covered by the hour count).
    """
    if not started_at_iso:
        return "-"
    try:
        # Podman returns e.g. "2026-04-24T00:17:31.123456789Z". Python's
        # fromisoformat can't handle nanosecond precision pre-3.11, so trim.
        base = started_at_iso.split(".")[0].rstrip("Z")
        start = datetime.fromisoformat(base).replace(tzinfo=timezone.utc)
    except ValueError:
        return "-"
    secs = int((datetime.now(timezone.utc) - start).total_seconds())
    if secs < 60:
        return f"{secs}s"
    if secs < 3600:
        return f"{secs // 60}m {secs % 60}s"
    return f"{secs // 3600}h {(secs % 3600) // 60}m"


# ---------------------------------------------------------------------------
# Cluster helpers
# ---------------------------------------------------------------------------


def cluster_dir() -> Path:
    return SAVES_DIR / CLUSTER_NAME


def cluster_is_ready() -> bool:
    """Mirror of the entrypoint's cluster_ready — are the required files there?

    A two-shard cluster needs cluster.ini + BOTH Master/server.ini and
    Caves/server.ini. If any of the three is missing, DST refuses to launch.
    """
    cd = cluster_dir()
    return (
        (cd / "cluster.ini").is_file()
        and (cd / "Master" / "server.ini").is_file()
        and (cd / "Caves" / "server.ini").is_file()
    )


def shard_status() -> dict[str, bool]:
    """Per-shard presence flags for the dashboard."""
    cd = cluster_dir()
    return {
        "cluster_ini": (cd / "cluster.ini").is_file(),
        "master": (cd / "Master" / "server.ini").is_file(),
        "caves": (cd / "Caves" / "server.ini").is_file(),
    }


# Default values for the template wizard form. Used when no active cluster
# exists (fresh VPS, parked-only state). Once a cluster is provisioned the
# wizard's render context overrides these from the live cluster.ini, so the
# operator sees what the running game is actually configured with rather
# than starting fresh inputs every visit.
WIZARD_DEFAULTS: dict[str, Any] = {
    "cluster_name": CLUSTER_NAME,
    "password": CLUSTER_NAME,           # matches the original hardcoded HTML default
    "max_players": 6,
    "game_mode": "relaxed",
    "pvp": False,
    "description": "Friendly cooperative world.",
}


def read_active_cluster_settings() -> dict[str, Any]:
    """Read cluster.ini of the active cluster (if present) and return a dict
    in the shape WIZARD_DEFAULTS expects, so we can prefill the form with
    live values once the cluster has been provisioned. Missing keys fall
    back to the defaults; missing/unreadable file returns defaults wholesale."""
    out = dict(WIZARD_DEFAULTS)
    cd = cluster_dir()
    ini_path = cd / "cluster.ini"
    if not ini_path.is_file():
        return out
    cp = configparser.ConfigParser(strict=False, interpolation=None)
    try:
        cp.read(ini_path, encoding="utf-8")
    except (configparser.Error, OSError):
        return out
    g = cp["GAMEPLAY"] if "GAMEPLAY" in cp else {}
    n = cp["NETWORK"] if "NETWORK" in cp else {}
    if "game_mode" in g:
        out["game_mode"] = g["game_mode"].strip()
    if "max_players" in g:
        try:
            out["max_players"] = int(g["max_players"].strip())
        except ValueError:
            pass
    if "pvp" in g:
        out["pvp"] = g["pvp"].strip().lower() == "true"
    if "cluster_password" in n:
        out["password"] = n["cluster_password"].strip()
    if "cluster_description" in n:
        out["description"] = n["cluster_description"].strip()
    if "cluster_name" in n:
        out["cluster_name"] = n["cluster_name"].strip() or out["cluster_name"]
    return out


def list_parked() -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    if not PARKED_DIR.exists():
        return out
    for child in sorted(PARKED_DIR.iterdir()):
        if not child.is_dir():
            continue
        stat = child.stat()
        has_cluster_ini = (child / "cluster.ini").is_file()
        has_master = (child / "Master" / "server.ini").is_file()
        has_caves = (child / "Caves" / "server.ini").is_file()
        out.append(
            {
                "name": child.name,
                "mtime": datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc).isoformat(),
                # A parked cluster is "valid" only if it will actually launch:
                # cluster.ini + both shards' server.ini files present.
                "valid": has_cluster_ini and has_master and has_caves,
                "has_master": has_master,
                "has_caves": has_caves,
                "size_mb": round(
                    sum(p.stat().st_size for p in child.rglob("*") if p.is_file()) / 1_048_576,
                    2,
                ),
            }
        )
    return out


def safe_name(name: str) -> str:
    """Restrict cluster/parked names to a POSIX-sane subset."""
    cleaned = "".join(ch if ch.isalnum() or ch in "-_" else "-" for ch in name.strip())
    cleaned = cleaned.strip("-_")
    if not cleaned:
        raise HTTPException(status_code=400, detail="Empty or unsafe name")
    if len(cleaned) > 64:
        raise HTTPException(status_code=400, detail="Name too long (max 64 chars)")
    return cleaned


# ---------------------------------------------------------------------------
# Template-server writer
# ---------------------------------------------------------------------------

CLUSTER_INI_TEMPLATE = """\
[GAMEPLAY]
game_mode = {game_mode}
max_players = {max_players}
pvp = {pvp}
pause_when_empty = true
vote_enabled = true

[NETWORK]
cluster_name = {cluster_name}
cluster_description = {cluster_description}
cluster_password = {password}
cluster_intention = {intention}
lan_only_cluster = false
offline_cluster = false

[MISC]
console_enabled = true

[SHARD]
# Two-shard cluster: Master (overworld) + Caves (underground).
# Shards talk to each other over 127.0.0.1:master_port; the cluster_key
# authenticates the link and is generated fresh per cluster by the wizard.
shard_enabled = true
bind_ip = 127.0.0.1
master_ip = 127.0.0.1
master_port = 10888
cluster_key = {cluster_key}
"""

MASTER_SERVER_INI_TEMPLATE = """\
[NETWORK]
server_port = 10999

[SHARD]
is_master = true
name = Master

[STEAM]
authentication_port = 8766
master_server_port = 27016

[ACCOUNT]
encode_user_path = true
"""

CAVES_SERVER_INI_TEMPLATE = """\
[NETWORK]
server_port = 10998

[SHARD]
is_master = false
name = Caves

[STEAM]
authentication_port = 8768
master_server_port = 27018

[ACCOUNT]
encode_user_path = true
"""

MODOVERRIDES_TEMPLATE = """\
return {
}
"""

# Marks a shard directory as caves-enabled. Klei's own shard template writes
# this file; we mirror it so the generated cluster matches vanilla layouts.
WORLDGENOVERRIDE_CAVES = """\
return {
  override_enabled = true,
  preset = "DST_CAVE",
}
"""


def _write_cluster_files(
    cd: Path,
    *,
    cluster_name: str,
    password: str,
    max_players: int,
    game_mode: str,
    pvp: bool,
    description: str,
    intention: str,
) -> None:
    """Write cluster.ini + both shard dirs into `cd`.

    Shared between write_template_cluster (saves/) and the parked-target code
    path. Caller guarantees `cd` does not already exist.
    """
    (cd / "Master").mkdir(parents=True, exist_ok=False)
    (cd / "Caves").mkdir(parents=True, exist_ok=False)

    # A per-cluster random key authenticates the shard-to-shard link. Any
    # reasonably random 16-byte string is fine — shards compare literally.
    cluster_key = secrets.token_hex(16)

    (cd / "cluster.ini").write_text(
        CLUSTER_INI_TEMPLATE.format(
            game_mode=game_mode,
            max_players=max_players,
            pvp="true" if pvp else "false",
            cluster_name=cluster_name,
            cluster_description=description.replace("\n", " "),
            password=password,
            intention=intention,
            cluster_key=cluster_key,
        ),
        encoding="utf-8",
    )
    (cd / "Master" / "server.ini").write_text(MASTER_SERVER_INI_TEMPLATE, encoding="utf-8")
    (cd / "Master" / "modoverrides.lua").write_text(MODOVERRIDES_TEMPLATE, encoding="utf-8")

    (cd / "Caves" / "server.ini").write_text(CAVES_SERVER_INI_TEMPLATE, encoding="utf-8")
    (cd / "Caves" / "modoverrides.lua").write_text(MODOVERRIDES_TEMPLATE, encoding="utf-8")
    # worldgenoverride.lua marks the Caves shard as a caves preset; without
    # this the shard would try to generate an overworld.
    (cd / "Caves" / "worldgenoverride.lua").write_text(WORLDGENOVERRIDE_CAVES, encoding="utf-8")

    (cd / "adminlist.txt").write_text("", encoding="utf-8")
    # cluster_token.txt is intentionally NOT written here — the DST entrypoint
    # writes it from $CLUSTER_TOKEN in .env on launch.


def write_template_cluster(
    *,
    cluster_name: str,
    password: str,
    max_players: int,
    game_mode: str,
    pvp: bool,
    description: str,
    intention: str = "cooperative",
) -> Path:
    cd = SAVES_DIR / cluster_name
    if cd.exists():
        raise HTTPException(status_code=409, detail=f"Cluster '{cluster_name}' already exists")
    _write_cluster_files(
        cd,
        cluster_name=cluster_name,
        password=password,
        max_players=max_players,
        game_mode=game_mode,
        pvp=pvp,
        description=description,
        intention=intention,
    )
    return cd


# ---------------------------------------------------------------------------
# .env read/write — simple KEY=VAL format
# ---------------------------------------------------------------------------


def read_env_file() -> dict[str, str]:
    out: dict[str, str] = {}
    if not ENV_FILE.exists():
        return out
    for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        out[k.strip()] = v.strip()
    return out


def render_env_file(env: dict[str, str]) -> str:
    lines = [
        "# Generated by the admin panel — safe to drop onto a fresh VPS as-is.",
        "# Pairs with run-dst.sh from the repo.",
        "",
    ]
    for k in (
        "CLUSTER_NAME",
        "CLUSTER_TOKEN",
        "R2_ACCOUNT_ID",
        "R2_BUCKET",
        "R2_ACCESS_KEY_ID",
        "R2_SECRET_ACCESS_KEY",
        "AUTO_UPDATE",
        "ADMIN_USER",
        "ADMIN_PASSWORD",
    ):
        if k in env:
            lines.append(f"{k}={env[k]}")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# R2 backup via rclone (admin-initiated, independent of DST container state)
# ---------------------------------------------------------------------------


def r2_env_ready(env: dict[str, str]) -> bool:
    return all(
        env.get(k)
        for k in ("R2_ACCOUNT_ID", "R2_BUCKET", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY")
    )


def r2_rclone_env(env: dict[str, str]) -> dict[str, str]:
    """Build the env dict to pass to subprocess.run() for any rclone call
    against R2. Mirrors the entrypoint's r2_rclone_env in shape.

    NO_CHECK_BUCKET=true is critical: rclone normally probes the bucket on
    first use (HEAD/PUT at /<bucket>) which Cloudflare R2 tokens scoped to
    "Object Read & Write" don't have permission for, returning a stripped
    403 that propagates as a confusing AccessDenied with empty request id.
    """
    out = os.environ.copy()
    out.update(
        {
            "RCLONE_CONFIG_R2_TYPE": "s3",
            "RCLONE_CONFIG_R2_PROVIDER": "Cloudflare",
            "RCLONE_CONFIG_R2_ACCESS_KEY_ID": env["R2_ACCESS_KEY_ID"],
            "RCLONE_CONFIG_R2_SECRET_ACCESS_KEY": env["R2_SECRET_ACCESS_KEY"],
            "RCLONE_CONFIG_R2_ENDPOINT": f"https://{env['R2_ACCOUNT_ID']}.r2.cloudflarestorage.com",
            "RCLONE_CONFIG_R2_REGION": "auto",
            "RCLONE_CONFIG_R2_NO_CHECK_BUCKET": "true",
        }
    )
    return out


def run_backup(tag: str = "manual") -> tuple[bool, str]:
    env = read_env_file()
    if not r2_env_ready(env):
        return False, "R2 env vars not set in .env"
    if not cluster_is_ready():
        return False, f"Cluster '{CLUSTER_NAME}' not provisioned yet"

    rclone_env = r2_rclone_env(env)

    ts = datetime.now(tz=timezone.utc).strftime("%Y-%m-%dT%H%M%SZ")
    tmp = Path(f"/tmp/backup-{ts}-{tag}.tar.gz")
    try:
        with tarfile.open(tmp, "w:gz") as tar:
            tar.add(cluster_dir(), arcname=CLUSTER_NAME)

        bucket = env["R2_BUCKET"]
        latest_dst = f"r2:{bucket}/clusters/{CLUSTER_NAME}/latest.tar.gz"
        hist_dst = f"r2:{bucket}/clusters/{CLUSTER_NAME}/history/{ts}-{tag}.tar.gz"

        for dest in (latest_dst, hist_dst):
            proc = subprocess.run(
                ["rclone", "copyto", str(tmp), dest, "--quiet"],
                capture_output=True,
                text=True,
                env=rclone_env,
                timeout=600,
            )
            if proc.returncode != 0:
                return False, f"rclone failed for {dest}: {proc.stderr.strip()}"
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass
    return True, f"backup pushed ({ts}-{tag})"


# ---- R2 cluster catalog (list / restore / park) ----

def list_r2_clusters() -> list[dict]:
    """Return clusters that have a latest.tar.gz under r2:<bucket>/clusters/.

    Each entry: {"name": str, "size_mb": float, "mtime": "YYYY-MM-DD HH:MM"}.
    Returns [] on any error (R2 not configured, network down, empty bucket)
    so the dashboard can render gracefully even when R2 is misconfigured.
    """
    env = read_env_file()
    if not r2_env_ready(env):
        return []
    bucket = env["R2_BUCKET"]
    rclone_env = r2_rclone_env(env)
    # `--dirs-only` lists immediate subdirs of clusters/, each is a cluster name.
    proc = subprocess.run(
        ["rclone", "lsjson", f"r2:{bucket}/clusters/", "--dirs-only"],
        capture_output=True, text=True, env=rclone_env, timeout=20,
    )
    if proc.returncode != 0:
        return []
    try:
        dirs = json.loads(proc.stdout or "[]")
    except json.JSONDecodeError:
        return []
    out: list[dict] = []
    for d in dirs:
        name = d.get("Name") or d.get("Path")
        if not name:
            continue
        # stat the latest.tar.gz to fish out size + mtime in one call.
        s = subprocess.run(
            ["rclone", "lsjson", f"r2:{bucket}/clusters/{name}/latest.tar.gz"],
            capture_output=True, text=True, env=rclone_env, timeout=15,
        )
        if s.returncode != 0:
            continue
        try:
            files = json.loads(s.stdout or "[]")
        except json.JSONDecodeError:
            continue
        if not files:
            continue
        f = files[0]
        size_mb = round(int(f.get("Size", 0)) / (1024 * 1024), 1)
        mtime = (f.get("ModTime") or "")[:16].replace("T", " ")
        out.append({"name": name, "size_mb": size_mb, "mtime": mtime})
    out.sort(key=lambda x: x["name"])
    return out


def fetch_r2_cluster_to(name: str, dest_dir: Path) -> tuple[bool, str]:
    """Download r2:<bucket>/clusters/<name>/latest.tar.gz and extract into
    dest_dir. dest_dir must NOT already exist (caller's responsibility).
    Returns (ok, message)."""
    env = read_env_file()
    if not r2_env_ready(env):
        return False, "R2 env vars not set in .env"
    bucket = env["R2_BUCKET"]
    src = f"r2:{bucket}/clusters/{name}/latest.tar.gz"
    rclone_env = r2_rclone_env(env)
    tmp = Path(f"/tmp/r2-fetch-{os.getpid()}-{name}.tar.gz")
    try:
        proc = subprocess.run(
            ["rclone", "copyto", src, str(tmp), "--quiet"],
            capture_output=True, text=True, env=rclone_env, timeout=600,
        )
        if proc.returncode != 0:
            return False, f"rclone copyto {src}: {proc.stderr.strip() or 'unknown error'}"
        if not tmp.is_file() or tmp.stat().st_size == 0:
            return False, f"downloaded archive is empty"
        dest_dir.mkdir(parents=True)
        with tarfile.open(tmp, "r:gz") as tar:
            # Same path-traversal guards as the zip upload path.
            for m in tar.getmembers():
                p = Path(m.name)
                if p.is_absolute() or ".." in p.parts:
                    return False, f"unsafe entry in archive: {m.name}"
            tar.extractall(dest_dir)
        # Backups from entrypoint use `tar -C ... <CLUSTER_NAME>`, which
        # produces a top-level <CLUSTER_NAME>/ directory inside the archive.
        # Flatten that so dest_dir/cluster.ini is directly accessible.
        children = [c for c in dest_dir.iterdir() if not c.name.startswith(".")]
        if (
            len(children) == 1
            and children[0].is_dir()
            and not (dest_dir / "cluster.ini").exists()
        ):
            inner = children[0]
            for item in inner.iterdir():
                shutil.move(str(item), str(dest_dir / item.name))
            inner.rmdir()
        return True, f"restored {name} ({tmp.stat().st_size // 1024} KiB)"
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

app = FastAPI(title="DST admin panel", docs_url=None, redoc_url=None, openapi_url=None)
app.mount("/static", StaticFiles(directory=str(APP_ROOT / "static")), name="static")


# ---- Dashboard ----

def _read_text_or_empty(p: Path) -> str:
    return p.read_text(encoding="utf-8") if p.is_file() else ""


@app.get("/", response_class=HTMLResponse)
def dashboard(request: Request, _: str = Depends(require_auth)) -> HTMLResponse:
    env = read_env_file()
    cd = cluster_dir()
    mods_setup_path = MODS_DIR / "dedicated_server_mods_setup.lua"
    adminlist_path = cd / "adminlist.txt"
    return TEMPLATES.TemplateResponse(
        request=request,
        name="index.html",
        context={
            "cluster_name": CLUSTER_NAME,
            "cluster_ready": cluster_is_ready(),
            "cluster_exists": cd.exists(),
            "shards": shard_status(),
            "dst": dst_status(),
            "parked": list_parked(),
            "r2_clusters": list_r2_clusters(),
            "r2_ready": r2_env_ready(env),
            "wizard": read_active_cluster_settings(),
            "adminlist": _read_text_or_empty(adminlist_path),
            "mods_setup": _read_text_or_empty(mods_setup_path),
            "modoverrides_master": _read_text_or_empty(cd / "Master" / "modoverrides.lua"),
            "modoverrides_caves": _read_text_or_empty(cd / "Caves" / "modoverrides.lua"),
            "env_keys": sorted(read_env_file().keys()),
        },
    )


@app.get("/api/status")
def api_status(_: str = Depends(require_auth)) -> Response:
    """Live-poll endpoint for the dashboard JavaScript. Returns JSON."""
    cd = cluster_dir()
    state = dst_status()
    # Only bother with the exec / log-parse if the container exists; otherwise
    # pgrep will just error out and we waste the round-trip.
    if state.get("exists"):
        procs = dst_process_status()
        shard_log = {
            "master": parse_shard_log_state(cd / "Master" / "server_log.txt"),
            "caves":  parse_shard_log_state(cd / "Caves" / "server_log.txt"),
        }
        uptime = uptime_human(state.get("started_at")) if state.get("state") == "running" else "-"
    else:
        procs = {"count": 0, "expected": 2, "healthy": False}
        shard_log = {
            "master": {"exists": False, "ready": False, "linked": False},
            "caves":  {"exists": False, "ready": False, "linked": False},
        }
        uptime = "-"
    data = {
        "dst": state,
        "uptime": uptime,
        "procs": procs,
        "shard_log": shard_log,
        "cluster_ready": cluster_is_ready(),
        "cluster_exists": cd.exists(),
        "shards": shard_status(),
        "r2_ready": r2_env_ready(read_env_file()),
        "logs": {
            "container": dst_log_tail(8),
            "master": read_log_tail(cd / "Master" / "server_log.txt", 6),
            "caves": read_log_tail(cd / "Caves" / "server_log.txt", 6),
        },
        "ts": datetime.now(timezone.utc).isoformat(),
    }
    return Response(content=json.dumps(data), media_type="application/json")


@app.get("/status", response_class=PlainTextResponse)
def json_status(_: str = Depends(require_auth)) -> Response:
    data = {
        "cluster": CLUSTER_NAME,
        "cluster_ready": cluster_is_ready(),
        "shards": shard_status(),
        "dst": dst_status(),
        "parked_count": len(list_parked()),
        "r2_ready": r2_env_ready(read_env_file()),
    }
    return Response(content=json.dumps(data, indent=2), media_type="application/json")


# ---- Server control ----

@app.post("/server/start")
def server_start(_: str = Depends(require_auth)) -> RedirectResponse:
    podman("start", DST_CONTAINER)
    return RedirectResponse("/", status_code=303)


@app.post("/server/stop")
def server_stop(_: str = Depends(require_auth)) -> RedirectResponse:
    # 90s matches run-dst.sh --stop-timeout so the entrypoint has time for
    # c_save + c_shutdown + final R2 push.
    podman("stop", "-t", "90", DST_CONTAINER, timeout=120)
    return RedirectResponse("/", status_code=303)


@app.post("/server/restart")
def server_restart(_: str = Depends(require_auth)) -> RedirectResponse:
    podman("restart", "-t", "90", DST_CONTAINER, timeout=120)
    return RedirectResponse("/", status_code=303)


# ---- Cluster: upload zip (park) ----

@app.post("/cluster/upload")
async def cluster_upload(
    archive_field: UploadFile = File(..., alias="archive"),
    park_name: str = Form(...),
    _: str = Depends(require_auth),
) -> RedirectResponse:
    """Park a cluster from an uploaded archive. Accepts both .zip and .tar.gz
    (the latter matches the format we push to R2, so an operator can download
    a backup from R2 and re-upload it here without re-zipping). Format is
    detected by magic bytes, not by filename."""
    name = safe_name(park_name)
    dest = PARKED_DIR / name
    if dest.exists():
        raise HTTPException(status_code=409, detail=f"Parked slot '{name}' already exists")

    raw = await archive_field.read()
    if not raw:
        raise HTTPException(status_code=400, detail="Empty upload")

    is_zip = raw[:4] in (b"PK\x03\x04", b"PK\x05\x06", b"PK\x07\x08")
    is_gz = raw[:2] == b"\x1f\x8b"

    dest.mkdir(parents=True)
    try:
        if is_zip:
            try:
                zf = zipfile.ZipFile(io.BytesIO(raw))
            except zipfile.BadZipFile:
                raise HTTPException(status_code=400, detail="Not a valid zip file")
            for n in zf.namelist():
                p = Path(n)
                if p.is_absolute() or ".." in p.parts:
                    raise HTTPException(status_code=400, detail=f"Unsafe zip entry: {n}")
            zf.extractall(dest)
        elif is_gz:
            try:
                tf = tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz")
            except tarfile.TarError as exc:
                raise HTTPException(status_code=400, detail=f"Not a valid tar.gz: {exc}")
            for m in tf.getmembers():
                p = Path(m.name)
                if p.is_absolute() or ".." in p.parts:
                    raise HTTPException(status_code=400, detail=f"Unsafe tar entry: {m.name}")
            tf.extractall(dest)
            tf.close()
        else:
            raise HTTPException(
                status_code=400,
                detail="Unsupported archive format. Upload a .zip or .tar.gz "
                       "(magic bytes PK… or 1F8B…).",
            )
    except HTTPException:
        # Clean up partial extraction so the slot is reusable on retry.
        shutil.rmtree(dest, ignore_errors=True)
        raise

    # If the archive contains a single top-level folder (e.g. "my-world/" or
    # "qkation-cooperative/" from an R2 tar), flatten so dest/cluster.ini is
    # directly under dest/.
    children = [c for c in dest.iterdir() if not c.name.startswith(".")]
    if len(children) == 1 and children[0].is_dir() and not (dest / "cluster.ini").exists():
        inner = children[0]
        for item in inner.iterdir():
            shutil.move(str(item), str(dest / item.name))
        inner.rmdir()

    return RedirectResponse("/", status_code=303)


# ---- Cluster: template wizard ----

@app.post("/cluster/template")
def cluster_template(
    cluster_name: str = Form(...),
    password: str = Form(""),
    max_players: int = Form(6),
    game_mode: str = Form("relaxed"),
    pvp: bool = Form(False),
    description: str = Form(""),
    target: str = Form("active"),  # "active" or "parked"
    _: str = Depends(require_auth),
) -> RedirectResponse:
    name = safe_name(cluster_name)
    if max_players < 1 or max_players > 64:
        raise HTTPException(status_code=400, detail="max_players out of range (1-64)")
    if game_mode not in {"relaxed", "survival", "endless", "wilderness"}:
        raise HTTPException(status_code=400, detail="invalid game_mode")

    if target == "parked":
        # Write into parked/, user activates later. Shared helper guarantees
        # both Master and Caves shard files land in the right layout.
        PARKED_DIR.mkdir(exist_ok=True)
        cd_target = PARKED_DIR / name
        if cd_target.exists():
            raise HTTPException(status_code=409, detail=f"Parked '{name}' already exists")
        _write_cluster_files(
            cd_target,
            cluster_name=name,
            password=password,
            max_players=max_players,
            game_mode=game_mode,
            pvp=pvp,
            description=description,
            intention="cooperative",
        )
    else:
        # Write directly as the active cluster. Only legal when no active cluster exists.
        write_template_cluster(
            cluster_name=name,
            password=password,
            max_players=max_players,
            game_mode=game_mode,
            pvp=pvp,
            description=description,
        )
    return RedirectResponse("/", status_code=303)


# ---- Cluster: activate parked → running ----

@app.post("/cluster/activate")
def cluster_activate(
    parked_name: str = Form(...),
    _: str = Depends(require_auth),
) -> RedirectResponse:
    name = safe_name(parked_name)
    parked = PARKED_DIR / name
    if not (parked / "cluster.ini").is_file():
        raise HTTPException(status_code=400, detail=f"Parked '{name}' has no cluster.ini")

    # Stop DST first (graceful), swap folders, restart.
    podman("stop", "-t", "90", DST_CONTAINER, timeout=120)

    cd = cluster_dir()
    if cd.exists():
        # Move current active → parked with a timestamp tag.
        ts = datetime.now(tz=timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        archive = PARKED_DIR / f"{CLUSTER_NAME}-archived-{ts}"
        PARKED_DIR.mkdir(exist_ok=True)
        shutil.move(str(cd), str(archive))

    # Move parked → active slot.
    SAVES_DIR.mkdir(exist_ok=True)
    shutil.move(str(parked), str(cd))

    podman("start", DST_CONTAINER)
    return RedirectResponse("/", status_code=303)


# ---- Cluster: R2 restore (replace active) ----

@app.post("/cluster/r2-restore")
def cluster_r2_restore(
    cluster_name: str = Form(...),
    _: str = Depends(require_auth),
) -> RedirectResponse:
    """Stop DST, archive the current active cluster (if any) into parked/,
    download r2:<bucket>/clusters/<cluster_name>/latest.tar.gz, extract into
    the active slot, restart DST. Mirror of activate-parked but for R2."""
    name = safe_name(cluster_name)

    # Stage download into a temp slot so a partial/broken archive doesn't
    # leave us cluster-less. Move into place atomically once ready.
    staging = SAVES_DIR / f".r2-staging-{os.getpid()}-{name}"
    if staging.exists():
        shutil.rmtree(staging)
    ok, msg = fetch_r2_cluster_to(name, staging)
    if not ok:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)
        raise HTTPException(status_code=502, detail=msg)
    if not (staging / "cluster.ini").is_file():
        shutil.rmtree(staging, ignore_errors=True)
        raise HTTPException(status_code=400, detail=f"R2 backup '{name}' has no cluster.ini after extract")

    podman("stop", "-t", "90", DST_CONTAINER, timeout=120)

    cd = cluster_dir()
    if cd.exists():
        ts = datetime.now(tz=timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        PARKED_DIR.mkdir(exist_ok=True)
        archive = PARKED_DIR / f"{CLUSTER_NAME}-archived-{ts}"
        shutil.move(str(cd), str(archive))

    SAVES_DIR.mkdir(exist_ok=True)
    shutil.move(str(staging), str(cd))

    podman("start", DST_CONTAINER)
    return RedirectResponse("/", status_code=303)


# ---- Cluster: park a copy of an R2 backup (without activating) ----

@app.post("/cluster/r2-park")
def cluster_r2_park(
    cluster_name: str = Form(...),
    park_name: str = Form(""),
    _: str = Depends(require_auth),
) -> RedirectResponse:
    """Download r2:<bucket>/clusters/<cluster_name>/latest.tar.gz into a new
    parked/ slot. Caller can pick a different park_name to avoid colliding
    with the live cluster name; defaults to the same name."""
    src_name = safe_name(cluster_name)
    dest_name = safe_name(park_name) if park_name else src_name
    PARKED_DIR.mkdir(exist_ok=True)
    dest = PARKED_DIR / dest_name
    if dest.exists():
        raise HTTPException(status_code=409, detail=f"Parked slot '{dest_name}' already exists")
    ok, msg = fetch_r2_cluster_to(src_name, dest)
    if not ok:
        if dest.exists():
            shutil.rmtree(dest, ignore_errors=True)
        raise HTTPException(status_code=502, detail=msg)
    return RedirectResponse("/", status_code=303)


# ---- Cluster: delete parked ----

@app.post("/cluster/delete")
def cluster_delete(
    parked_name: str = Form(...),
    _: str = Depends(require_auth),
) -> RedirectResponse:
    name = safe_name(parked_name)
    target = PARKED_DIR / name
    if target.is_dir():
        shutil.rmtree(target)
    return RedirectResponse("/", status_code=303)


# ---- Adminlist ----

@app.post("/admins")
def admins_save(
    adminlist: str = Form(""),
    _: str = Depends(require_auth),
) -> RedirectResponse:
    if not cluster_is_ready():
        raise HTTPException(status_code=400, detail="Cluster not provisioned")
    # Keep only valid KU_ lines; strip comments and blanks silently.
    cleaned: list[str] = []
    for raw in adminlist.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if not line.startswith("KU_"):
            continue
        cleaned.append(line)
    (cluster_dir() / "adminlist.txt").write_text("\n".join(cleaned) + ("\n" if cleaned else ""), encoding="utf-8")
    return RedirectResponse("/", status_code=303)


# ---- Mods ----

@app.post("/mods")
def mods_save(
    mods_setup: str = Form(""),
    modoverrides_master: str = Form(""),
    modoverrides_caves: str = Form(""),
    _: str = Depends(require_auth),
) -> RedirectResponse:
    """Write the workshop list + both shards' modoverrides.

    modoverrides is per-shard in DST (mods enabled on Master aren't
    automatically enabled on Caves, and vice versa). Common practice is
    to keep the two in sync; the UI presents them as separate textareas
    but the caller can copy-paste to unify.
    """
    MODS_DIR.mkdir(exist_ok=True)
    (MODS_DIR / "dedicated_server_mods_setup.lua").write_text(mods_setup, encoding="utf-8")
    if cluster_is_ready():
        cd = cluster_dir()
        (cd / "Master" / "modoverrides.lua").write_text(modoverrides_master, encoding="utf-8")
        (cd / "Caves" / "modoverrides.lua").write_text(modoverrides_caves, encoding="utf-8")
    return RedirectResponse("/", status_code=303)


# ---- Backup ----

@app.post("/backup/trigger")
def backup_trigger(_: str = Depends(require_auth)) -> RedirectResponse:
    run_backup(tag="manual")
    return RedirectResponse("/", status_code=303)


# ---- Bootstrap download ----

@app.get("/bootstrap/env")
def bootstrap_env(_: str = Depends(require_auth)) -> Response:
    env = read_env_file()
    if not r2_env_ready(env):
        # R2 is required; handing out a half-filled .env would produce a
        # VPS that boots into a fail-fast exit. Refuse with a clear error.
        raise HTTPException(
            status_code=409,
            detail=(
                "Cannot download .env — Cloudflare R2 credentials are not "
                "fully set. Populate R2_ACCOUNT_ID, R2_BUCKET, "
                "R2_ACCESS_KEY_ID, and R2_SECRET_ACCESS_KEY on the host "
                "before generating a portable .env."
            ),
        )
    body = render_env_file(env)
    return Response(
        content=body,
        media_type="text/plain; charset=utf-8",
        headers={"Content-Disposition": 'attachment; filename=".env"'},
    )


# Template for the "Download bootstrap.sh" button.
# Secrets are baked into the vars block at the top; the rest downloads and
# runs vultr-bootstrap.sh from GitHub in non-interactive mode (it detects
# pre-set env vars and skips all TTY prompts).
BOOTSTRAP_SH = """\
#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  DST dedicated server — pre-filled bootstrap / Vultr Startup Script
#  Generated by the DST admin panel on {generated_at}
#
#  HOW TO USE:
#    Option A — Vultr Startup Script (zero SSH):
#      Vultr dashboard → Startup Scripts → Add Script → paste → save.
#      Attach to your VPS when creating it; runs on first boot as root.
#
#    Option B — SSH paste:
#      SSH in as root and paste the whole file into the terminal.
#
#    Option C — scp + run:
#      scp this file to the VPS, then: sudo bash bootstrap.sh
#
#  All secrets are already filled in — no interactive prompts.
#  SECURITY: treat this file like a password. Delete after use.
# ─────────────────────────────────────────────────────────────────────────────

# ── VARS (pre-filled from your current .env) ─────────────────────────────────
CLUSTER_NAME="{cluster_name}"
CLUSTER_TOKEN="{cluster_token}"
ADMIN_PASSWORD="{admin_password}"
R2_ACCOUNT_ID="{r2_account_id}"
R2_BUCKET="{r2_bucket}"
R2_ACCESS_KEY_ID="{r2_access_key_id}"
R2_SECRET_ACCESS_KEY="{r2_secret_access_key}"
INSTALL_BESZEL="n"
# ─────────────────────────────────────────────────────────────────────────────
# Web admin login is always the dst Linux user. ADMIN_PASSWORD is used for
# BOTH the web admin and the dst Linux user password (so you can also SSH in
# as dst with the same credential). See bootstrap/vultr-bootstrap.sh.

set -euo pipefail

_require() {{
    local var="$1"
    [[ -n "${{!var:-}}" ]] || {{ echo "ERROR: $var is empty" >&2; exit 1; }}
}}
_require CLUSTER_TOKEN
_require ADMIN_PASSWORD
_require R2_ACCOUNT_ID
_require R2_BUCKET
_require R2_ACCESS_KEY_ID
_require R2_SECRET_ACCESS_KEY

export CLUSTER_NAME CLUSTER_TOKEN ADMIN_PASSWORD \\
       R2_ACCOUNT_ID R2_BUCKET R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY \\
       INSTALL_BESZEL

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL \\
    "https://raw.githubusercontent.com/moxxiq/dst-dedicated-container/master/bootstrap/vultr-bootstrap.sh" \\
    -o "$WORK/vultr-bootstrap.sh"
chmod +x "$WORK/vultr-bootstrap.sh"
exec "$WORK/vultr-bootstrap.sh"
"""


@app.get("/bootstrap/script")
def bootstrap_script(_: str = Depends(require_auth)) -> Response:
    from datetime import datetime, timezone

    env = read_env_file()
    if not r2_env_ready(env):
        raise HTTPException(
            status_code=409,
            detail=(
                "Cannot download bootstrap.sh — Cloudflare R2 credentials "
                "are not fully set. DST refuses to launch without R2, so a "
                "script generated now would boot a broken VPS. Populate all "
                "four R2_* keys in .env first."
            ),
        )
    body = BOOTSTRAP_SH.format(
        generated_at=datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        cluster_name=env.get("CLUSTER_NAME", ""),
        cluster_token=env.get("CLUSTER_TOKEN", ""),
        admin_password=env.get("ADMIN_PASSWORD", ""),
        r2_account_id=env.get("R2_ACCOUNT_ID", ""),
        r2_bucket=env.get("R2_BUCKET", ""),
        r2_access_key_id=env.get("R2_ACCESS_KEY_ID", ""),
        r2_secret_access_key=env.get("R2_SECRET_ACCESS_KEY", ""),
    )
    return Response(
        content=body,
        media_type="text/x-shellscript; charset=utf-8",
        headers={"Content-Disposition": 'attachment; filename="bootstrap.sh"'},
    )
