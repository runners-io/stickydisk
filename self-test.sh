#!/usr/bin/env bash
# Self-test for runners-io/stickydisk (RUN-1745): stickydisk.sh against a fake
# manifest directory and fake blkid / mkfs.ext4 / mount / chown / curl on PATH.
# No network, no root, no real disk.
#
# WHAT THIS CAN AND CANNOT PROVE. It proves the decisions: what is validated
# before anything runs, who gets a mount, who gets a notice, when mkfs is allowed
# to run, and that a door that is down costs the learning and never the mount. It
# cannot prove that a real ext4 mounts on a real NBD device behind a real veil:
# that is the live walk on a metal node.
#
# THE RULE THIS TEST EXISTS TO HOLD: a disk is formatted only on a positive "no
# filesystem" from blkid -p (exit 2). Case "blkid cannot decide" holds it, and the
# mutation check at the end removes the guard from a copy of the script and
# requires that same case to go red, so the case is shown able to fail.

# The single-quoted $ below are deliberate: the metacharacter cases are literal
# text for the script under test.
# shellcheck disable=SC2016,SC2088
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap '[ -n "${SELFTEST_KEEP:-}" ] && echo "kept: $work" || rm -rf "$work"' EXIT

fails=0
checks=0
pass() { checks=$((checks + 1)); printf 'ok    %s\n' "$1"; }
fail() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL  %s\n' "$1"; }
eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (got '$2', want '$3')"; fi; }
has() { if grep -qF -- "$3" <<<"$2"; then pass "$1"; else fail "$1 (no '$3' in: $(head -c 300 <<<"$2"))"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then fail "$1 (found '$3')"; else pass "$1"; fi; }

command -v jq >/dev/null 2>&1 || { echo "self-test needs jq"; exit 2; }

# --- the fakes ------------------------------------------------------------------
bin="$work/bin"
mkdir -p "$bin"
for t in sudo blkid mkfs.ext4 mount chown curl blockdev; do
  case "$t" in
    sudo)
      printf '#!/usr/bin/env bash\nexec "$@"\n' >"$bin/$t" ;;
    blkid)
      # FAKE_BLKID_RC: 0 with TYPE=ext4 (formatted), 2 (nothing there), 1 (could not decide).
      cat >"$bin/$t" <<'EOF'
#!/usr/bin/env bash
echo "blkid $*" >>"$FAKE_LOG"
case "${FAKE_BLKID_RC:-0}" in
  0) echo "DEVNAME=$3"; echo "TYPE=ext4"; exit 0 ;;
  *) exit "${FAKE_BLKID_RC}" ;;
esac
EOF
      ;;
    mount)
      cat >"$bin/$t" <<'EOF'
#!/usr/bin/env bash
echo "mount $*" >>"$FAKE_LOG"
case "$*" in
  *noinit_itable*) [ -z "${FAKE_MOUNT_NOINIT_FAILS:-}" ] || exit 32 ;;
esac
[ -z "${FAKE_MOUNT_FAILS:-}" ] || exit 32
exit 0
EOF
      ;;
    curl)
      cat >"$bin/$t" <<'EOF'
#!/usr/bin/env bash
body=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    --data) body="$2"; shift 2 ;;
    -H|-X|-o|--connect-timeout|-m) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "curl $url $body" >>"$FAKE_LOG"
exit "${FAKE_CURL_RC:-0}"
EOF
      ;;
    *)
      printf '#!/usr/bin/env bash\necho "%s $*" >>"$FAKE_LOG"\nexit 0\n' "$t" >"$bin/$t" ;;
  esac
  chmod +x "$bin/$t"
done

digest_of() { printf '%s' "$1" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-32; }

# new_case <name>: a scratch tree with an /opt/ghwarp stand-in, a log, outputs.
new_case() {
  case_dir="$work/$1"
  rm -rf "$case_dir"
  mkdir -p "$case_dir/opt" "$case_dir/tmp" "$case_dir/home"
  : >"$case_dir/log"
  : >"$case_dir/out"
  printf 'https://cache-gra1.example.test:8443/ghwarp/joblog' >"$case_dir/opt/joblog-url"
}

# manifest <state> [refusal] [device]: one revealed/refused/unavailable entry for $KEY.
write_manifest() {
  local state="$1" refusal="${2:-}" device="${3:-/dev/vdc}" d
  d="$(digest_of "$KEY")"
  jq -cn --arg d "$d" --arg s "$state" --arg r "$refusal" --arg dev "$device" \
    '{disks: {($d): {n: 1, device: $dev, state: $s, refusal: $r, reason: ""}}}' >"$case_dir/opt/sticky-disks.json"
}

