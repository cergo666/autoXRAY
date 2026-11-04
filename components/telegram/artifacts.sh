#!/usr/bin/env bash
# Immutable third-party inputs for the optional Telegram backend.
# Update versions and hashes together after checking the upstream release/commit.

TELEMT_VERSION="3.5.16"
TPROXY_COMMIT="c8adb8b7c6b7fc46c12ae3acb68be9070c26a8e8"
TPROXY_SHA256="a78b48f536180143dd7005785ca397310c36ee0b132e19949a45d64f586ab549"

telegram_fetch_verified() {
    local url=$1 expected=$2 output=$3 tmp
    tmp=$(mktemp -d) || return 1
    if ! "${AX_TELEGRAM_CURL:-curl}" -fsSL --retry 2 "$url" -o "$tmp/artifact"; then
        echo "Не удалось скачать закреплённый артефакт: $url" >&2
        rm -rf "$tmp"
        return 1
    fi
    if ! printf '%s  %s\n' "$expected" "$tmp/artifact" | sha256sum -c --quiet -; then
        echo "SHA-256 стороннего артефакта не совпал: $url" >&2
        rm -rf "$tmp"
        return 1
    fi
    cp "$tmp/artifact" "$output" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
}

telegram_install_telemt() {
    local destination=$1 arch libc asset sha tmp entries
    arch=$(uname -m)
    libc=gnu
    ldd --version 2>&1 | grep -iq musl && libc=musl
    case "$arch/$libc" in
        x86_64/gnu)
            asset="telemt-x86_64-linux-gnu.tar.gz"
            sha="e6f46b2f3becf29bfd555cec8a059e429f7c082c1af402499b3a7940cf8ebd34" ;;
        x86_64/musl)
            asset="telemt-x86_64-linux-musl.tar.gz"
            sha="05d7c32eff5990285657408cf383614d845ecc06aac0d5adc02a86d72c907146" ;;
        aarch64/gnu)
            asset="telemt-aarch64-linux-gnu.tar.gz"
            sha="1e1bc87f05923b9673cbbaf34a3e50f7fdcf7d496cd24efcdb34c278ed18a659" ;;
        aarch64/musl)
            asset="telemt-aarch64-linux-musl.tar.gz"
            sha="33d7b2aa55f8852ddcc59e0fa8f5ad9bca3ce94d9fea6665b918e9ae91820ae3" ;;
        *) echo "TeleMT $TELEMT_VERSION не поддерживает архитектуру/либc: $arch/$libc" >&2; return 1 ;;
    esac

    tmp=$(mktemp -d) || return 1
    if ! telegram_fetch_verified "https://github.com/telemt/telemt/releases/download/$TELEMT_VERSION/$asset" "$sha" "$tmp/archive.tar.gz"; then
        rm -rf "$tmp"; return 1
    fi
    entries=$(tar -tzf "$tmp/archive.tar.gz") || { rm -rf "$tmp"; return 1; }
    if [[ $entries != telemt ]] \
        || ! tar --no-same-owner --no-same-permissions -xzf "$tmp/archive.tar.gz" -C "$tmp" telemt \
        || [[ ! -f $tmp/telemt ]]; then
        echo "Архив TeleMT $TELEMT_VERSION имеет неожиданный состав." >&2
        rm -rf "$tmp"; return 1
    fi
    install -m 755 "$tmp/telemt" "$destination" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
}

telegram_extract_tproxy_source() {
    local destination=$1 tmp
    tmp=$(mktemp -d) || return 1
    if ! telegram_fetch_verified \
        "https://codeload.github.com/telegramdesktop/tproxy-server/tar.gz/$TPROXY_COMMIT" \
        "$TPROXY_SHA256" "$tmp/source.tar.gz"; then
        rm -rf "$tmp"; return 1
    fi
    mkdir -p "$destination" \
        && tar --no-same-owner --no-same-permissions -xzf "$tmp/source.tar.gz" -C "$destination" --strip-components=1 \
        || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
}
