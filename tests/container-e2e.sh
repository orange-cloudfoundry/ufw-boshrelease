#!/bin/bash
# e2e: simulate the BOSH runtime layout on the stemcell container image
# (ghcr.io/cloudfoundry/ubuntu-jammy-stemcell:1.1474) and exercise the job.
# Run: docker run --rm -v <repo>:/r -v <rendered-e2e>:/e2e ghcr.io/cloudfoundry/ubuntu-jammy-stemcell:1.1474 bash /r/tests/container-e2e.sh
# iptables ships with the stemcell image; python3 needs no distutils/setuptools
# (packaging vendors its own isolated build env).
set -u
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL $1: $2"; }

# --- runtime layout ---
mkdir -p /var/vcap/packages /var/vcap/jobs /var/vcap/data /var/vcap/sys/run
mkdir -p /compile/ufw
cp /r/blobs/ufw/ufw.orig.tar.gz /compile/ufw/
cp /r/blobs/ufw/setuptools-79.0.1-py3-none-any.whl /compile/ufw/
if ! ( cd /compile && BOSH_COMPILE_TARGET=/compile BOSH_INSTALL_TARGET=/var/vcap/packages/ufw bash /r/packages/ufw/packaging ); then
  bad "packaging" "packages/ufw/packaging failed on stemcell python"
  echo "PASS=$PASS FAIL=$FAIL"; exit 1
fi
cp -r /e2e/rendered /var/vcap/jobs/ufw
J=/var/vcap/jobs/ufw
UFW="$J/bin/ufw"

