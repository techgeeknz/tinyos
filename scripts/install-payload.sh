#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2312

# -----------------------------
# Paths & helpers
# -----------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if command -v realpath >/dev/null 2>&1; then
  SCRIPT_PATH="$(
    realpath -e -- "${BASH_SOURCE[0]}" 2>/dev/null || \
    printf '%s' "${BASH_SOURCE[0]}"
  )"
else
  SCRIPT_PATH="${BASH_SOURCE[0]}"
fi
IS_EFI_APP="${SCRIPT_DIR}/is-efi-app.sh"
[ -x "$IS_EFI_APP" ] || IS_EFI_APP=""

MANIFEST_TEMPLATE="tinyos-{}.manifest"
subst_template() { printf '%s' "${1%\{\}*}$2${1#*\{\}}"; }

trim_ws() { printf '%s' "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }
norm_slashes() { printf '%s' "$1" | sed -E 's:/+:/:g'; }
strip_leading_slash() { printf '%s' "$1" | sed -E 's:^/+::'; }
join_path() { printf '%s' "$(norm_slashes "$1/$2")"; }
log() { [ "${VERBOSE:-0}" -gt 0 ] && echo "[install-payload] $*" >&2 || true; }
die() { echo "[install-payload] ERROR: $*" >&2; exit 1; }

validate_relpath() {
  local s="$(strip_leading_slash "$1")" IFS=/; read -r -a parts <<<"$s" || true
  for p in "${parts[@]}"; do
    case "$p" in ''|'.'|'..'|*' '|
        *.) return 1;; esac
  done
  return 0
}

# -----------------------------
# Args / globals
# -----------------------------
STAGE_STAMP=""
PAYLOAD=""
TOOLS_MOUNT=""
TINYOS_REL=""
MANIFEST=""           # explicit manifest (accepted if outside payload)
BACKUPS=".backup"
VERBOSE=${VERBOSE:-0}
PREFLIGHT_ONLY=0
PREFLIGHT_OUT=""      # optional IPC: child → parent key=value file

# -----------------------------
# Manifest helpers
# -----------------------------
_manifest_candidates() {
  find "${PAYLOAD%/}" -mindepth 1 -maxdepth 1 -type f \
    -iname "$(subst_template "$MANIFEST_TEMPLATE" '*')" -printf '%p\n' | LC_ALL=C sort
}

_manifest_find() {
  # 1) Explicit external manifest — accept as-is
  # 2) Else payload must contain EXACTLY one tinyos-*.manifest
  local mf payload_abs manifest_abs
  payload_abs="$(cd -- "${PAYLOAD%/}" && pwd)"
  if [ -n "${MANIFEST:-}" ]; then
    [ -f "$MANIFEST" ] || die "manifest not found: $MANIFEST"
    manifest_abs="$(cd -- "$(dirname -- "$MANIFEST")" && pwd)"
    if [ "$manifest_abs" != "$payload_abs" ]; then printf '%s' "$MANIFEST"; return 0; fi
    printf '%s' "$MANIFEST"; return 0
  fi
  mapfile -t candidates < <(_manifest_candidates)
  case "${#candidates[@]}" in
    1) mf="${candidates[0]}" ;;
    *) die "payload must contain exactly one tinyos-*.manifest (found ${#candidates[@]}):
$(printf '  %s
' "${candidates[@]}")" ;;
  esac
  printf '%s' "$mf"
}

_manifest_parse_header() {
  awk 'BEGIN{FS="="} /^--/{exit} /^[[:space:]]*#/ {next} /^[A-Z][A-Z0-9_]*=/ {
    k=$1; sub(/^[^=]*=/,""); v=$0;
    if (k=="FILE_HASH"||k=="MANIFEST_VERSION"||k=="TINYOS_REL"||k=="INSTALL_NAME"||k=="TINYOS_TOKEN")
      printf "%s=%s
",k,v
  }' "$1"
}

