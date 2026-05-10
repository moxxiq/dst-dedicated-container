# Pinned to ubuntu-24 (Ubuntu 24.04 LTS) — current tag as of 2026-04-18.
# To bump: check https://hub.docker.com/r/steamcmd/steamcmd/tags
#
# Note on users: this tag ships with `ubuntu` (UID 1000) and no `steam` user.
# We use `ubuntu` — UID 1000 matches typical host users and keeps bind-mount perms sane.
FROM --platform=linux/amd64 docker.io/steamcmd/steamcmd:ubuntu-24

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      tini \
      locales \
      procps \
      curl \
      libcurl3-gnutls \
      rclone \
      inotify-tools \
      zip \
      unzip \
 && locale-gen en_US.UTF-8 \
 && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    HOME=/home/ubuntu \
    STEAM_HOME=/home/ubuntu/.local/share/Steam \
    DST_DIR=/home/ubuntu/dst \
    KLEI_DIR=/home/ubuntu/.klei

RUN install -d -o ubuntu -g ubuntu \
      "$STEAM_HOME" \
      "$DST_DIR" \
      "$KLEI_DIR" \
      "$KLEI_DIR/DoNotStarveTogether" \
      /home/ubuntu/.steam \
      /home/ubuntu/Steam/logs \
      /home/ubuntu/user-mods \
    # Some steamcmd internals hardcode $HOME/Steam/logs/stderr.txt; pre-create it.
    && ln -sf "$STEAM_HOME" /home/ubuntu/.steam/root \
    && ln -sf "$STEAM_HOME" /home/ubuntu/.steam/steam

COPY --chown=root:root entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER ubuntu
WORKDIR /home/ubuntu

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
# Default: run the full DST lifecycle. Override with `steamcmd +quit` for a smoke test,
# or `bash` for an interactive shell.
CMD ["dst"]
