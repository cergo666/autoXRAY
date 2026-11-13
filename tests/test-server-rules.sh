#!/usr/bin/env bash
# shellcheck disable=SC2016 # Single-quoted bash -c snippets intentionally expand in child shell.
# Standalone, unprivileged regression suite: bash tests/test-server-rules.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export AX_DRY=1
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
raw = json.dumps({"routing":{"rules":rules},"outbounds":[{"tag":x} for x in ('direct','block','block-bt')]})

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
        s={**base,"server_policy":{"allow_domains":["2ip.io"],"block_domains":["example.com"]}}
        out=json.loads(m.transformed(raw,s))['routing']['rules']
        self.assertEqual(out[:5],rules[:5]); self.assertEqual(out[5]['ruleTag'],'ax-policy-allow')
        self.assertEqual(out[6]['ruleTag'],'ax-policy-block')
        self.assertEqual(out[7:],rules[5:])
    def test_idempotent_no_duplicates(self):
        s={**base,"server_policy":{"allow_domains":["a.example"]}}
        first=m.transformed(raw,s)
        self.assertEqual(first,m.transformed(first,s))
        self.assertEqual(first.count('ax-policy-allow'),1)
    def test_unsafe_upstream_rule_order_rejected(self):
        s={**base,"server_policy":{"allow_domains":["a.example"]}}
        reordered=[rules[5], *rules[:5], *rules[6:]]
        with self.assertRaises(m.PolicyError):
            m.transformed(json.dumps({"routing":{"rules":reordered},"outbounds":[{"tag":x} for x in ('direct','block','block-bt')]}),s)
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
# Verify the real jq-based config builder can be piped through the transformer
# without changing an unconfigured direct installation's generated bytes.
RENDER_TMP=$(mktemp -d)
printf '%s\n' '{"mode":"direct","domain":"example.com","users":[],"socks":{"user":"u","pass":"p"},"paths":{"xhttp":"abc"},"warp":{"registered":false}}' >"$RENDER_TMP/state.json"
printf '%s\n' '{}' >"$RENDER_TMP/traffic.json"
printf '%s\n' '[]' >"$RENDER_TMP/bans.json"
AX_ETC="$RENDER_TMP" AX_TEMPLATES="$(pwd)/templates" AX_UNIT_TEST=1 AX_DRY=1 bash -c '
  source ./autoxray
  render_xray_json >"$AX_ETC/raw.json"
  /usr/bin/python3 "$TPL_DIR/server_rules.py" "$STATE" transform <"$AX_ETC/raw.json" >"$AX_ETC/piped.json"
  cmp -s "$AX_ETC/raw.json" "$AX_ETC/piped.json" || exit 1
  jq -e ".routing.rules | length > 0" "$AX_ETC/piped.json" >/dev/null
' || { rm -rf "$RENDER_TMP"; exit 1; }
rm -rf "$RENDER_TMP"

# Test actual Bash glue: failure restores state and retries old Xray while lock held.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf '%s\n' '{"mode":"direct","users":[]}' >"$TMP/state.json"
chmod 600 "$TMP/state.json"
export AX_ETC="$TMP" AX_TEMPLATES="$PWD/templates" AX_UNIT_TEST=1
# `source` in its own shell so mocking apply_xray can't leak into caller.
bash -c '
  source ./autoxray
  calls=0
  backup_inode=""
  apply_xray() {
    calls=$((calls+1))
    if [[ $calls == 1 ]]; then
      backup_path=$(find "$AX_ETC" -maxdepth 1 -name ".rules-before.*" -print -quit)
      [[ -n $backup_path ]] || exit 1
      backup_inode=$(stat -c %i "$backup_path")
    fi
    return 1
  }
  if locked cmd_rules_change block example.com; then echo "ERROR: failed Xray accepted"; exit 1; fi
  [[ $calls == 2 ]] || { echo "ERROR: rollback retry missing"; exit 1; }
  [[ $(jq -r ".server_policy // empty" "$STATE") == "" ]] || { echo "ERROR: state not restored"; exit 1; }
  [[ $(stat -c %a "$STATE") == 600 ]] || exit 1
  [[ $(stat -c %i "$STATE") == "$backup_inode" ]] || { echo "ERROR: rollback was not atomic"; exit 1; }
  [[ -z $(find "$AX_ETC" -maxdepth 1 -name ".rules-before.*" -print -quit) ]] || exit 1
'
# Confirm valid edits and unchanged edits don't cause extra renders.
bash -c '
  source ./autoxray
  calls=0
  apply_xray() { calls=$((calls+1)); return 0; }
  locked cmd_rules_change allow example.com
  [[ $calls == 1 ]] || exit 1
  locked cmd_rules_change allow example.com
  [[ $calls == 1 ]] || exit 1
'
# Confirm success after a failed first apply restores the previous policy.
printf '%s\n' '{"mode":"direct","users":[]}' >"$TMP/state.json"
bash -c '
  source ./autoxray
  calls=0
  apply_xray() { calls=$((calls+1)); [[ $calls == 2 ]]; }
  if locked cmd_rules_change block example.com; then exit 1; fi
  [[ $calls == 2 ]] || exit 1
  [[ $(jq -r ".server_policy // empty" "$STATE") == "" ]] || exit 1
'
# Telegram confirmation: bound to chat, filter, nonce and five-minute lifetime.
export AX_RULE_CONFIRM_DIR="$TMP/confirm"
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
# The lock must remain held while Xray is being applied (not released for nested render).
bash -c '
  source ./autoxray
  apply_xray() { flock -n "$LOCK" -c true && { echo "ERROR: lock released early"; return 1; }; return 0; }
  locked cmd_rules_change block two.example.com
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
'
echo 'OK: server rules self-tests + atomic rollback + shared lock + disabled-filter callbacks'
