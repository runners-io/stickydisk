#!/usr/bin/env bash
# runners-io/stickydisk (RUN-1745): mount the keyed disk this job was given, or
# say, truthfully, why it was not.
#
# WHAT IT READS. /opt/ghwarp/sticky-disks.json, which the guest's job-started
# hook (images/guest/ghwarp-bootstrap) writes, root-owned and mode 0644, before
# the job's first step: one entry per keyed disk the host attached to this VM,
#
#   {"disks": {"<digest>": {"n": 1, "device": "/dev/vdc",
#                           "state": "revealed|refused|unavailable",
#                           "refusal": "protected"|"", "reason": "..."}}}
#
# keyed by the digest of the key (the first 16 bytes of sha256(key), 32 lowercase
# hex characters), so the host never put a customer's string on a path and this
# script never learns a host device. A key with no entry is a key the host did
# not attach: it is asked for ("wanted") so the NEXT run of this job has it.
#
# WHAT IT NEVER DOES: fail a job for want of a disk (unless the workflow said
# fail-if-unavailable), format a disk it could not positively read, or reach the
# network for anything but one best-effort note to the node.
#
# THE ONE RULE ABOUT FORMATTING. mkfs only on a POSITIVE "no filesystem": blkid -p
# exits 2 when it finds nothing. Any other failure is a probe that could not
# decide, and it is answered by NOT mounting rather than by formatting what may be
# the customer's cache. The guest's own hook has the same rule for the same
# reason (a wiped superblock with stale bytes behind it must not be re-formatted
# blindly); self-test.sh holds this with a mutation check.
#
# THE DOOR. "wanted" and "mounted" are posted to /ghwarp/stickydisk on the host
# that already takes the job log (the guest reaches the node on its service port
# only). The node knows who is calling by the address of the tap the request came
# in on, never by anything sent here. A door that is unreachable costs the learning
# and the commit of this run's changes, never the mount.

set -uo pipefail

manifest="${GHWARP_STICKY_MANIFEST:-/opt/ghwarp/sticky-disks.json}"
joblog_url_file="${GHWARP_JOBLOG_URL_FILE:-$(dirname "$manifest")/joblog-url}"

out() { [ -z "${GITHUB_OUTPUT:-}" ] || printf '%s=%s\n' "$1" "$2" >>"$GITHUB_OUTPUT"; return 0; }
say() { printf 'runners.io stickydisk: %s\n' "$*"; }
notice() { printf '::notice title=runners.io stickydisk::%s\n' "$*"; }
warn() { printf '::warning title=runners.io stickydisk::%s\n' "$*"; }
die() { printf '::error title=runners.io stickydisk::%s\n' "$*"; out mounted false; out device-state unavailable; exit 1; }

key="${INPUT_KEY:-}"
path="${INPUT_PATH:-}"
strict="${INPUT_FAIL_IF_UNAVAILABLE:-false}"
case "$strict" in true|TRUE|True) strict=true ;; *) strict=false ;; esac

# --- the inputs, before anything else -----------------------------------------
# The key's charset is what keeps it safe in a workflow command and in the host's
# logs; the length is the host's. Nothing below runs on a key outside it.
key_re='^[A-Za-z0-9._:@/+=-]{1,128}$'
[[ "$key" =~ $key_re ]] || die "the key must be 1 to 128 characters of letters, digits and . _ : @ / + = -"