# -----------------------------
# Preflight (unprivileged)
# -----------------------------
_preflight_unpriv() {
  (
    set -euo pipefail
    local _pf_out="${PREFLIGHT_OUT:-}"
    [ -d "$PAYLOAD" ] || die "payload dir missing: $PAYLOAD"

    # Ensure at least one EFI app present
    local has_efi=0
    if [ -x "$IS_EFI_APP" ]; then
      while IFS= read -r -d '' f; do
        "$IS_EFI_APP" "$f" 2>/dev/null && { has_efi=1; break; }
      done < <(find "$PAYLOAD" -maxdepth 1 -type f -print0)
    else
      set -- "$PAYLOAD"/*.efi "$PAYLOAD"/*.EFI; [ "$#" -gt 0 ] && has_efi=1 || true
    fi
    [ $has_efi -eq 1 ] || die "no EFI application found in $PAYLOAD"

    # Discover manifest
    local mf alg mrel iname token base expected
    mf="$(_manifest_find)"
    log "Using manifest: $mf"
    alg="$( _manifest_parse_header "$mf" | awk -F= '/^FILE_HASH=/{print $2}' )"
    mrel="$( _manifest_parse_header "$mf" | awk -F= '/^TINYOS_REL=/{print $2}' )"
    iname="$( _manifest_parse_header "$mf" | awk -F= '/^INSTALL_NAME=/{print $2}' )"
    token="$( _manifest_parse_header "$mf" | awk -F= '/^TINYOS_TOKEN=/{print $2}' )"
    [ -n "$alg" ]   || die "manifest missing FILE_HASH"
    [ -n "$token" ] || die "manifest missing TINYOS_TOKEN"

    # Filename must match token-derived template
    base="$(basename -- "$mf")"; expected="$(subst_template "$MANIFEST_TEMPLATE" "$token")"
    [ "$base" = "$expected" ] || \
      die "manifest name '$base' does not match token '$token' (expected '$expected')"

    # Inherit TINYOS_REL if not provided by caller
    if [ -z "${TINYOS_REL:-}" ] && [ -n "$mrel" ]; then TINYOS_REL="$mrel"; fi

    # Verify payload using helper (no tinyos.conf needed)
    if [ -x "$SCRIPT_DIR/manifest.sh" ]; then
      VERBOSE=$VERBOSE "$SCRIPT_DIR/manifest.sh" --payload "$PAYLOAD" --verify --manifest "$mf"
    else
      die "manifest.sh helper not found/executable at $SCRIPT_DIR/manifest.sh"
    fi

    # Optional IPC: emit discovered keys
    if [ -n "$_pf_out" ]; then
      { [ -n "$mrel" ]  && printf 'TINYOS_REL=%s\n'  "$mrel";
        [ -n "$iname" ] && printf 'INSTALL_NAME=%s\n' "$iname";
      } >"$_pf_out.tmp"
      mv -f "$_pf_out.tmp" "$_pf_out"
    fi
  )
}

# -----------------------------
# Drop-priv wrapper
# -----------------------------
_run_preflight_dropped(){
  local tu tg rc _out
  tu="${SUDO_UID:-}"; tg="${SUDO_GID:-}"
  if [ -z "$tu" ] || [ -z "$tg" ]; then
    if command -v stat >/dev/null 2>&1 && [ -d "$PAYLOAD" ]; then
      tu="$(stat -c %u "$PAYLOAD" 2>/dev/null || true)"
      tg="$(stat -c %g "$PAYLOAD" 2>/dev/null || true)"
    fi
  fi
  tu="${tu:-65534}"; tg="${tg:-65534}"

  _out="$(mktemp)" || die "mktemp failed"
  chown "$tu":"$tg" "$_out" 2>/dev/null || true
  chmod 600 "$_out" 2>/dev/null || true

  if command -v setpriv >/dev/null 2>&1; then
    log "preflight: dropping privileges via setpriv to uid=$tu gid=$tg"
    setpriv --reuid="$tu" --regid="$tg" --clear-groups --reset-env \
      "$SCRIPT_PATH" \
      --stage-stamp "$STAGE_STAMP" \
      --payload     "$PAYLOAD" \
      ${MANIFEST:+--manifest "$MANIFEST"} \
      ${TINYOS_REL:+--tinyos-rel "$TINYOS_REL"} \
      $( [ "$VERBOSE" -gt 0 ] && printf -- "--verbose" ) \
      --preflight-only --preflight-out "$_out"
    rc=$?
  elif command -v sudo >/dev/null 2>&1; then
    log "preflight: dropping privileges via sudo -u #$tu"
    sudo -n -u "#$tu" -- "$SCRIPT_PATH" \
      --stage-stamp "$STAGE_STAMP" \
      --payload     "$PAYLOAD" \
      ${MANIFEST:+--manifest "$MANIFEST"} \
      ${TINYOS_REL:+--tinyos-rel "$TINYOS_REL"} \
      $( [ "$VERBOSE" -gt 0 ] && printf -- "--verbose" ) \
      --preflight-only --preflight-out "$_out"
    rc=$?
  else
    echo "[install-payload] WARN: cannot drop privileges (missing setpriv/sudo); running preflight as root" >&2
    PREFLIGHT_OUT="$_out" _preflight_unpriv; rc=$?
  fi

  if [ -s "$_out" ]; then . "$_out" 2>/dev/null || true; fi
  rm -f -- "$_out" 2>/dev/null || true
  return $rc
}

# -----------------------------
# CLI
# -----------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --stage-stamp) STAGE_STAMP="$2"; shift 2 ;;
    --payload)     PAYLOAD="$2";     shift 2 ;;
    --tools-mount) TOOLS_MOUNT="$2"; shift 2 ;;
    --tinyos-rel)  TINYOS_REL="$2";  shift 2 ;;
    --manifest)    MANIFEST="$2";    shift 2 ;;
    --backups)     BACKUPS="$2";     shift 2 ;;
    --preflight-only) PREFLIGHT_ONLY=1; shift ;;
    --preflight-out)  PREFLIGHT_OUT="$2"; shift 2 ;;
    -v|--verbose)  VERBOSE=$((VERBOSE+1)); shift ;;
    *) die "Unknown arg: $1" ;;
  esac
done

[ -e "$STAGE_STAMP" ] || die "staging incomplete (need $STAGE_STAMP)"
[ -d "$PAYLOAD" ] || die "payload dir missing: $PAYLOAD"

# Preflight (unprivileged)
if [ "$PREFLIGHT_ONLY" -eq 1 ]; then _preflight_unpriv; exit $?; fi
if [ "$EUID" -eq 0 ]; then
  _run_preflight_dropped || exit $?
else
  _preflight_unpriv || exit $?
fi

# -----------------------------
# Installation (root)
# -----------------------------
[ "$EUID" -eq 0 ] || die "'install' requires root; run: sudo make install"

TOOLS_MOUNT="$(norm_slashes "$(trim_ws "${TOOLS_MOUNT:-}")")"
case "$TOOLS_MOUNT" in
  /*) :;;
  *) die "TOOLS_MOUNT must be absolute (got '$TOOLS_MOUNT')";;
esac
TINYOS_REL="$(norm_slashes "$(strip_leading_slash "$(trim_ws "${TINYOS_REL:-}")")")"
[ -n "$TINYOS_REL" ] ||
  die "TINYOS_REL must be non-empty (set in tinyos.conf or via --tinyos-rel)"
validate_relpath "$TINYOS_REL" || die "TINYOS_REL contains illegal VFAT components: '$TINYOS_REL'"

# Normalize TOOLS_MOUNT (drop trailing slashes) and build final base dir
TOOLS_MOUNT="${TOOLS_MOUNT%/}"
BD="$(join_path "$TOOLS_MOUNT" "$TINYOS_REL")"
log "TOOLS_MOUNT='$TOOLS_MOUNT'  TINYOS_REL='$TINYOS_REL'  →  BD='$BD'"

mountpoint -q "$TOOLS_MOUNT" || \
  die "TOOLS partition is not mounted at $TOOLS_MOUNT (mount -t vfat /dev/sdXN '$TOOLS_MOUNT')"
if ! findmnt -nr -t vfat,msdos,exfat,ntfs -T "$TOOLS_MOUNT" >/dev/null 2>&1; then
  echo "[install-payload] WARN: $TOOLS_MOUNT is not a FAT-like FS (proceeding)" >&2
fi
case "$BD" in "$TOOLS_MOUNT"|"$TOOLS_MOUNT/")
  die "Refusing to sync into mount root ('$BD'); set a subdirectory in TINYOS_REL." ;;
esac

install -d -m 0755 "$BD"; log "Install destination validated: $BD"

# Backup existing EFI apps
shopt -s nullglob
stamp="$(date +%Y%m%d%H%M%S)"; bdir="$BD/$BACKUPS/tinyos-$stamp"; mkdir -p "$bdir"
if [ -x "$IS_EFI_APP" ]; then
  while IFS= read -r -d '' g; do
    if "$IS_EFI_APP" "$g" 2>/dev/null; then
      rel="${g#"$BD"/}"
      install -D -m 0644 "$g" "$bdir/$rel" && rm -f -- "$g"
    fi
  done < <(find "$BD" -maxdepth 1 -type f -print0)
else
  while IFS= read -r -d '' g; do
    rel="${g#"$BD"/}"
    install -D -m 0644 "$g" "$bdir/$rel" && rm -f -- "$g"
  done < <(find "$BD" -iname '*.efi' -maxdepth 1 -type f -print0)
fi
find "$BD/$BACKUPS" -depth -type d -empty -delete >/dev/null 2>&1 || true

# Also back up and remove any old manifests at destination
while IFS= read -r -d '' mf_old; do
  rel="${mf_old#"$BD"/}"; install -D -m 0644 "$mf_old" "$bdir/$rel" && rm -f -- "$mf_old"
done < <(find "$BD" -maxdepth 1 -type f -iname 'tinyos-*.manifest' -print0)

# Sync payload → destination
FSTYPE="$(findmnt -nr -T "$BD" -o FSTYPE 2>/dev/null || echo)"
case "$FSTYPE" in
  vfat|msdos|exfat|ntfs)
    # VFAT-like: no ownership. Also relax timestamp granularity with --modify-window.
    RSYNC_OPTS=(-rlptD --no-owner --no-group --modify-window=2 --omit-dir-times)
    OWN_FIX=0
    ;;
  *)
    # POSIX: preserve and force owner:group during transfer.
    # (rsync --chown requires rsync >= 3.1 on both ends; here both ends are local)
    RSYNC_OPTS=(-rlptD --chown=0:0)
    OWN_FIX=1
    ;;
esac
rsync "${RSYNC_OPTS[@]}" "$PAYLOAD/" "$BD/"

if [ "${OWN_FIX:-0}" -eq 1 ]; then
  chown -hR 0:0 "$BD" 2>/dev/null || find "$BD" -xdev -exec chown 0:0 {} + 2>/dev/null || true
fi

# Copy manifest (authoritative)
mf_src="$(_manifest_find)"; install -D -m 0644 "$mf_src" "$BD/$(basename -- "$mf_src")"

sync
echo "Installed: $BD/ (payload verified against manifest and synced)"
