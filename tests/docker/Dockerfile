# Минимальное окружение для e2e-проверки autoXRAY: настоящие nginx и Xray, без systemd.
FROM nginx:1.28

ARG XRAY_VERSION=v26.10.21

RUN apt-get update \
 && apt-get install -y --no-install-recommends jq curl openssl ca-certificates unzip qrencode iproute2 procps python3 util-linux \
 && rm -rf /var/lib/apt/lists/*

# Xray с проверкой контрольной суммы из официального .dgst
RUN set -eux; \
    base="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}"; \
    curl -fsSL -o /tmp/xray.zip "$base/Xray-linux-64.zip"; \
    curl -fsSL -o /tmp/xray.dgst "$base/Xray-linux-64.zip.dgst"; \
    want="$(grep -i 'SHA2-256' /tmp/xray.dgst | head -n1 | sed 's/.*= *//')"; \
    echo "$want  /tmp/xray.zip" | sha256sum -c -; \
    mkdir -p /usr/local/share/xray /usr/local/etc/xray /var/log/xray /var/lib/xray/cert; \
    unzip -q /tmp/xray.zip -d /tmp/xray; \
    install -m 755 /tmp/xray/xray /usr/local/bin/xray; \
    install -m 644 /tmp/xray/geoip.dat /tmp/xray/geosite.dat /usr/local/share/xray/; \
    rm -rf /tmp/xray /tmp/xray.zip /tmp/xray.dgst

# Гео-данные как на настоящем сервере: официальный установщик Xray берёт их из Loyalsoldier/v2ray-rules-dat (в архиве ядра набор другой)
RUN set -eux; \
    for f in geoip geosite; do \
      curl -fsSL -o /usr/local/share/xray/$f.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$f.dat"; \
      want="$(curl -fsSL "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/$f.dat.sha256sum" | cut -d' ' -f1)"; \
      echo "$want  /usr/local/share/xray/$f.dat" | sha256sum -c -; \
    done

ENV XRAY_LOCATION_ASSET=/usr/local/share/xray

COPY systemctl-shim.sh /usr/local/bin/systemctl
RUN chmod +x /usr/local/bin/systemctl

WORKDIR /opt/autoxray
CMD ["sleep", "infinity"]