# run_action <script> : runs the script in the case; sets rc, text, outputs.
run_action() {
  local script="${1:-$here/stickydisk.sh}"
  text="$(
    env -i PATH="$bin:$PATH" HOME="$case_dir/home" \
      FAKE_LOG="$case_dir/log" \
      GITHUB_OUTPUT="$case_dir/out" RUNNER_TEMP="$case_dir/tmp" RUNNER_OS="${RUNNER_OS_T:-Linux}" \
      ${RUNNER_ENV_T:+RUNNER_ENVIRONMENT="$RUNNER_ENV_T"} \
      GHWARP_STICKY_MANIFEST="$case_dir/opt/sticky-disks.json" \
      GHWARP_JOBLOG_URL_FILE="$case_dir/opt/joblog-url" \
      ${FAKE_BLKID_RC_T:+FAKE_BLKID_RC="$FAKE_BLKID_RC_T"} \
      ${FAKE_MOUNT_NOINIT_FAILS_T:+FAKE_MOUNT_NOINIT_FAILS=1} \
      ${FAKE_MOUNT_FAILS_T:+FAKE_MOUNT_FAILS=1} \
      ${FAKE_CURL_RC_T:+FAKE_CURL_RC="$FAKE_CURL_RC_T"} \
      INPUT_KEY="$KEY" INPUT_PATH="$P" INPUT_FAIL_IF_UNAVAILABLE="${STRICT:-false}" \
      bash "$script" 2>&1
  )"
  rc=$?
  logtxt="$(cat "$case_dir/log")"
  outtxt="$(cat "$case_dir/out")"
}
reset_env() { unset RUNNER_OS_T RUNNER_ENV_T FAKE_BLKID_RC_T FAKE_MOUNT_NOINIT_FAILS_T FAKE_MOUNT_FAILS_T FAKE_CURL_RC_T STRICT; }

KEY='acme/app-npm'
reset_env

# --- 1. inputs, before anything else -----------------------------------------------
for bad in '' 'has space' 'semi;colon' 'new
line' 'pct%41' 'quote"x' '$(touch PWNED)' "$(printf 'k%.0s' $(seq 1 129))"; do
  new_case badkey; KEY="$bad"; P="$case_dir/mnt"; write_manifest revealed 2>/dev/null || true
  run_action
  eq "key '$(printf '%s' "$bad" | head -c 12 | tr '\n' '~')' is refused" "$rc" 1
  hasnt "  ...and nothing was run for it" "$logtxt" "mount"
done
KEY="$(printf 'k%.0s' $(seq 1 128))"
new_case okkey128; P="$case_dir/mnt"; run_action
eq "a 128 byte key is accepted" "$rc" 0
KEY='acme/app-npm'

for badp in '' 'relative/dir' '/a/../b' '/' ; do
  new_case badpath; P="$badp"; write_manifest revealed
  run_action
  eq "path '$badp' is refused" "$rc" 1
  hasnt "  ...and nothing was mounted for it" "$logtxt" "mount"
done
new_case tilde; write_manifest revealed; P='~/.npm'; run_action
eq "~/.npm is accepted" "$rc" 0
has "  ...and expanded against HOME" "$logtxt" "mount -o noinit_itable /dev/vdc $case_dir/home/.npm"

# --- 2. not a runners.io Linux runner ------------------------------------------------
new_case windows; P="$case_dir/mnt"; write_manifest revealed
RUNNER_OS_T=Windows run_action; reset_env
eq "Windows: exit 0" "$rc" 0
has "Windows: one notice" "$text" "Linux-only"
has "Windows: device-state not-ours" "$outtxt" "device-state=not-ours"
eq "Windows: nothing was run" "$logtxt" ""

new_case hosted; P="$case_dir/mnt"; write_manifest revealed
RUNNER_ENV_T=github-hosted run_action; reset_env
eq "GitHub-hosted: exit 0" "$rc" 0
has "GitHub-hosted: not-ours" "$outtxt" "device-state=not-ours"
eq "GitHub-hosted: nothing was run" "$logtxt" ""

new_case nodir; P="$case_dir/mnt"; rm -rf "$case_dir/opt"
run_action
eq "no /opt/ghwarp at all: exit 0" "$rc" 0
has "no /opt/ghwarp: not-ours" "$outtxt" "device-state=not-ours"