setcfg() { python3 -c "
import json,sys
p='$J/config/ufw.json'
d=json.load(open(p))
exec(sys.argv[1])
json.dump(d,open(p,'w'),indent=2)
" "$1"; }

iptables_before=$(iptables-save | wc -l)

# 1. dry-run: exit 0, firewall untouched
out=$($J/bin/start 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q "DRY-RUN" && [ "$(iptables-save | wc -l)" = "$iptables_before" ] \
  && ok "dry-run leaves firewall untouched" || bad "dry-run" "rc=$rc out=$out lines=$(iptables-save|wc -l)"
[ -f /var/vcap/data/ufw/dry-run-rendered.json ] && ok "dry-run renders artifact" || bad "dry-run artifact" missing

# 2. enforce: enable + rules
setcfg "d['enforce']=True"
out=$($J/bin/start 2>&1); rc=$?
[ $rc -eq 0 ] || bad "enforce start" "rc=$rc out=$out"
$UFW status | head -1 | grep -q "^Status: active" && ok "firewall active" || bad "active" "$($UFW status | head -1)"
$UFW status verbose | grep -q "^Default: deny (incoming), allow (outgoing), deny (routed)" && ok "default posture" || bad "posture" "$($UFW status verbose | head -3)"
added=$($UFW show added)
[ "$(echo "$added" | grep -c '^ufw ')" = "3" ] && ok "3 tagged rules" || bad "rules" "$added"

# 3. monit_check healthy
$J/bin/monit_check; [ $? -eq 0 ] && ok "monit_check ok" || bad "monit_check" "unexpected failure"

# 4. config change adds rule (diff apply)
setcfg "d['commands'].append(\"allow from 172.17.0.0/16 to any port 8080 proto tcp comment 'paas-ufw/firewall-test added later'\")"
$J/bin/start >/dev/null 2>&1
[ "$($UFW show added | grep -c '^ufw ')" = "4" ] && ok "rule added via diff" || bad "add" "$($UFW show added)"
$J/bin/monit_check; [ $? -eq 0 ] && ok "monit_check ok after add" || bad "monit_check add" fail

# 4b. config change removes a rule -> release prunes it (delete+comment path)
setcfg "d['commands']=[c for c in d['commands'] if '8080' not in c]"
$J/bin/start >/dev/null 2>&1
[ "$($UFW show added | grep -c '^ufw ')" = "3" ] && ok "stale rule pruned by release" || bad "prune" "$($UFW show added)"
$J/bin/monit_check; [ $? -eq 0 ] && ok "monit_check ok after prune" || bad "monit_check prune" fail

# 5. drift: external delete of a managed rule -> check fails -> start repairs
setcfg "d['commands'].append(\"allow from 172.17.0.0/16 to any port 8080 proto tcp comment 'paas-ufw/firewall-test added later'\")"
$J/bin/start >/dev/null 2>&1
$UFW delete allow from 172.17.0.0/16 to any port 8080 proto tcp comment 'paas-ufw/firewall-test added later' >/dev/null 2>&1
$J/bin/monit_check; [ $? -ne 0 ] && ok "monit_check detects drift" || bad "drift detect" "not detected"
$J/bin/start >/dev/null 2>&1
$J/bin/monit_check; [ $? -eq 0 ] && ok "drift repaired" || bad "drift repair" "still failing"

# 6. foreign rules untouched
$UFW allow from 8.8.8.8/32 to any port 4444 proto tcp comment 'manual operator rule' >/dev/null 2>&1
$J/bin/start >/dev/null 2>&1
$UFW show added | grep -q "manual operator rule" && ok "foreign rule preserved" || bad "foreign" "it was removed!"
$J/bin/monit_check; [ $? -eq 0 ] && ok "monit_check ignores foreign rules" || bad "monit foreign" fail

# 7. stop keeps armed by default
$J/bin/stop >/dev/null 2>&1
$UFW status | head -1 | grep -q "^Status: active" && ok "stay_armed_on_stop keeps rules" || bad "stay armed" "firewall went inactive"

# 8. stay_armed_on_stop=false disarms
setcfg "d['stay_armed_on_stop']=False"
$J/bin/stop >/dev/null 2>&1
$UFW status | head -1 | grep -qv "^Status: active" && ok "disarm on stop works" || bad "disarm" "still active"

# 8b. ctl wrapper is executable and handles drain
$J/bin/ctl drain >/dev/null 2>&1 && ok "ctl drain exits 0" || bad "ctl drain" "failed"

# 8c. ctl start does NOT hang (regression: logger pipes blocked this for 90s)
mkdir -p /var/vcap/sys/log/ufw
out=$(timeout 30 $J/bin/ctl start 2>&1); rc=$?
[ $rc -eq 0 ] && ok "ctl start completes within 30s" || bad "ctl start hang/timeout" "rc=$rc out=$out"
[ -f /var/vcap/sys/log/ufw/ctl.log ] \
  && grep -q "job started at" /var/vcap/sys/log/ufw/ctl.log \
  && grep -q "job finished" /var/vcap/sys/log/ufw/ctl.log \
  && ok "ctl.log written (no logger pipe)" \
  || bad "ctl.log" "missing or incomplete: $(ls -la /var/vcap/sys/log/ufw/ 2>&1)"
[ -f /var/vcap/sys/run/ufw/ufw.pid ] && ok "ctl start wrote pidfile" || bad "ctl pidfile" "missing"
[ -f /var/vcap/sys/log/ufw/start.log ] && ok "start.log written by ctl wrapper" || bad "ctl start.log" "missing"

# 8d. daemon (tail -f /dev/null) actually running, monit can monitor it
sleep 0.5
daemon_pid=$(cat /var/vcap/sys/run/ufw/ufw.pid 2>/dev/null || echo "")
if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
  ok "ctl start left live daemon pid $daemon_pid (monit-compatible)"
else
  bad "ctl daemon" "pidfile pid '$daemon_pid' not alive"
fi

# 8e. ctl stop terminates daemon and cleans pidfile
timeout 30 $J/bin/ctl stop >/dev/null 2>&1
rc=$?
[ $rc -eq 0 ] && ok "ctl stop completes within 30s" || bad "ctl stop hang/timeout" "rc=$rc"
[ ! -f /var/vcap/sys/run/ufw/ufw.pid ] && ok "ctl stop removed pidfile" || bad "ctl stop pidfile" "still present"
if [ -n "$daemon_pid" ] && ! kill -0 "$daemon_pid" 2>/dev/null; then
  ok "ctl stop terminated daemon process"
else
  bad "ctl stop daemon" "pid $daemon_pid still alive"
fi
[ -f /var/vcap/sys/log/ufw/stop.log ] && ok "stop.log written" || bad "ctl stop.log" "missing"

# 9. ipv6: default false seeded, tracked through marker, flip re-toggles
setcfg "d['stay_armed_on_stop']=True"
$J/bin/start >/dev/null 2>&1   # re-arm after section 8's disarm
grep -q '^IPV6=no' /etc/default/ufw && ok "ipv6 default seeded no" || bad "ipv6 seed" "$(grep IPV6 /etc/default/ufw)"
[ "$(cat /var/vcap/data/ufw/applied.ipv6 2>/dev/null)" = "no" ] && ok "ipv6 marker no" || bad "ipv6 marker" "$(cat /var/vcap/data/ufw/applied.ipv6 2>/dev/null)"
sed -i 's@IPV6=no/@IPV6=yes/@' "$J/bin/pre-start"
setcfg "d['ipv6']=True"
out=$($J/bin/start 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q "IPV6 mode change" && grep -q '^IPV6=yes' /etc/default/ufw \
  && $UFW status | head -1 | grep -q "^Status: active" && [ "$(cat /var/vcap/data/ufw/applied.ipv6)" = "yes" ] \
  && ok "ipv6 flip re-toggled" || bad "ipv6 flip" "rc=$rc out=$out $(grep IPV6 /etc/default/ufw)"
sed -i 's@IPV6=yes/@IPV6=no/@' "$J/bin/pre-start"
setcfg "d['ipv6']=False"
$J/bin/start >/dev/null 2>&1
grep -q '^IPV6=no' /etc/default/ufw && [ "$(cat /var/vcap/data/ufw/applied.ipv6)" = "no" ] \
  && $UFW status | head -1 | grep -q "^Status: active" && ok "ipv6 back to no" || bad "ipv6 revert" "$(grep IPV6 /etc/default/ufw)"
$J/bin/monit_check; [ $? -eq 0 ] && ok "monit_check ok after ipv6 churn" || bad "monit_check ipv6 churn" fail

# 10. rendering was already validated in the erb harness
echo
echo "e2e result: PASS=$PASS FAIL=$FAIL"
[ $FAIL -eq 0 ]
