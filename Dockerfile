# Base image pinned by digest for reproducible builds.
# Tag at pin time: cm2network/steamcmd:root (Debian 13 "trixie").
# Refresh: docker buildx imagetools inspect cm2network/steamcmd:root
FROM        cm2network/steamcmd:root@sha256:e6b6b3503bf0e41feafe12dc709c90151afba193e1292cac55d28a7d470b1493

LABEL       org.opencontainers.image.source="https://github.com/castrowithc/arkserver"

ARG         ARK_TOOLS_VERSION="8ddf0b83dc82243d8fc9ecf9bf4bac62c6911c73"
ARG         IMAGE_VERSION="dev"

# NOTE: SERVER_PASSWORD/ADMIN_PASSWORD are intentionally NOT baked into the image
# (avoids the SecretsUsedInArgOrEnv build warning and shipping default credentials).
# Provide them at runtime via .env / -e. steam-entrypoint.sh warns if ADMIN_PASSWORD is unset.
ENV         IMAGE_VERSION="${IMAGE_VERSION}" \
            SESSION_NAME="ARK: Survival Evolved Server" \
            SERVER_MAP="TheIsland" \
            MAX_PLAYERS="20" \
            GAME_MOD_IDS="" \
            UPDATE_ON_START="false" \
            BACKUP_ON_STOP="false" \
            PRE_UPDATE_BACKUP="true" \
            WARN_ON_STOP="true" \
            CLUSTER_ID="" \
            SUB_INSTANCE_KEYS="" \
            SERVER_MAP_MOD_ID="" \
            PUID="1000" \
            PGID="1000" \
            UMASK="0002" \
            ARK_TOOLS_VERSION="${ARK_TOOLS_VERSION}" \
            ARK_SERVER_VOLUME="/app" \
            BETA="" \
            BETA_ACCESSCODE="" \
            TEMPLATE_DIRECTORY="/conf.d" \
            GAME_CLIENT_PORT="7777" \
            UDP_SOCKET_PORT="7778" \
            RCON_PORT="27020" \
            SERVER_LIST_PORT="27015" \
            STEAM_HOME="/home/${USER}" \
            STEAM_USER="${USER}" \
            STEAM_LOGIN="anonymous"

ENV         ARK_TOOLS_DIR="${ARK_SERVER_VOLUME}/arkmanager"

# apt-get upgrade patcht OS-Pakete des (digest-gepinnten) Basis-Images auf den
# aktuellen Debian-Stand — hält CVE-Fixes unabhängig vom Basis-Image-Refresh
# aktuell (z. B. openssl CVE-2026-31789). Der CI-Trivy-Scan (Phase 7) erzwingt das.
RUN         set -x && \
            apt-get update && \
            apt-get upgrade -y && \
            apt-get install -y  perl-modules \
                                curl \
                                lsof \
                                libc6-i386 \
                                lib32gcc-s1 \
                                bzip2 \
                                gosu \
                                cron \
                                procps \
            && \
            apt-get purge -y --auto-remove sudo 2>/dev/null || true && \
            install -d -m 0755 -o ${USER} -g ${USER} /var/spool/cron/crontabs && \
            opt=$([ "${ARK_TOOLS_VERSION#v}" != "${ARK_TOOLS_VERSION}" ] && echo -n "--tag" || echo -n "--commit") && \
            curl -sL https://raw.githubusercontent.com/arkmanager/ark-server-tools/refs/heads/master/netinstall.sh | \
            bash -s ${USER} ${opt}=${ARK_TOOLS_VERSION} && \
            ln -s /usr/local/bin/arkmanager /usr/bin/arkmanager && \
            install -d -o ${USER} ${ARK_SERVER_VOLUME} && \
            su ${USER} -c "bash -x ${STEAMCMDDIR}/steamcmd.sh +login anonymous +quit" && \
            apt-get -qq autoclean && apt-get -qq autoremove && apt-get -qq clean && \
            rm -rf /tmp/* /var/cache/*

# --chmod, weil das Exec-Bit nicht im Git-Index steht (die Skripte sind dort 100644):
# ein Linux-Checkout wuerde sie sonst als 644 kopieren und der Container startet nicht.
COPY --chmod=0755 bin/    /
COPY        conf.d  ${TEMPLATE_DIRECTORY}

# Relocate the SteamCMD ANSI-strip wrapper next to the real steamcmd.sh inside
# steamcmdroot (=${STEAM_HOME}/steamcmd) and out of / (#97, #91).
RUN         install -D -m 0755 -o ${USER} -g ${USER} \
                /steamcmd-stripansi.sh "${STEAM_HOME}/steamcmd/steamcmd-stripansi.sh" && \
            rm -f /steamcmd-stripansi.sh

EXPOSE      ${GAME_CLIENT_PORT}/udp ${UDP_SOCKET_PORT}/udp ${SERVER_LIST_PORT}/udp ${RCON_PORT}/tcp

VOLUME      ["${ARK_SERVER_VOLUME}"]
WORKDIR     ${ARK_SERVER_VOLUME}

ENTRYPOINT  ["/docker-entrypoint.sh"]
CMD         []