# --- 3. a key the host did not attach --------------------------------------------------
new_case absent; P="$case_dir/mnt"
run_action
eq "no manifest: exit 0" "$rc" 0
has "no manifest: says it will be attached from the next run" "$text" "will be attached from the next run of this job"
has "no manifest: not-attached-yet" "$outtxt" "device-state=not-attached-yet"
has "no manifest: mounted=false" "$outtxt" "mounted=false"
has "no manifest: wanted is posted, to the door beside the job log" "$logtxt" "curl https://cache-gra1.example.test:8443/ghwarp/stickydisk"
has "no manifest: the request is {verb, key}" "$logtxt" '{"verb":"wanted","key":"acme/app-npm"}'
hasnt "no manifest: no mount" "$logtxt" "mount"

new_case otherkey; P="$case_dir/mnt"; KEY=other write_manifest revealed; KEY='acme/app-npm'
run_action
has "a manifest holding another key: not-attached-yet" "$outtxt" "device-state=not-attached-yet"

new_case door_down; P="$case_dir/mnt"; FAKE_CURL_RC_T=7 run_action; reset_env
eq "door unreachable, key absent: still exit 0" "$rc" 0
has "door unreachable, key absent: still says so" "$outtxt" "device-state=not-attached-yet"

new_case no_door_file; P="$case_dir/mnt"; rm -f "$case_dir/opt/joblog-url"; run_action
eq "no joblog-url file: exit 0" "$rc" 0
hasnt "no joblog-url file: no request is made" "$logtxt" "curl"

new_case odd_door; P="$case_dir/mnt"; printf 'https://evil.example.test/elsewhere' >"$case_dir/opt/joblog-url"; run_action
hasnt "a joblog-url that does not end in /ghwarp/joblog is not posted to" "$logtxt" "curl"

# --- 4. a revealed disk ----------------------------------------------------------------
new_case fresh; P="$case_dir/mnt"; write_manifest revealed; FAKE_BLKID_RC_T=2 run_action; reset_env
eq "revealed, empty device: exit 0" "$rc" 0
eq "revealed, empty device: mkfs ran once" "$(grep -c '^mkfs.ext4' <<<"$logtxt")" 1
has "revealed, empty device: labelled ghwarp-sticky-1" "$logtxt" "mkfs.ext4 -q -F -L ghwarp-sticky-1 /dev/vdc"
has "revealed, empty device: mounted noinit_itable" "$logtxt" "mount -o noinit_itable /dev/vdc $P"
has "revealed, empty device: chowned to the runner" "$logtxt" "chown $(id -u):$(id -g) $P"
has "revealed, empty device: mounted=true" "$outtxt" "mounted=true"
has "revealed, empty device: device-state=mounted" "$outtxt" "device-state=mounted"
has "revealed, empty device: mounted is posted" "$logtxt" '{"verb":"mounted","key":"acme/app-npm"}'

new_case formatted; P="$case_dir/mnt"; write_manifest revealed; FAKE_BLKID_RC_T=0 run_action; reset_env
eq "revealed, formatted device: exit 0" "$rc" 0
hasnt "revealed, formatted device: NO mkfs" "$logtxt" "mkfs.ext4"
has "revealed, formatted device: mounted" "$outtxt" "mounted=true"

# THE RULE: blkid that cannot decide must not format. (Mutation-checked below.)
undecided_case() {
  new_case undecided; P="$case_dir/mnt"; write_manifest revealed
  FAKE_BLKID_RC_T=1 run_action "$1"; reset_env
}
undecided_case "$here/stickydisk.sh"
eq "blkid cannot decide: exit 0" "$rc" 0
hasnt "blkid cannot decide: NO mkfs" "$logtxt" "mkfs.ext4"
hasnt "blkid cannot decide: nothing is mounted" "$logtxt" "mount"
has "blkid cannot decide: unavailable" "$outtxt" "device-state=unavailable"
has "blkid cannot decide: says the disk was left as it is" "$text" "left exactly as it is"

new_case fallback; P="$case_dir/mnt"; write_manifest revealed
FAKE_MOUNT_NOINIT_FAILS_T=1 run_action; reset_env
has "noinit_itable refused: mounted without it" "$outtxt" "mounted=true"
has "noinit_itable refused: second mount has no -o" "$logtxt" "mount /dev/vdc $P"

