#!/bin/busybox sh
# Apply HP_TOOLS sysfs.d after it’s available
if [ -d "$TINYOS_DIR/sysfs.d" ]; then
  apply_sysfs_dir "$TINYOS_DIR/sysfs.d"
fi
