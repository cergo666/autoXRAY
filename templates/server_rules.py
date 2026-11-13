#!/usr/bin/env python3
"""Server-side Xray policy for autoXRAY direct mode.

Pure transform + atomic state editor. The caller (autoxray CLI) holds the
existing autoXRAY flock through state edit, Xray validation and rollback.
No subprocesses, no shell execution, no direct changes to Xray services.
"""
from __future__ import annotations

import html
import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path

FILTERS = {
    "ipcheck": "Сайты проверки IP",
    "ads": "Реклама",
    "spyware": "Windows-телеметрия",
    "bittorrent": "BitTorrent",
}
# Keep default set in sync with the dedicated IP-check rule in autoxray.
IPCHECK = frozenset({"ifconfig.me", "checkip.amazonaws.com", "pify.org", "2ip.io", "geosite:category-ip-geo-detect"})
DENY_SUFFIXES = (".local", ".localhost", ".internal", ".lan", ".home.arpa", ".invalid", ".test")
DOMAIN = re.compile(r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?")


class PolicyError(ValueError):
    pass


def valid_domain(raw: str) -> bool:
    return (isinstance(raw, str) and len(raw) <= 253 and raw.isascii()
            and DOMAIN.fullmatch(raw) is not None
            and not raw.endswith(DENY_SUFFIXES))


def policy_of(state: dict) -> dict:
    obj = state.get("server_policy")
    if obj is None:
        obj = {}
    if not isinstance(obj, dict):
        raise PolicyError("Неверный тип server_policy")
    return obj


def filters_of(state: dict) -> dict:
    filters = policy_of(state).get("filters")
    if filters is None:
        filters = {}
    if not isinstance(filters, dict):
        raise PolicyError("Неверный тип filters")
    for key in FILTERS:
        if key in filters and type(filters[key]) is not bool:
            raise PolicyError("Некорректное значение фильтра: " + key)
    return {key: filters.get(key, True) for key in FILTERS}


def domains_of(state: dict, field: str) -> list[str]:
    values = policy_of(state).get(field, [])
    if (not isinstance(values, list) or len(values) > 100
            or any(not valid_domain(x) for x in values)
            or len(set(values)) != len(values)):
        raise PolicyError("Некорректный список " + field)
    return values


def validate(state: dict) -> tuple[dict, list[str], list[str]]:
    if not isinstance(state, dict):
        raise PolicyError("Некорректное состояние")
    filters = filters_of(state)
    allowed = domains_of(state, "allow_domains")
    blocked = domains_of(state, "block_domains")
    if len(allowed) + len(blocked) > 100 or set(allowed) & set(blocked):
        raise PolicyError("Конфликт или превышение лимита доменов")
    return filters, allowed, blocked


def transformed(raw: str, state: dict) -> str:
    if not policy_of(state):
        return raw  # Byte-for-byte compatibility with an unconfigured installation.
    if state.get("mode", "direct") != "direct":
        return raw  # Policy does not affect bridge routing.
    flags, allowed, blocked = validate(state)
    cfg = json.loads(raw)
    route = cfg.get("routing")
    if not isinstance(route, dict) or not isinstance(route.get("rules"), list):
        raise PolicyError("Отсутствуют routing.rules")
    outbounds = {x.get("tag") for x in cfg.get("outbounds", []) if isinstance(x, dict)}
    if not {"direct", "block", "block-bt"}.issubset(outbounds):
        raise PolicyError("Отсутствует обязательный outbound")

    kept = []
    for rule in route["rules"]:
        if not isinstance(rule, dict):
            raise PolicyError("Некорректный Xray rule")
        # Re-rendering an already transformed config must not duplicate overrides.
        if rule.get("ruleTag") in ("ax-policy-allow", "ax-policy-block"):
            continue
        tag = rule.get("outboundTag")
        domains = rule.get("domain", [])
        if not isinstance(domains, list):
            raise PolicyError("Некорректный список domain")
        if tag == "block-bt" and rule.get("protocol") == ["bittorrent"] and not flags["bittorrent"]:
            continue
        if tag == "block" and domains:
            skip = set()
            if not flags["ads"]:
                skip.add("geosite:category-ads")
            if not flags["spyware"]:
                skip.add("geosite:win-spy")
            if not flags["ipcheck"]:
                # Never delete unrelated custom rules: only touch the dedicated IP-check group.
                if set(domains) == IPCHECK or (set(domains) <= IPCHECK and "2ip.io" in domains):
                    continue
            if skip.intersection(domains):
                rule = dict(rule)
                rule["domain"] = [x for x in domains if x not in skip]
                if not rule["domain"]:
                    continue
        kept.append(rule)

    # Do not weaken the non-negotiable restrictions if upstream changes routing order.
    # In particular, a domain allow must never preempt user/IP limits or private IP.
    critical = [i for i, rule in enumerate(kept)
                if (rule.get("outboundTag") == "block"
                    and ("geoip:private" in rule.get("ip", [])
                         or "port" in rule or "user" in rule))]
    first_domain = next((i for i, rule in enumerate(kept) if rule.get("domain")), len(kept))
    if critical and first_domain <= max(critical):
        raise PolicyError("Непредусмотренный порядок защитных правил Xray")
    index = first_domain
    extras = []
    if allowed:
        extras.append({"domain": ["domain:" + x for x in allowed], "outboundTag": "direct", "ruleTag": "ax-policy-allow"})
    if blocked:
        extras.append({"domain": ["domain:" + x for x in blocked], "outboundTag": "block", "ruleTag": "ax-policy-block"})
    route["rules"] = kept[:index] + extras + kept[index:]
    return json.dumps(cfg, ensure_ascii=False, indent=2) + "\n"


def change(state: dict, operation: str, key: str, value: str | None = None) -> bool:
    if state.get("mode", "direct") != "direct":
        raise PolicyError("Правила доступны только в режиме direct")
    validate(state)
    new = json.loads(json.dumps(state))
    policy = new.setdefault("server_policy", {})
    if operation == "set":
        if key not in FILTERS or value not in ("on", "off"):
            raise PolicyError("Использование: set ipcheck|ads|spyware|bittorrent on|off")
        desired = value == "on"
        if filters_of(new)[key] == desired:
            return False
        policy.setdefault("filters", {})[key] = desired
    elif operation in ("allow", "block", "del"):
        if value is not None or not valid_domain(key):
            raise PolicyError("Требуется один допустимый домен, например example.com")
        allow = set(domains_of(new, "allow_domains"))
        block = set(domains_of(new, "block_domains"))
        before = (allow.copy(), block.copy())
        if operation == "allow":
            block.discard(key)
            allow.add(key)
        elif operation == "block":
            allow.discard(key)
            block.add(key)
        else:
            allow.discard(key)
            block.discard(key)
        if before == (allow, block):
            return False
        policy["allow_domains"] = sorted(allow)
        policy["block_domains"] = sorted(block)
    else:
        raise PolicyError("Неизвестная операция")
    validate(new)
    state.clear()
    state.update(new)
    return True


def atomic_write(path: Path, state: dict) -> None:
    meta = path.stat()
    fd, name = tempfile.mkstemp(prefix=".server-policy-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as out:
            json.dump(state, out, ensure_ascii=False, indent=2)
            out.write("\n")
            out.flush()
            os.fsync(out.fileno())
        os.chown(name, meta.st_uid, meta.st_gid)
        os.chmod(name, stat.S_IMODE(meta.st_mode))
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def status(state: dict) -> str:
    if state.get("mode", "direct") != "direct":
        return "📜 <b>Правила Xray</b>\nДоступно только в режиме direct; bridge не изменён."
    flags, allowed, blocked = validate(state)
    result = ["📜 <b>Серверные правила Xray</b>", "Фильтры применяются ко всем пользователям.", ""]
    for key, label in FILTERS.items():
        result.append(("🔴 " if flags[key] else "🟢 ") + html.escape(label)
                      + ": <b>" + ("БЛОК" if flags[key] else "РАЗРЕШЕНО") + "</b>")
    result += ["", "🔐 <b>Неизменяемые ограничения</b>",
               "• Приватные IP, почтовые/SMB-порты, лимиты пользователей", "",
               "✅ <b>Разрешённые домены</b>"]
    result += ["• <code>" + html.escape(d) + "</code>" for d in allowed[:20]] or ["Нет"]
    if len(allowed) > 20:
        result.append("…и ещё " + str(len(allowed) - 20))
    result += ["", "🚫 <b>Заблокированные домены</b>"]
    result += ["• <code>" + html.escape(d) + "</code>" for d in blocked[:20]] or ["Нет"]
    if len(blocked) > 20:
        result.append("…и ещё " + str(len(blocked) - 20))
    result += ["", "➕ /rule allow example.com", "🚫 /rule block example.com", "🗑 /rule del example.com",
               "", "ℹ️ Изменения действуют на сервере, а не в клиентских подписках."]
    return "\n".join(result)


def keyboard(state: dict) -> str:
    if state.get("mode", "direct") != "direct":
        return json.dumps({"inline_keyboard": [[{"text": "⬅️ Назад", "callback_data": "status"}]]})
    flags, _, _ = validate(state)
    rows = []
    for key, title in FILTERS.items():
        desired = "off" if flags[key] else "on"
        rows.append([{"text": ("🔓 Разрешить · " if flags[key] else "🔒 Заблокировать · ") + title,
                      "callback_data": f"r:ask:{key}:{desired}"}])
    rows.extend([
        [{"text": "➕ Разрешить домен", "callback_data": "r:help:allow"},
         {"text": "🚫 Заблокировать домен", "callback_data": "r:help:block"}],
        [{"text": "🔄 Обновить", "callback_data": "r:show"},
         {"text": "⬅️ Назад", "callback_data": "status"}],
    ])
    return json.dumps({"inline_keyboard": rows}, ensure_ascii=False, separators=(",", ":"))


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        raise PolicyError("Использование: server_rules.py STATE transform|status|keyboard|edit ...")
    path = Path(argv[1])
    operation = argv[2]
    state = json.loads(path.read_text(encoding="utf-8"))
    if operation == "transform":
        if len(argv) != 3:
            raise PolicyError("Лишние аргументы")
        sys.stdout.write(transformed(sys.stdin.read(), state))
    elif operation == "status" and len(argv) == 3:
        print(status(state))
    elif operation == "keyboard" and len(argv) == 3:
        print(keyboard(state))
    elif operation == "edit" and 4 <= len(argv) <= 6:
        if os.geteuid() != 0 and os.environ.get("AX_DRY") != "1":
            raise PolicyError("Изменение правил требует root")
        args = argv[3:]
        if args[0] == "set" and len(args) != 3:
            raise PolicyError("Неверное число аргументов")
        if args[0] in ("allow", "block", "del") and len(args) != 2:
            raise PolicyError("Неверное число аргументов")
        if change(state, args[0], args[1], args[2] if len(args) == 3 else None):
            atomic_write(path, state)
            print("CHANGED")
        else:
            print("UNCHANGED")
    else:
        raise PolicyError("Неизвестная команда или неверные аргументы")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except (PolicyError, OSError, TypeError, json.JSONDecodeError) as error:
        print("Ошибка правил: " + str(error), file=sys.stderr)
        raise SystemExit(1) from None
