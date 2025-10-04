#!/bin/busybox sh
# ---------- TOOLS (toolbox partition) ----------
if [ -z "${TOOLS_MOUNT:-} " ]; then
  log "WARN: TOOLS_MOUNT not set; payload will be unavailable"
  unset TINYOS_MANIFEST TINYOS_DIR
elif [ -z "${TINYOS_TOKEN:-}" ]; then
  log "WARN: TINYOS_TOKEN not set; payload will be unavailable"
  unset TINYOS_MANIFEST TINYOS_DIR
else
  log "discovering TOOLS partition"
  export TOOLS_DEV=""
  TOOLS_CAND=
  [ -n "$VFAT_PARTS" ] || VFAT_PARTS="$("$BB" blkid | filter_hint 'TYPE=vfat')"

  # Seed from cmdline hint
  if [ -n "${_CMD_TOOLS_HINT:-}" ]; then
    TOOLS_CAND="${TOOLS_CAND}"$'\n'"$(filter_vfat "$_CMD_TOOLS_HINT")"
  fi

  # Seed from config hint
  if [ -n "${TOOLS_HINT:-}" ]; then
    TOOLS_CAND="${TOOLS_CAND}"$'\n'"$(filter_vfat "$TOOLS_HINT")"
  fi

  # Seed from label TOOLS
  TOOLS_CAND="${TOOLS_CAND}"$'\n'"$(filter_vfat 'LABEL~/TOOLS/')"

  # Finally, all vfat partitions
  TOOLS_CAND="${TOOLS_CAND}"$'\n'"${VFAT_PARTS}"

  # Resolve manifest basename
  MANIFEST_NAME="$(subst_template "$MANIFEST_TEMPLATE" "$TINYOS_TOKEN")"

  # Trial mount candidates
  "$BB" mkdir -p "$TOOLS_MOUNT" || true
  TRIAL_MOUNT="$(
    echo "$TOOLS_CAND" \
    | "$BB" awk -v FS=':' '(NF>1 && !seen[$1]) {seen[$1]=1;print $1}' \
    | while read -r CAND_DEV; do
        mount_fat_ro "$CAND_DEV" "$TOOLS_MOUNT"
        if [ -f "$TOOLS_MOUNT/$TINYOS_REL/$MANIFEST_NAME" ]; then
          # Found in expected location
          FOUND_MANIFEST="$TINYOS_REL/$MANIFEST_NAME"
        else
          # Search candidate partition for manifest
          FOUND_MANIFEST="$(
            ( cd "$TOOLS_MOUNT"
              "$BB" find . -type f -iname "$MANIFEST_NAME" -print
            ) || true \
            | "$BB" awk 'NR==1{print substr($0, 3)}'
          )"
        fi
        if [ -n "$FOUND_MANIFEST" ]; then
          printf "%s\n%s\n" "$CAND_DEV" "$FOUND_MANIFEST"
          break
        else
          "$BB" umount "$TOOLS_MOUNT" || true
        fi
      done
  )"
  if [ -n "$TRIAL_MOUNT" ]; then
    export TOOLS_DEV="$(echo "$TRIAL_MOUNT" | "$BB" sed -ne '1p')"
    export TINYOS_MANIFEST="$(echo "$TRIAL_MOUNT" | "$BB" sed -ne '2p')"
    export TINYOS_REL="$("$BB" dirname "$TINYOS_MANIFEST")"
    export TINYOS_DIR="${TOOLS_MOUNT}/${TINYOS_REL}"
  fi

  # Uniform logging regardless of discovery method
  if [ -n "${TOOLS_DEV:-}" ]; then
    log "TOOLS $TOOLS_DEV mounted on $TOOLS_MOUNT"
  else
    msg "WARN: TOOLS not found; payload will be unavailable"
    unset TINYOS_MANIFEST TINYOS_DIR
  fi
fi