# shellcheck disable=SC2088  # the tilde is matched as text; it is the input's, not ours to expand
case "$path" in '~') path="$HOME" ;; '~/'*) path="$HOME/${path#\~/}" ;; esac
[ -n "$path" ] || die "path is required"
case "$path" in /*) ;; *) die "path must be absolute, or start with ~/" ;; esac
case "$path" in *[[:cntrl:]]*) die "path holds a control character" ;; esac
case "/$path/" in */../*) die "path may not contain .." ;; esac
[ "$path" != / ] || die "path may not be /"

# --- is this a runners.io Linux runner? ---------------------------------------
# One notice, nothing changed, success: a workflow that also runs on GitHub-hosted
# runners carries this step unconditionally.
notours() {
  notice "$1; this step does nothing here, and the job runs as it would without it."
  out mounted false
  out device-state not-ours
  exit 0
}
[ "${RUNNER_OS:-Linux}" = Linux ] || notours "this is a ${RUNNER_OS} runner, and keyed sticky disks are Linux-only"
[ "${RUNNER_ENVIRONMENT:-}" != github-hosted ] || notours "this is a GitHub-hosted runner, not a runners.io runner"
[ -d "$(dirname "$manifest")" ] || notours "this is not a runners.io runner"

if ! command -v jq >/dev/null 2>&1; then
  unavailable_reason="jq is not installed on this runner"
fi

digest_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-32
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -c1-32
  else
    return 1
  fi
}
digest="$(digest_of "$key")" || digest=""
case "$digest" in *[!0-9a-f]*) digest="" ;; esac
[ "${#digest}" = 32 ] || die "this runner has no sha256 tool, so the key cannot be looked up"

# --- at most five distinct keys in one job -------------------------------------
# A job's disks are attached before it starts and the host never attaches more
# than five, so a sixth is a workflow that cannot work: refused, loudly, before it
# touches anything. The same key twice is one disk (it is bound to the second path).
seen_dir=""
if [ -n "${RUNNER_TEMP:-}" ] && [ -d "${RUNNER_TEMP}" ]; then
  seen_dir="${RUNNER_TEMP%/}/runners-io-stickydisk-keys"
  mkdir -p "$seen_dir" 2>/dev/null || seen_dir=""
fi
if [ -n "$seen_dir" ] && [ ! -e "$seen_dir/$digest" ]; then
  n_seen="$(find "$seen_dir" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${n_seen:-0}" -ge 5 ]; then
    die "this job already uses 5 sticky-disk keys, the most one job can have; this would be a sixth"
  fi
  : >"$seen_dir/$digest" 2>/dev/null || true
fi

# --- the door ------------------------------------------------------------------
door=""
if [ -r "$joblog_url_file" ]; then
  u="$(head -c 512 "$joblog_url_file" 2>/dev/null | tr -d '\r\n')"
  case "$u" in
    http://*/ghwarp/joblog|https://*/ghwarp/joblog) door="${u%/ghwarp/joblog}/ghwarp/stickydisk" ;;
  esac
fi
post() { # post <verb>: best effort, quiet, never fails the step
  [ -n "$door" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local body
  body="$(jq -cn --arg verb "$1" --arg key "$key" '{verb:$verb,key:$key}')" || return 0
  curl -sS -o /dev/null --connect-timeout 3 -m 6 -X POST -H 'Content-Type: application/json' \
    --data "$body" "$door" >/dev/null 2>&1 || true
  return 0
}

# --- how a step ends -------------------------------------------------------------
# An unavailable or refused disk is the platform's graceful degradation: say why,
# run cold, succeed. fail-if-unavailable turns it into a failure.
finish_cold() { # finish_cold <state> <message>
  out mounted false
  out device-state "$1"
  if [ "$strict" = true ]; then
    printf '::error title=runners.io stickydisk::%s\n' "$2"
    exit 1
  fi
  if [ "$1" = refused ]; then notice "$2"; else warn "$2"; fi
  exit 0
}

if [ -n "${unavailable_reason:-}" ]; then
  finish_cold unavailable "the disk for key ${key} could not be used: ${unavailable_reason}. This job runs without it."
fi

# --- look the key up -------------------------------------------------------------
entry=""
if [ -f "$manifest" ]; then
  if ! entry="$(jq -c --arg d "$digest" '.disks[$d] // empty' "$manifest" 2>/dev/null)"; then
    finish_cold unavailable "the disk for key ${key} could not be used: the list of this job's disks is unreadable. This job runs without it."
  fi
fi

if [ -z "$entry" ]; then
  post wanted
  say "this key's disk will be attached from the next run of this job"
  notice "the sticky disk for key ${key} is not attached to this run: this key's disk will be attached from the next run of this job. This run continues without it."
  out mounted false
  out device-state not-attached-yet
  exit 0
fi

state="$(jq -r '.state // ""' <<<"$entry")"
device="$(jq -r '.device // ""' <<<"$entry")"
n="$(jq -r '.n // 0' <<<"$entry")"
refusal="$(jq -r '.refusal // ""' <<<"$entry")"
reason="$(jq -r '.reason // ""' <<<"$entry" | tr -cd 'A-Za-z0-9 ._:/=()-' | cut -c1-160)"

case "$state" in
  refused)
    case "$refusal" in
      protected)
        finish_cold refused "the sticky disk for key ${key} is withheld from this build: this repository's sticky disks are protected, so only trusted runs of its default branch may read them, and this build is not one of them. The job runs without it." ;;
      *)
        finish_cold refused "the sticky disk for key ${key} is withheld from this build: it is from a fork, runs a tag, or could not be identified, and runners.io never gives those builds a repository's sticky disk. The job runs without it." ;;
    esac
    ;;
  revealed) ;;
  *)
    finish_cold unavailable "the sticky disk for key ${key} could not be attached to this run${reason:+ (${reason})}. The job runs without it."
    ;;
