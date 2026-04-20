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
ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
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


# ---------------------------------------------------------------------------
# Cluster helpers
# ---------------------------------------------------------------------------


def cluster_dir() -> Path:
    return SAVES_DIR / CLUSTER_NAME


def cluster_is_ready() -> bool:
    """Mirror of the entrypoint's cluster_ready — are the required files there?"""
    cd = cluster_dir()
    return (cd / "cluster.ini").is_file() and (cd / "Master" / "server.ini").is_file()


def list_parked() -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    if not PARKED_DIR.exists():
        return out
    for child in sorted(PARKED_DIR.iterdir()):
        if not child.is_dir():
            continue
        stat = child.stat()
        has_cluster_ini = (child / "cluster.ini").is_file()
        out.append(
            {
                "name": child.name,
                "mtime": datetime.fromtimestamp(stat.st_mtime, tz=timezone.utc).isoformat(),
                "valid": has_cluster_ini,
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
shard_enabled = false
bind_ip = 127.0.0.1
master_ip = 127.0.0.1
master_port = 10888
cluster_key = dstserverkey
"""

SERVER_INI_TEMPLATE = """\
[NETWORK]
server_port = 10999

[SHARD]
is_master = true

[STEAM]
authentication_port = 8766
master_server_port = 27016

[ACCOUNT]
encode_user_path = true
"""

MODOVERRIDES_TEMPLATE = """\
return {
}
"""


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
    (cd / "Master").mkdir(parents=True, exist_ok=True)

    (cd / "cluster.ini").write_text(
        CLUSTER_INI_TEMPLATE.format(
            game_mode=game_mode,
            max_players=max_players,
            pvp="true" if pvp else "false",
            cluster_name=cluster_name,
            cluster_description=description.replace("\n", " "),
            password=password,
            intention=intention,
        ),
        encoding="utf-8",
    )
    (cd / "Master" / "server.ini").write_text(SERVER_INI_TEMPLATE, encoding="utf-8")
    (cd / "Master" / "modoverrides.lua").write_text(MODOVERRIDES_TEMPLATE, encoding="utf-8")
    (cd / "adminlist.txt").write_text("", encoding="utf-8")
    # cluster_token.txt is intentionally NOT written here — the DST entrypoint
    # writes it from $CLUSTER_TOKEN in .env on launch.
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


def run_backup(tag: str = "manual") -> tuple[bool, str]:
    env = read_env_file()
    if not r2_env_ready(env):
        return False, "R2 env vars not set in .env"
    if not cluster_is_ready():
        return False, f"Cluster '{CLUSTER_NAME}' not provisioned yet"

    rclone_env = os.environ.copy()
    rclone_env.update(
        {
            "RCLONE_CONFIG_R2_TYPE": "s3",
            "RCLONE_CONFIG_R2_PROVIDER": "Cloudflare",
            "RCLONE_CONFIG_R2_ACCESS_KEY_ID": env["R2_ACCESS_KEY_ID"],
            "RCLONE_CONFIG_R2_SECRET_ACCESS_KEY": env["R2_SECRET_ACCESS_KEY"],
            "RCLONE_CONFIG_R2_ENDPOINT": f"https://{env['R2_ACCOUNT_ID']}.r2.cloudflarestorage.com",
            "RCLONE_CONFIG_R2_REGION": "auto",
        }
    )

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


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

app = FastAPI(title="DST admin panel", docs_url=None, redoc_url=None, openapi_url=None)
app.mount("/static", StaticFiles(directory=str(APP_ROOT / "static")), name="static")


# ---- Dashboard ----

@app.get("/", response_class=HTMLResponse)
def dashboard(request: Request, _: str = Depends(require_auth)) -> HTMLResponse:
    env = read_env_file()
    cd = cluster_dir()
    modoverrides_path = cd / "Master" / "modoverrides.lua"
    mods_setup_path = MODS_DIR / "dedicated_server_mods_setup.lua"
    adminlist_path = cd / "adminlist.txt"
    return TEMPLATES.TemplateResponse(
        request=request,
        name="index.html",
        context={
            "cluster_name": CLUSTER_NAME,
            "cluster_ready": cluster_is_ready(),
            "cluster_exists": cd.exists(),
            "dst": dst_status(),
            "parked": list_parked(),
            "r2_ready": r2_env_ready(env),
            "adminlist": adminlist_path.read_text(encoding="utf-8") if adminlist_path.is_file() else "",
            "mods_setup": mods_setup_path.read_text(encoding="utf-8") if mods_setup_path.is_file() else "",
            "modoverrides": modoverrides_path.read_text(encoding="utf-8") if modoverrides_path.is_file() else "",
            "env_keys": sorted(read_env_file().keys()),
        },
    )


@app.get("/status", response_class=PlainTextResponse)
def json_status(_: str = Depends(require_auth)) -> Response:
    data = {
        "cluster": CLUSTER_NAME,
        "cluster_ready": cluster_is_ready(),
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
    zipfile_field: UploadFile = File(..., alias="zipfile"),
    park_name: str = Form(...),
    _: str = Depends(require_auth),
) -> RedirectResponse:
    name = safe_name(park_name)
    dest = PARKED_DIR / name
    if dest.exists():
        raise HTTPException(status_code=409, detail=f"Parked slot '{name}' already exists")

    raw = await zipfile_field.read()
    if not raw:
        raise HTTPException(status_code=400, detail="Empty upload")

    try:
        zf = zipfile.ZipFile(io.BytesIO(raw))
    except zipfile.BadZipFile:
        raise HTTPException(status_code=400, detail="Not a valid zip file")

    # Protection: no path escaping ("../"), no absolute paths.
    for n in zf.namelist():
        p = Path(n)
        if p.is_absolute() or ".." in p.parts:
            raise HTTPException(status_code=400, detail=f"Unsafe zip entry: {n}")

    dest.mkdir(parents=True)
    zf.extractall(dest)

    # If the zip contains a single top-level folder (e.g. "my-world/"),
    # flatten so dest/cluster.ini is directly under dest/.
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
        # Write into parked/, then user can activate later.
        original_saves = SAVES_DIR
        # Trick: redirect SAVES_DIR to PARKED_DIR for this call.
        cd_target = PARKED_DIR / name
        if cd_target.exists():
            raise HTTPException(status_code=409, detail=f"Parked '{name}' already exists")
        # Compose the files directly without the helper (which wants SAVES_DIR).
        (cd_target / "Master").mkdir(parents=True)
        (cd_target / "cluster.ini").write_text(
            CLUSTER_INI_TEMPLATE.format(
                game_mode=game_mode,
                max_players=max_players,
                pvp="true" if pvp else "false",
                cluster_name=name,
                cluster_description=description.replace("\n", " "),
                password=password,
                intention="cooperative",
            ),
            encoding="utf-8",
        )
        (cd_target / "Master" / "server.ini").write_text(SERVER_INI_TEMPLATE, encoding="utf-8")
        (cd_target / "Master" / "modoverrides.lua").write_text(MODOVERRIDES_TEMPLATE, encoding="utf-8")
        (cd_target / "adminlist.txt").write_text("", encoding="utf-8")
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
    modoverrides: str = Form(""),
    _: str = Depends(require_auth),
) -> RedirectResponse:
    MODS_DIR.mkdir(exist_ok=True)
    (MODS_DIR / "dedicated_server_mods_setup.lua").write_text(mods_setup, encoding="utf-8")
    if cluster_is_ready():
        (cluster_dir() / "Master" / "modoverrides.lua").write_text(modoverrides, encoding="utf-8")
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


BOOTSTRAP_SH = """\
#!/usr/bin/env bash
# Generated by the DST admin panel.
# Paste this whole file onto a fresh Ubuntu 22.04/24.04 Vultr VPS (scp + sudo bash).
# All secrets (cluster token, admin password, R2 credentials) are baked in —
# no further interaction required. R2 credentials are mandatory; DST exits on
# launch if any are missing.
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/moxxiq/dst-dedicated-container.git}"
TARGET="${TARGET:-/home/dst/steamCMD}"

if ! id dst >/dev/null 2>&1; then
  useradd -m -s /bin/bash dst
fi

apt-get update
apt-get install -y --no-install-recommends podman git rsync ca-certificates

sudo -u dst -H git clone "$REPO_URL" "$TARGET" 2>/dev/null || (cd "$TARGET" && sudo -u dst git pull)

cat > "$TARGET/.env" <<'ENVEOF'
{env_body}
ENVEOF
chown dst:dst "$TARGET/.env"
chmod 0600 "$TARGET/.env"

chown -R 1000:1000 "$TARGET/saves" "$TARGET/mods" "$TARGET/parked" 2>/dev/null || true

sudo -u dst -H bash -c "cd '$TARGET' && podman build --platform=linux/amd64 -t local/steamcmd:latest ."
sudo -u dst -H bash -c "cd '$TARGET' && ./run-dst.sh start"
sudo -u dst -H bash -c "cd '$TARGET/admin' && podman build --platform=linux/amd64 -t local/dst-admin:latest . && podman compose up -d"

echo "== bootstrap complete =="
echo "DST container:   podman logs -f dst"
echo "Admin panel:     http://<this-vps-ip>:8080  (user: $ADMIN_USER_LINE)"
"""


@app.get("/bootstrap/script")
def bootstrap_script(_: str = Depends(require_auth)) -> Response:
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
    body = BOOTSTRAP_SH.replace("{env_body}", render_env_file(env).strip()).replace(
        "$ADMIN_USER_LINE", env.get("ADMIN_USER", "admin")
    )
    return Response(
        content=body,
        media_type="text/x-shellscript; charset=utf-8",
        headers={"Content-Disposition": 'attachment; filename="bootstrap.sh"'},
    )