new_case mountfail; P="$case_dir/mnt"; write_manifest revealed
FAKE_MOUNT_FAILS_T=1 run_action; reset_env
eq "mount fails: still exit 0" "$rc" 0
has "mount fails: unavailable" "$outtxt" "device-state=unavailable"
has "mount fails: mounted=false" "$outtxt" "mounted=false"

new_case door_down_mounts; P="$case_dir/mnt"; write_manifest revealed
FAKE_CURL_RC_T=7 run_action; reset_env
eq "door unreachable, disk revealed: exit 0" "$rc" 0
has "door unreachable, disk revealed: STILL mounts" "$outtxt" "mounted=true"
has "door unreachable, disk revealed: STILL says mounted" "$outtxt" "device-state=mounted"

new_case odd_device; P="$case_dir/mnt"; write_manifest revealed 'x' '/dev/vdc; rm -rf /'
run_action
has "a device name with a shell metacharacter is not used" "$outtxt" "device-state=unavailable"
hasnt "  ...and nothing was mounted" "$logtxt" "mount"

# --- 5. refused and unavailable ----------------------------------------------------------
new_case refused; P="$case_dir/mnt"; write_manifest refused
run_action
eq "refused: exit 0" "$rc" 0
has "refused: device-state=refused" "$outtxt" "device-state=refused"
has "refused: names a fork" "$text" "from a fork"
hasnt "refused: no mount, no mkfs" "$logtxt" "mount"

new_case refused_p; P="$case_dir/mnt"; write_manifest refused protected
run_action
has "refused, protected: names the protected setting" "$text" "protected"
eq "refused, protected: exit 0" "$rc" 0

new_case refused_strict; P="$case_dir/mnt"; write_manifest refused
STRICT=true run_action; reset_env
eq "refused with fail-if-unavailable: exit 1" "$rc" 1
has "refused with fail-if-unavailable: still device-state=refused" "$outtxt" "device-state=refused"

new_case unavail; P="$case_dir/mnt"; write_manifest unavailable
run_action
eq "unavailable: exit 0" "$rc" 0
has "unavailable: device-state=unavailable" "$outtxt" "device-state=unavailable"
has "unavailable: a warning, with the key" "$text" "::warning"

new_case unavail_strict; P="$case_dir/mnt"; write_manifest unavailable
STRICT=true run_action; reset_env
eq "unavailable with fail-if-unavailable: exit 1" "$rc" 1

# --- 6. six keys in one job ------------------------------------------------------------------
new_case six; P="$case_dir/mnt"
last=0
for i in 1 2 3 4 5 6; do
  KEY="key-$i"; P="$case_dir/mnt$i"; run_action; last=$rc
  if [ "$i" -le 5 ]; then eq "key $i of 6 is accepted" "$rc" 0; fi
done
eq "the sixth distinct key is refused" "$last" 1
has "the sixth key's message says why" "$text" "sixth"
KEY="key-1"; P="$case_dir/mnt1"; run_action
eq "a key already used is not a sixth" "$rc" 0
KEY='acme/app-npm'

# --- 7. the same key twice is one disk ---------------------------------------------------------
new_case twice; write_manifest revealed
P="$case_dir/one"; run_action
P="$case_dir/two"; run_action
eq "the same key at a second path: exit 0" "$rc" 0
has "the same key at a second path: bound, not mounted twice" "$logtxt" "mount --bind $case_dir/one $case_dir/two"
eq "the same key at a second path: the device is mounted once" "$(grep -c '^mount -o noinit_itable /dev/vdc' <<<"$logtxt")" 1

# --- 8. the check on the check -------------------------------------------------------------------
# Remove the positive-"no filesystem" guard from a COPY of the script, so that any
# blkid failure formats, and require the "blkid cannot decide" case to go red.
mut="$work/mutant"
mkdir -p "$mut"
sed 's/if \[ "\$probe_rc" = 2 \]; then/if [ "$probe_rc" != 0 ]; then/' "$here/stickydisk.sh" >"$mut/stickydisk.sh"
if cmp -s "$here/stickydisk.sh" "$mut/stickydisk.sh"; then
  fail "CONTROL: the mutation changed nothing, so the check below proves nothing"
else
  undecided_case "$mut/stickydisk.sh"
  if grep -qF "mkfs.ext4" <<<"$logtxt"; then
    pass "CONTROL: without the positive-no-filesystem guard, the unreadable-blkid case formats (the case can fail)"
  else
    fail "CONTROL: without the guard the unreadable-blkid case still did not format, so that case cannot see the guard"
  fi
fi

echo "$checks checks, $fails failed"
[ "$fails" -eq 0 ]
