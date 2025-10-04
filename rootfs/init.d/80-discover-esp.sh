#!/bin/busybox sh
# ---------- ESP (real EFI System Partition) ----------
if [ -z "${ESP_MOUNT:-} " ]; then
  log "WARN: ESP_MOUNT not set; system ESP will be unavailable"
else
  log "discovering ESP partition"
  export ESP_DEV=""
  ESP_CAND=
  [ -n "$VFAT_PARTS" ] || VFAT_PARTS="$("$BB" blkid | filter_hint 'TYPE=vfat')"

  # Seed from cmdline hint
  if [ -n "${_CMD_ESP_HINT:-}" ]; then
    ESP_CAND="${ESP_CAND}"$'\n'"$(filter_vfat "$_CMD_ESP_HINT")"
  fi

  # Seed from config hint
  if [ -n "${ESP_HINT:-}" ]; then
    ESP_CAND="${ESP_CAND}"$'\n'"$(filter_vfat "$ESP_HINT")"
  fi

  # Mark explicitly seeded candidates
  ESP_MARK='---'
  ESP_CAND="$(printf "%s\n%s:%s\n" "$ESP_CAND" "$ESP_MARK" "$ESP_MARK")"

  # Seed from label ESP, EFI, or SYS
  ESP_CAND="${ESP_CAND}"$'\n'"$(filter_vfat 'LABEL~/ESP|EFI|SYS/')"

  # Finally, all vfat partitions
  ESP_CAND="${ESP_CAND}"$'\n'"${VFAT_PARTS}"

  # Trial mount candidates
  "$BB" mkdir -p "$ESP_MOUNT" || true
  TRIAL_MOUNT="$(
    echo "$ESP_CAND" \
    | "$BB" awk -v FS=':' -v sep="$ESP_MARK" '
        $1==sep             { print $1; next }
        (NF>1 && !seen[$1]) { print $1; seen[$1]=1 }
      ' \
    | {
        CAND_BOOST=100
        while read -r CAND_DEV; do
          # Find marker
          if [ "$CAND_DEV" == "$ESP_MARK" ]; then
            CAND_BOOST=$(($CAND_BOOST / 2))
            continue
          fi

          # Skip TOOLS partition
          if [ "$CAND_DEV" == "${TOOLS_DEV:-}" ]; then continue; fi

          mount_fat_ro "$CAND_DEV" "$ESP_MOUNT"
          if [ -d "$ESP_MOUNT/EFI" ]; then
            # Calculate score for potential candidate (number of
            # directories containing EFI files)
            ESP_SCORE=$(( $CAND_BOOST + 3 * $(
              cd "$ESP_MOUNT"
              { "$BB" find "EFI" -type f -iname '*.efi' -print || true; } \
              | "$BB" awk -v FS='/' '
                  !seen[$2] { seen[$2]=1 }
                  END       { print length(seen) }
                '
            ) ))

            printf '%s:%s\n' "$CAND_DEV" "$ESP_SCORE"
            [[ $CAND_BOOST -eq 0 ]] || CAND_BOOST=$(($CAND_BOOST - 1))
          fi
          "$BB" umount "$ESP_MOUNT" || true
        done
      } \
    | "$BB" awk -v FS=':' '
        BEGIN           { best_dev=""; best_score=-1; }
        $2 > best_score { best_dev=$1; best_score=$2; }
        END             { if (best_score > 0) print best_dev; }
      '
  )"
  if [ -n "$TRIAL_MOUNT" ]; then
    ESP_DEV="$TRIAL_MOUNT"
    mount_fat_ro "$ESP_DEV" "$ESP_MOUNT"
  fi

  # Uniform logging regardless of discovery method
  if [ -n "${ESP_DEV:-}" ]; then
    log "System ESP $ESP_DEV mounted on $ESP_MOUNT"
  else
    msg "WARN: System ESP not found"
  fi
fi