esac

# --- a revealed disk: mount it -----------------------------------------------------
case "$n" in [1-5]) ;; *) finish_cold unavailable "the sticky disk for key ${key} has no usable slot number. The job runs without it." ;; esac
dev_re='^/dev/[A-Za-z0-9]+$'
[[ "$device" =~ $dev_re ]] || finish_cold unavailable "the sticky disk for key ${key} names no usable device. The job runs without it."

# The same key a second time: one disk, bound to the second path.
if [ -n "$seen_dir" ] && [ -s "$seen_dir/$digest" ]; then
  first="$(head -n 1 "$seen_dir/$digest")"
  if sudo mkdir -p "$path" && sudo mount --bind "$first" "$path"; then
    say "key ${key} is already mounted at ${first}; bound it at ${path} too"
    out mounted true
    out device-state mounted
    exit 0
  fi
  finish_cold unavailable "the sticky disk for key ${key} is mounted at ${first} and could not also be bound at ${path}. The job runs without the second path."
fi

# Drop what this guest cached while the disk was veiled before anything reads it.
sudo blockdev --flushbufs "$device" >/dev/null 2>&1 || true

probe="$(sudo blkid -p -o export "$device" 2>/dev/null)"
probe_rc=$?
ok=1
# GUARD:positive-no-filesystem -- the only place a disk is formatted.
if [ "$probe_rc" = 2 ]; then
  say "the disk for key ${key} is empty; making a filesystem on it for the first time"
  sudo mkfs.ext4 -q -F -L "ghwarp-sticky-${n}" "$device" || ok=0
elif [ "$probe_rc" != 0 ] || ! grep -q '^TYPE=' <<<"$probe"; then
  ok=0
fi
if [ "$ok" != 1 ]; then
  finish_cold unavailable "the sticky disk for key ${key} could not be checked or prepared, and was left exactly as it is. The job runs without it."
fi

# noinit_itable, and the disk mounted without it rather than not at all (RUN-1029).
mounted=0
if sudo mkdir -p "$path"; then
  if sudo mount -o noinit_itable "$device" "$path"; then
    mounted=1
  elif sudo mount "$device" "$path"; then
    mounted=1
  fi
fi
if [ "$mounted" != 1 ]; then
  finish_cold unavailable "the sticky disk for key ${key} could not be mounted at ${path}. The job runs without it."
fi

# The runner does not run as root, so an unwritable mount point is the same as no
# cache at all.
sudo chown "$(id -u):$(id -g)" "$path" || true
[ -z "$seen_dir" ] || printf '%s\n' "$path" >"$seen_dir/$digest" 2>/dev/null || true
say "the disk for key ${key} is mounted at ${path}"
post mounted
out mounted true
out device-state mounted
exit 0
