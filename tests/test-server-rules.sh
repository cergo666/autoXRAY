#!/usr/bin/env bash
# shellcheck disable=SC2016 # Single-quoted bash -c snippets intentionally expand in child shell.
# Standalone, unprivileged regression suite: bash tests/test-server-rules.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export AX_DRY=1 PYTHONDONTWRITEBYTECODE=1
python3 - <<'PY'
import importlib.util, json, os, pathlib, tempfile, unittest
p = pathlib.Path('templates/server_rules.py')
spec = importlib.util.spec_from_file_location('server_rules', p)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
base = {"mode":"direct","users":[]}
rules = [
    {"inboundTag":["api"],"outboundTag":"api"},
    {"user":["alice"],"source":["10.0.0.1"],"outboundTag":"block"},
    {"ip":["geoip:private"],"outboundTag":"block"},
    {"port":"25, 135, 137-139, 445","outboundTag":"block"},
    {"protocol":["bittorrent"],"outboundTag":"block-bt"},
    {"domain":["geosite:category-ads","geosite:win-spy","geosite:private"],"outboundTag":"block"},
    {"domain":["warp.example"],"outboundTag":"warp"},
    {"domain":["ifconfig.me","checkip.amazonaws.com","pify.org","2ip.io","geosite:category-ip-geo-detect"],"outboundTag":"block"},
]
outbounds = [{"tag":"direct","protocol":"freedom","settings":{}},
             {"tag":"block","protocol":"blackhole"},{"tag":"block-bt","protocol":"blackhole"}]
raw = json.dumps({"routing":{"domainStrategy":"IPIfNonMatch","rules":rules},"outbounds":outbounds})

