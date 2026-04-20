# Admin panel — FastAPI + Jinja2 + podman CLI.
# Talks to the host's DST container via the mounted podman socket.
# Pinned Python to 3.12 (Debian slim); bump when the base moves.
FROM python:3.12-slim

# `podman` CLI for managing the DST container (remote via mounted socket).
# `rclone` so the "manual backup" endpoint can push to R2 without exec-ing
# into the DST container (avoids a dependency on DST being up).
RUN apt-get update && apt-get install -y --no-install-recommends \
      podman \
      rclone \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

EXPOSE 8080

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