class RulesTest(unittest.TestCase):
    def test_unconfigured_unchanged(self):
        self.assertEqual(m.transformed(raw,base),raw)
    def test_bridge_untouched(self):
        self.assertEqual(m.transformed(raw,{"mode":"bridge","server_policy":{"filters":{"ads":False}}}),raw)
    def test_filter_controls_no_protection_removal(self):
        s={**base,"server_policy":{"filters":{"ads":False,"spyware":False,"ipcheck":False,"bittorrent":False}}}
        result=json.loads(m.transformed(raw,s))['routing']['rules']
        self.assertEqual(result[:4],rules[:4]); self.assertEqual(len(result),6)
        self.assertEqual(result[5], rules[6])
        self.assertEqual(result[4]['domain'],['geosite:private'])
    def test_specific_exceptions_order(self):
        s={**base,"server_policy":{"allow_domains":["example.com"],"block_domains":["sub.example.com"]}}
        config=json.loads(m.transformed(raw,s))
        route=config['routing']
        self.assertEqual(route['domainStrategy'],'IPIfNonMatch')
        out=route['rules']
        self.assertEqual(out[:5],rules[:5])
        self.assertEqual(out[5],{"domain":["geosite:private"],"outboundTag":"block"})
        self.assertEqual(out[6]['ruleTag'],'ax-policy-block')
        self.assertEqual(out[7]['ruleTag'],'ax-policy-allow')
        self.assertEqual(out[7]['outboundTag'],'ax-policy-direct')
        self.assertEqual(out[8]['domain'],rules[5]['domain'][:2])
        self.assertEqual(out[9:],rules[6:])
        self.assertEqual(config['outbounds'][:3],outbounds)
        self.assertEqual(config['outbounds'][3]['settings']['finalRules'],
                         [{"action":"block","ip":["geoip:private"]}])
    def test_idempotent_no_duplicates(self):
        s={**base,"server_policy":{"allow_domains":["a.example"]}}
        first=m.transformed(raw,s)
        self.assertEqual(first,m.transformed(first,s))
        self.assertEqual(first.count('ax-policy-allow'),1)
    def test_unsafe_upstream_rule_order_rejected(self):
        s={**base,"server_policy":{"allow_domains":["a.example"]}}
        reordered=[rules[5], *rules[:5], *rules[6:]]
        with self.assertRaises(m.PolicyError):
            m.transformed(json.dumps({"routing":{"rules":reordered},"outbounds":outbounds}),s)
    def test_missing_or_conditional_private_ip_rule_rejected(self):
        s={**base,"server_policy":{"allow_domains":["a.example"]}}
        for private in ([], [{**rules[2], "inboundTag": ["one-inbound"]}]):
            with self.assertRaisesRegex(m.PolicyError, "приватных IP"):
                m.transformed(json.dumps({"routing":{"rules":rules[:2]+private+rules[3:]},
                                          "outbounds":outbounds}),s)
    def test_blocked_domain_validation(self):
        for domain in ('127.0.0.1','a.local','a..com','a.com;id','x'*64+'.com','https://example.com','*.example.com','a.test'):
            self.assertFalse(m.valid_domain(domain),domain)
        self.assertTrue(m.valid_domain('xn--e1afmkfd.xn--p1ai'))
    def test_conflict_rejected(self):
        s={**base,"server_policy":{"allow_domains":["example.com"],"block_domains":["example.com"]}}
        with self.assertRaises(m.PolicyError):m.transformed(raw,s)
    def test_invalid_missing_outbound(self):
        s={**base,"server_policy":{"filters":{"ads":False}}}
        broken=json.dumps({"routing":{"rules":rules},"outbounds":[{"tag":"direct"}]})
        with self.assertRaises(m.PolicyError):m.transformed(broken,s)
    def test_mutation_idempotent_and_reversible(self):
        s=dict(base)
        self.assertTrue(m.change(s,'block','example.com'))
        self.assertFalse(m.change(s,'block','example.com'))
        self.assertTrue(m.change(s,'allow','example.com'))
        self.assertEqual(m.domains_of(s,'block_domains'),[])
        self.assertTrue(m.change(s,'del','example.com'))
        self.assertFalse(m.change(s,'del','example.com'))
    def test_null_optional_fields_are_editable(self):
        for policy in (None, {"filters":None}):
            s={**base, "server_policy":policy}
            self.assertTrue(m.change(s,'set','ads','off'))
            self.assertFalse(m.filters_of(s)['ads'])
    def test_telegram_status_fits_with_long_domains(self):
        suffix = ".".join(("a"*63, "b"*63, "c"*63, "example"))
        s={**base, "server_policy":{"allow_domains":[f"allow{i}.{suffix}" for i in range(50)],
                                    "block_domains":[f"block{i}.{suffix}" for i in range(50)]}}
        msg=m.status(s)
        self.assertLessEqual(len(msg.encode("utf-16-le")) // 2,4096)
        self.assertEqual(msg.count("…и ещё"),2)
    def test_limits(self):
        s=dict(base)
        for i in range(100):m.change(s,'allow',f'a{i}.example.com')
        with self.assertRaises(m.PolicyError):m.change(s,'allow','overflow.example.com')
    def test_bridge_edit_denied(self):
        with self.assertRaises(m.PolicyError):m.change({'mode':'bridge'},'block','example.com')
    def test_atomic_write_preserves_mode(self):
        with tempfile.TemporaryDirectory() as t:
            f=pathlib.Path(t)/'state.json';f.write_text('{}');f.chmod(0o600)
            m.atomic_write(f,{'mode':'direct'})
            self.assertEqual(f.stat().st_mode & 0o777,0o600)
    def test_stale_action_rejects_repeated_edit(self):
        s=dict(base)
        self.assertTrue(m.change(s,'set','ads','off'))
        self.assertFalse(m.change(s,'set','ads','off'))
        self.assertTrue(m.change(s,'set','ads','on'))

unittest.main(verbosity=2)
PY
# Exercise the real render path with no interpreter (legacy self-update).
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export AX_ETC="$TMP" AX_XRAY_CFG="$TMP/xray.json" AX_TEMPLATES="$PWD/templates" AX_UNIT_TEST=1
export AX_SNAP_DIR="$TMP/snapshots" AX_RULE_CONFIRM_DIR="$TMP/confirm"
export AX_RULES_PYTHON
AX_RULES_PYTHON=$(command -v python3)
mkdir "$TMP/bin"
printf '%s\n' '#!/usr/bin/env bash' '[[ $1 == run && $2 == -test ]]' >"$TMP/bin/xray"
chmod +x "$TMP/bin/xray"
export PATH="$TMP/bin:$PATH"
printf '%s\n' '{"mode":"direct","domain":"example.com","users":[],"socks":{"user":"u","pass":"p"},"paths":{"xhttp":"abc"},"warp":{"registered":false},"nodes":[]}' >"$TMP/baseline"
printf '%s\n' '{}' >"$TMP/traffic.json"
printf '%s\n' '[]' >"$TMP/bans.json"
AX_RULES_PYTHON="$TMP/no-python3" bash -ec '
  source ./autoxray
  # Isolate syntax validation so the test needs neither Xray nor certificates.
  xray() { [[ $1 == run && $2 == -test ]]; }
  for edit in "." "del(.mode)" ".server_policy = null" ".server_policy = {}" \
    ".mode = \"bridge\" | .server_policy = {filters: {ads:false}}" \
    ".mode = \"bridge\" | .server_policy = \"unused\""; do
    jq "$edit" "$AX_ETC/baseline" >"$STATE"
    render_xray_json >"$AX_ETC/raw.json"
    apply_xray
    cmp "$AX_ETC/raw.json" "$XRAY_CFG"
  done
  cp "$XRAY_CFG" "$AX_ETC/live-config"
  for policy in "{filters: {ads:false}}" "false"; do
    jq ".server_policy = $policy" "$AX_ETC/baseline" >"$STATE"
    cp "$STATE" "$AX_ETC/live-state"
    if apply_xray; then echo "ERROR: invalid or unavailable policy accepted"; exit 1; fi
    cmp "$AX_ETC/live-config" "$XRAY_CFG"
    cmp "$AX_ETC/live-state" "$STATE"
  done
'

# Validation/restart failure leaves the prior state and file permissions intact.
install -m 600 "$TMP/baseline" "$TMP/state.json"
bash -ec '
  source ./autoxray
  xray() { [[ $1 == run && $2 == -test ]]; }
  apply_xray
  cp "$XRAY_CFG" "$AX_ETC/live-config"
  state_inode=$(stat -c %i "$STATE")
  xray() { return 1; }
  if locked cmd_rules_change block example.com; then echo "ERROR: rejected config accepted"; exit 1; fi
  cmp "$AX_ETC/baseline" "$STATE"
  cmp "$AX_ETC/live-config" "$XRAY_CFG"
  [[ $(stat -c %i "$STATE") == "$state_inode" && $(stat -c %a "$STATE") == 600 ]]
  xray() { [[ $1 == run && $2 == -test ]]; }
  svc() {
    # First restart fails, the restored config must be in place on retry.
    if [[ ! -e $AX_ETC/restart-failed ]]; then touch "$AX_ETC/restart-failed"; return 1; fi
    cmp "$AX_ETC/live-config" "$XRAY_CFG" && touch "$AX_ETC/restart-restored"
  }
  if locked cmd_rules_change block example.com; then echo "ERROR: failed restart accepted"; exit 1; fi
  [[ -f $AX_ETC/restart-restored ]]
  cmp "$AX_ETC/baseline" "$STATE"
  cmp "$AX_ETC/live-config" "$XRAY_CFG"
  [[ -z $(find "$AX_ETC" -maxdepth 1 -name ".state.rules.*" -print -quit) ]]
'
# Confirm valid edits and unchanged edits don't cause extra renders.
bash -ec '
  source ./autoxray
  apply_xray() {
    [[ $1 != "$STATE" ]] || return 1
    jq -e ".server_policy.allow_domains == [\"example.com\"]" "$1" >/dev/null || return 1
    jq -e ".server_policy == null" "$STATE" >/dev/null || return 1
    echo apply >>"$AX_ETC/calls"
  }
  locked cmd_rules_change allow example.com
  jq -e ".server_policy.allow_domains == [\"example.com\"]" "$STATE" >/dev/null
  locked cmd_rules_change allow example.com
  [[ $(wc -l <"$AX_ETC/calls") == 1 && $(stat -c %a "$STATE") == 600 ]]
'
# Older Xray releases can silently accept an unknown config key.
bash -ec '
  source ./autoxray
  xray_version() { echo v1.2.3; }
  xray() { touch "$AX_ETC/unexpected-xray"; }
  cp "$XRAY_CFG" "$AX_ETC/live-config"
  if apply_xray; then echo "ERROR: unsafe Xray version accepted"; exit 1; fi
  [[ ! -e $AX_ETC/unexpected-xray ]]
  cmp "$AX_ETC/live-config" "$XRAY_CFG"
  render_xray_with_rules "$STATE" >"$XRAY_CFG"
  check_rules_core "$XRAY_CFG" "$XRAY_RULES_MIN"
  if cmd_core update v1.2.3 --yes; then echo "ERROR: unsafe core downgrade accepted"; exit 1; fi
  mkdir -p "$AX_SNAP_DIR"
  snapshot="$AX_SNAP_DIR/protected.tar.gz"
  tar -C / -czf "$snapshot" "${XRAY_CFG#/}"
  if locked snapshot_unpack "$snapshot"; then echo "ERROR: unsafe rules snapshot restored"; exit 1; fi
'
# Telegram confirmation: bound to chat, filter, nonce and five-minute lifetime.
bash -c '
  source ./autoxray
  token=$(bot_rule_pending_save 12345678 ads off) || exit 1
  [[ $token =~ ^[0-9a-f]{16}$ ]] || exit 1
  if bot_rule_pending_consume 98765432 ads "$token"; then exit 1; fi
  if bot_rule_pending_consume 12345678 ipcheck "$token"; then exit 1; fi
  desired=$(bot_rule_pending_consume 12345678 ads "$token") || exit 1
  [[ $desired == off ]] || exit 1
  if bot_rule_pending_consume 12345678 ads "$token"; then exit 1; fi
  token=$(bot_rule_pending_save 12345678 ads off) || exit 1
  f=$(bot_rule_pending_file 12345678) || exit 1
  printf "%s ads off %s\n" "$token" "$(($(date +%s)-400))" >"$f"
  if bot_rule_pending_consume 12345678 ads "$token"; then exit 1; fi
'
# If the PR1 maintenance lock wrapper is installed, all edits must pass through it.
bash -c '
  source ./autoxray
  calls=0
  with_update_lock() { calls=$((calls+1)); return 75; }
  before=$(sha256sum "$STATE" | cut -d " " -f1)
  if cmd_rules set ads off; then exit 1; fi
  [[ $calls == 1 ]] || exit 1
  [[ $(sha256sum "$STATE" | cut -d " " -f1) == "$before" ]] || exit 1
'
# An otherwise unlocked state writer must wait for a failing rules edit.
bash -ec '
  source ./autoxray
  writer=""
  apply_xray() {
    if flock -n "$LOCK" -c true; then exit 1; fi
    (
      source ./autoxray
      touch "$AX_ETC/writer-ready"
      st_edit ".users += [{name:\"concurrent\"}]"
    ) 9>&- & echo "$!" >"$AX_ETC/writer-pid"
    for (( i=0; i<100; i++ )); do
      [[ ! -e $AX_ETC/writer-ready ]] || break
      sleep .02
    done
    [[ -e $AX_ETC/writer-ready ]] || exit 1
    sleep .1
    jq -e ".users == []" "$STATE" >/dev/null || exit 1
    return 1
  }
  if locked cmd_rules_change block two.example.com; then exit 1; fi
  writer=$(cat "$AX_ETC/writer-pid")
  for (( i=0; i<100; i++ )); do
    kill -0 "$writer" 2>/dev/null || break
    jq -e ".users[0].name == \"concurrent\"" "$STATE" >/dev/null && break
    sleep .02
  done
  jq -e ".users[0].name == \"concurrent\" and .server_policy.allow_domains == [\"example.com\"]" "$STATE" >/dev/null
'
# Telegram must recognize an explicitly disabled filter as false (jq `// true`
# incorrectly converts false into true). Verify the real callback dispatcher.
printf '%s\n' '{"mode":"direct","users":[],"server_policy":{"filters":{"ads":false}}}' >"$TMP/state.json"
bash -c '
  source ./autoxray
  tg_answer() { :; }
  tg_send() { :; }
  bot_rules_show() { :; }
  bot_rules_apply() { printf "%s\n" "$*" >>"$AX_ETC/actions"; }
  bot_callback 12345678 5 testcb r:ask:ads:on
  pending=$(bot_rule_pending_file 12345678) || exit 1
  [[ -s $pending ]] || { echo "ERROR: cannot re-enable disabled filter"; exit 1; }
  read -r nonce _ <"$pending"
  bot_callback 12345678 5 testcb "r:do:ads:$nonce"
  [[ $(cat "$AX_ETC/actions") == "12345678 set ads on" ]] || exit 1
  # Replaying a confirmation cannot execute an additional change.
  bot_callback 12345678 5 testcb "r:do:ads:$nonce"
  [[ $(wc -l <"$AX_ETC/actions") == 1 ]] || exit 1
  bot_callback 12345678 5 testcb r:ask:ads:on
  read -r nonce _ <"$pending"
  bot_callback 12345678 5 testcb "r:cancel:ads:$nonce"
  bot_callback 12345678 5 testcb "r:do:ads:$nonce"
  [[ ! -e $pending && $(wc -l <"$AX_ETC/actions") == 1 ]] || exit 1
'
# Access is checked again while holding the state lock in the maintenance worker.
bash -ec '
  source ./autoxray
  cp "$STATE" "$AX_ETC/unauthorized"
  if locked bot_rules_change 12345678 block example.org; then exit 1; fi
  cmp "$AX_ETC/unauthorized" "$STATE"
  printf "%s\n" test-token >"$BOT_TOKEN_FILE"
  st_edit ".bot = {enabled:true,admins:[12345678]}"
  tg_send() { :; }
  bot_rules_show() { :; }
  bot_rules_apply 12345678 block example.org
  [[ $BOT_RC == 0 ]] || { echo "$BOT_OUT"; exit 1; }
  jq -e ".server_policy.block_domains == [\"example.org\"]" "$STATE" >/dev/null
'
echo 'OK: server rules self-tests, Python-free render, shared lock, rollback and callbacks'
