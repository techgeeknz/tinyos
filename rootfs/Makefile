.DELETE_ON_ERROR:
.SUFFIXES:
MAKEFLAGS += --warn-undefined-variables

# Use a strict shell if available
ifneq (,$(wildcard /bin/bash))
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
endif

# rootfs/Makefile — orchestrates staging → initramfs → EFI (payload placement)
ROOT               := $(abspath ..)
SCRIPTS            := $(ROOT)/scripts
CONFIG_DIR         := $(ROOT)/config
CONFIG_FILES_DIR   := $(CONFIG_DIR)/files
TINYOS_CONF        := $(CONFIG_DIR)/tinyos.conf
TINYOS_MK          := $(CONFIG_DIR)/.tinyos.mk

# Verbosity / parallel controls (passed explicitly from the top-level Makefile)
V           ?= 0
J           ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# Script entry points
STAGE_MODULES_SH  := $(SCRIPTS)/stage-modules.sh
COLLECT_FW_SH     := $(SCRIPTS)/collect-firmware.sh
STAGE_ASSETS_SH   := $(SCRIPTS)/stage-assets.sh
PACK_INITRAMFS_SH := $(SCRIPTS)/pack-initramfs.sh
STAGE_EFI_SH      := $(SCRIPTS)/stage-efi.sh
FW_SPARSE_PULL_SH := $(SCRIPTS)/firmware-sparse-pull.sh
MANIFEST_SH       := $(SCRIPTS)/manifest.sh

# Normalization helpers (mirror top-level)
strip_ws = $(strip $(1))
drop_trailing_slash = $(patsubst %/,%,$(1))
drop_leading_slash  = $(patsubst /%,%,$(1))

# Staging roots (may be overridden by top-level)
STAGE_ROOT      ?= $(ROOT)/staging
STAGE_META_DIR  ?= $(STAGE_ROOT)/.meta
INITRAMFS_DIR   ?= $(STAGE_ROOT)/initramfs
PAYLOAD_DIR     ?= $(STAGE_ROOT)/payload
STAGE_MOD_DIR   ?= $(STAGE_ROOT)/modules

# Centralized metadata (no marker/log files inside initramfs/ or payload/)
LISTS_DIR       := $(STAGE_META_DIR)/lists
GRAPH_DIR       := $(STAGE_META_DIR)/graph
META_STAMPS     := $(STAGE_META_DIR)/stamps
$(shell mkdir -p '$(LISTS_DIR)' '$(GRAPH_DIR)' '$(META_STAMPS)' >/dev/null 2>&1 || true)

# Token/conf stamp (authoritative build stamp managed by manifest.sh)
TOKEN_FILE      := $(META_STAMPS)/token.meta

# Outputs
INSTALL_NAME    ?= tinyos.efi
INITRAMFS_IMG   ?= $(STAGE_ROOT)/initramfs.img

# Bring in overrides from tinyos.conf (if present) *after* sane defaults,
# then normalize them below in Make (idempotent).
-include $(TINYOS_MK)
PAYLOAD_DIR     := $(call strip_ws,$(PAYLOAD_DIR))
INSTALL_NAME    := $(call strip_ws,$(INSTALL_NAME))
EFI_OUT         ?= $(PAYLOAD_DIR)/$(INSTALL_NAME)

# If invoked standalone, allow regenerating .tinyos.mk from tinyos.conf
$(TINYOS_MK): $(SCRIPTS)/tinyos-conf-to-mk.sh $(TINYOS_CONF)
	@echo "==> regen .tinyos.mk from $(TINYOS_CONF)"
	@"$(SCRIPTS)/tinyos-conf-to-mk.sh" \
	  --in  "$(TINYOS_CONF)" \
	  --out "$(TINYOS_MK).tmp" && \
	mv -f "$(TINYOS_MK).tmp" "$(TINYOS_MK)"

# Normalize (idempotent; tolerates empty) — strip whitespace first
TOOLS_MOUNT     := $(call strip_ws,$(TOOLS_MOUNT))
ESP_MOUNT       := $(call strip_ws,$(ESP_MOUNT))
TINYOS_REL      := $(call strip_ws,$(TINYOS_REL))
INSTALL_NAME    := $(call strip_ws,$(INSTALL_NAME))

TOOLS_MOUNT     := $(call drop_trailing_slash,$(TOOLS_MOUNT))
ESP_MOUNT       := $(call drop_trailing_slash,$(ESP_MOUNT))
TINYOS_REL      := $(call drop_trailing_slash,$(call drop_leading_slash,$(TINYOS_REL)))

# Build stamps (artifact-based DAG)
MOD_INIT_STAMP  := $(META_STAMPS)/modules.initramfs.stamp
MOD_PAY_STAMP   := $(META_STAMPS)/modules.payload.stamp
FW_INIT_STAMP   := $(META_STAMPS)/firmware.initramfs.summary
FW_PAY_STAMP    := $(META_STAMPS)/firmware.payload.summary

# Best-effort kernel version probes for status output (status only; do not gate rules)
INIT_KVER := $(notdir $(firstword $(wildcard $(INITRAMFS_DIR)/lib/modules/*)))
PAY_KVER  := $(notdir $(firstword $(wildcard $(PAYLOAD_DIR)/lib/modules/*)))

# Allow the top-level Makefile to choose the “staging complete” marker explicitly.
STAGE_STAMP     ?= $(META_STAMPS)/manifest.ready.stamp
ASSETS_STAMP    := $(META_STAMPS)/assets.ready.stamp

# Inputs
INIT            ?= $(CURDIR)/init.d
BUSYBOX_BIN     ?= $(ROOT)/busybox/busybox
README_INITRAMFS?= $(CURDIR)/README.initramfs
README_PAYLOAD  ?= $(CURDIR)/README.payload

# NOTE: helpers can auto-detect module paths, but we keep MODULES_DIR explicit
# here for clarity and reproducibility across environments.
MODULES_DIR     := $(call strip_ws,$(STAGE_MOD_DIR))/lib/modules

# Prefer local linux-firmware checkout if present, else host
FW_REPO_DIR     ?= $(ROOT)/linux-firmware
ifeq (,$(wildcard $(FW_REPO_DIR)/.git))
  FW_SRC        ?= /lib/firmware
else
  FW_SRC        ?= $(FW_REPO_DIR)
endif

# Make the git binary override visible to all sub-makes and scripts.
GIT               ?= git
export GIT

# Firmware policy knobs for initramfs collection
FW_INIT_MAX_FILE_BYTES  ?=
FW_INIT_MAX_TOTAL_BYTES ?=
FW_INIT_MODULES_LIST    ?=   # optional: file with relative module paths to limit scan

# Optional policy knobs for payload firmware (warn-only)
FW_PAY_MAX_FILE_BYTES   ?=
FW_PAY_MAX_TOTAL_BYTES  ?=
FW_PAY_MODULES_LIST     ?=

# Optional convenience flags for stage-assets.sh (passed only if inputs exist)
ASSETS_FLAGS :=
ASSETS_FLAGS += $(if $(wildcard $(CONFIG_FILES_DIR)),--files-dir "$(CONFIG_FILES_DIR)",)
ASSETS_FLAGS += $(if $(wildcard $(TINYOS_CONF)),--tinyos-conf "$(TINYOS_CONF)",)
ASSETS_FLAGS += $(if $(wildcard $(README_INITRAMFS)),--readme-initramfs "$(README_INITRAMFS)",)
ASSETS_FLAGS += $(if $(wildcard $(README_PAYLOAD)),--readme-payload "$(README_PAYLOAD)",)

BZIMAGE_STUB    ?= $(ROOT)/linux/arch/x86/boot/bzImage

.PHONY: help help-dag all clean mrproper \
  prereqs prereqs-busybox prereqs-linux \
  stage-modules stage-firmware stage-assets \
  initramfs stage-efi staging token manifest

help:
	@echo "Targets (artifact DAG):"
	@echo "  all, staging     : build $(EFI_OUT) via modules → firmware → assets → initramfs → efi"
	@echo "  stage-modules    : emit $(MOD_INIT_STAMP) and $(MOD_PAY_STAMP)"
	@echo "  stage-firmware   : emit $(FW_INIT_STAMP) and $(FW_PAY_STAMP) (parallel-friendly)"
	@echo "  stage-assets     : emit $(STAGE_STAMP)"
	@echo "  initramfs        : build $(INITRAMFS_IMG) from $(FW_INIT_STAMP) + $(STAGE_STAMP)"
	@echo "  stage-efi        : build $(EFI_OUT) (flat in $(PAYLOAD_DIR)) from $(INITRAMFS_IMG) + bzImage stub"
	@echo "Artifacts written by firmware collection also include maps:"
	@echo "  $(LISTS_DIR)/firmware.{initramfs,payload}.map and $(LISTS_DIR)/module-firmware.{initramfs,payload}.map"
	@echo
	@echo "Key inputs:"
	@echo "  MODULES_DIR   = $(MODULES_DIR)   # explicit for reproducibility (helpers can auto-detect)"
	@echo "  FW_SRC        = $(FW_SRC)"
	@echo "  BUSYBOX_BIN   = $(BUSYBOX_BIN)"
	@echo "  BZIMAGE_STUB  = $(BZIMAGE_STUB)"
	@echo
	@echo "Controls:"
	@echo "  V=$(V) (scripts see VERBOSE=$(V)); J=$(J)"
	@echo
	@echo "Notes:"
	@echo "  • stage-modules touches per-tree stamps so firmware collection can run in parallel."
	@echo "  • stage-assets copies only config/files/{initramfs,payload} and installs init+busybox last."
	@echo "  • initramfs packs with fakeroot; ownership handled there, not during staging."

help-dag:
	@echo "Resolved artifact paths:"
	@echo "  MOD_INIT_STAMP  = $(MOD_INIT_STAMP)"
	@echo "  MOD_PAY_STAMP   = $(MOD_PAY_STAMP)"
	@echo "  FW_INIT_STAMP   = $(FW_INIT_STAMP)"
	@echo "  FW_PAY_STAMP    = $(FW_PAY_STAMP)"
	@echo "  STAGE_STAMP     = $(STAGE_STAMP)"
	@echo "  INITRAMFS_IMG   = $(INITRAMFS_IMG)"
	@echo "  EFI_OUT         = $(EFI_OUT)"
	@echo "  TOKEN_FILE      = $(TOKEN_FILE)"
	@echo "  LISTS_DIR       = $(LISTS_DIR)"
	@echo "  GRAPH_DIR       = $(GRAPH_DIR)"
	@echo "  META_STAMPS     = $(META_STAMPS)"
	@echo
	@echo "Detected kernel versions:"
	@echo "  INIT_KVER = $(or $(INIT_KVER),(not staged))"
	@echo "  PAY_KVER  = $(or $(PAY_KVER),(not staged))"
	@echo
	@echo "Dependency edges (conceptual):"
	@echo "  stage-modules     → $(MOD_INIT_STAMP) + $(MOD_PAY_STAMP)"
	@echo "  $(MOD_INIT_STAMP) → $(FW_INIT_STAMP)"
	@echo "  $(MOD_PAY_STAMP)  → $(FW_PAY_STAMP)"
	@echo "  stage-assets      → $(STAGE_STAMP)"
	@echo "  $(FW_INIT_STAMP) + $(STAGE_STAMP) → $(INITRAMFS_IMG)"
	@echo "  $(INITRAMFS_IMG)  → $(EFI_OUT)"
	@echo
	@echo "Controls: V=$(V), J=$(J)"

# --- Common checks ---
req-script = @([ -x "$(1)" ] || { echo "ERROR: missing script: $(1)"; exit 1; })

# Guard: abort if token or tinyos.conf changed during the run
define ensure_stable_token
	@"$(MANIFEST_SH)" --tinyos-conf "$(TINYOS_CONF)" --verify-stamp "$(TOKEN_FILE)"
endef

# Preflight prerequisites
prereqs-busybox:
	@[ -x "$(BUSYBOX_BIN)" ] || { echo "ERROR: BusyBox not found/executable at $(BUSYBOX_BIN). Build BusyBox first."; exit 1; }
prereqs-linux:
	@[ -f "$(BZIMAGE_STUB)" ] || { echo "ERROR: kernel bzImage not found at $(BZIMAGE_STUB). Build Linux first."; exit 1; }
	@[ -d "$(MODULES_DIR)" ] || { echo "ERROR: MODULES_DIR not found at $(MODULES_DIR). Run modules_install or set MODULES_DIR explicitly."; exit 1; }
prereqs: prereqs-busybox prereqs-linux

# Token stamp (managed by manifest.sh)
$(TOKEN_FILE): $(MANIFEST_SH) $(TINYOS_CONF) | $(META_STAMPS)
	@echo "==> [rootfs] write token/conf stamp → $(TOKEN_FILE)"
	@VERBOSE=$(V) "$(MANIFEST_SH)" \
	  --tinyos-conf "$(TINYOS_CONF)" \
	  --generate-stamp "$@.tmp"
	@mv -f "$@.tmp" "$@"

token: $(TOKEN_FILE)

# Step 1: Stage modules (writes stamps; also fills $(LISTS_DIR), $(GRAPH_DIR))
$(MOD_INIT_STAMP) $(MOD_PAY_STAMP): | $(META_STAMPS) $(LISTS_DIR) $(GRAPH_DIR)
	$(call req-script,$(STAGE_MODULES_SH))
	@echo "==> [rootfs] stage modules → $(STAGE_ROOT)"
	@VERBOSE=$(V) "$(STAGE_MODULES_SH)" \
	    --modules-dir     "$(call strip_ws,$(STAGE_ROOT))/modules/lib/modules" \
	    --config-dir      "$(CONFIG_DIR)" \
	    --dest            "$(STAGE_ROOT)" \
	    --lists-dir       "$(LISTS_DIR)" \
	    --graph-dir       "$(GRAPH_DIR)" \
	    --stamp-initramfs "$(MOD_INIT_STAMP)" \
	    --stamp-payload   "$(MOD_PAY_STAMP)"

stage-modules: $(MOD_INIT_STAMP) $(MOD_PAY_STAMP)

# --- Step 2: firmware (policy-driven) ---
FW_INIT_MODULES_DIR  = $(INITRAMFS_DIR)/lib/modules
FW_PAY_MODULES_DIR   = $(PAYLOAD_DIR)/lib/modules

###############################################################################
# DRY firmware rule generator
# $(call fw_collect_rule, VAR, MODDIR, DESTDIR, STAMP, MODLIST, MAX_FILE, MAX_TOTAL, FAIL_ON_LIMIT)
#   VAR           : initramfs | payload   (used in filenames/messages)
#   MODDIR        : absolute modules dir (…/lib/modules)
#   DESTDIR       : absolute firmware destination dir (…/lib/firmware)
#   STAMP         : summary stamp to write
#   MODLIST       : optional modules list file
#   MAX_FILE      : optional max single fw bytes
#   MAX_TOTAL     : optional max total fw bytes
#   FAIL_ON_LIMIT : 1 to enforce policy failure (initramfs), empty for warn-only (payload)
define fw_collect_rule
$(4): $(COLLECT_FW_SH) $(if $(filter $(1),initramfs),$(MOD_INIT_STAMP),$(MOD_PAY_STAMP)) | $(META_STAMPS) $(dir $(3))
	$(call req-script,$(COLLECT_FW_SH))
	@echo "==> [rootfs] collect firmware → $(1) $(if $(8),(policy limits),(warn on limits))"
	@if compgen -G '$(2)/*/kernel/*' >/dev/null 2>&1; then \
	  VERBOSE=$(V) "$(COLLECT_FW_SH)" \
	    --modules-dir  "$(call strip_ws,$(2))" \
	    --firmware-src "$(FW_SRC)" \
	    --dest         "$(call strip_ws,$(3))" \
	    $(if $(5),--modules-list "$(strip $(5))") \
	    $(if $(6),--max-file-bytes "$(strip $(6))") \
	    $(if $(7),--max-total-bytes "$(strip $(7))") \
	    $(if $(8),--fail-on-file-limit,) \
	    --out-list     "$(LISTS_DIR)/firmware.$(1).list" \
	    --out-missing  "$(LISTS_DIR)/firmware.$(1).missing" \
	    --out-heavy    "$(LISTS_DIR)/firmware.$(1).heavy" \
	    --out-map-fw   "$(LISTS_DIR)/firmware.$(1).map" \
	    --out-map-mod  "$(LISTS_DIR)/module-firmware.$(1).map" \
	    --out-summary  "$(4)" $(if $(8),|| { echo "ERROR: $(1) firmware policy violated"; exit 1; },); \
	else \
	  echo "[rootfs] no $(1) modules; skipping firmware collection"; \
	  : >"$(LISTS_DIR)/firmware.$(1).list"; \
	  : >"$(LISTS_DIR)/firmware.$(1).missing"; \
	  : >"$(LISTS_DIR)/firmware.$(1).heavy"; \
	  : >"$(LISTS_DIR)/firmware.$(1).map"; \
	  : >"$(LISTS_DIR)/module-firmware.$(1).map"; \
	  : >"$(4)"; \
	fi
	@# Best-effort: if missing and local repo exists, try sparse-pull then retry ONCE
	@if [ -s "$(LISTS_DIR)/firmware.$(1).missing" ] && \
	  [ -d "$(FW_SRC)/.git" ] && \
	  [ ! -e "$(META_STAMPS)/firmware.$(1).retry" ]; then \
	  echo "==> [rootfs] attempting sparse firmware pull for $(1)…"; \
	  VERBOSE=$(V) "$(FW_SPARSE_PULL_SH)" \
	    --repo "$(FW_SRC)" \
	    --from-map "$(LISTS_DIR)/firmware.$(1).map" \
	    --from-missing "$(LISTS_DIR)/firmware.$(1).missing" \
	    $(if $(V),--verbose); \
	  : >"$(META_STAMPS)/firmware.$(1).retry"; \
	  rm -f "$(4)"; \
	  $(MAKE) -s "$(4)"; \
	fi
	@rm -f "$(META_STAMPS)/firmware.$(1).retry"
endef

# Instantiate the common firmware rules
# Artifact: initramfs firmware summary (fatal on policy violations)
$(eval $(call fw_collect_rule,initramfs,$(FW_INIT_MODULES_DIR),$(INITRAMFS_DIR)/lib/firmware,$(FW_INIT_STAMP),$(FW_INIT_MODULES_LIST),$(FW_INIT_MAX_FILE_BYTES),$(FW_INIT_MAX_TOTAL_BYTES),1))

# Artifact: payload firmware summary (warn-only policy)
$(eval $(call fw_collect_rule,payload,$(FW_PAY_MODULES_DIR),$(PAYLOAD_DIR)/lib/firmware,$(FW_PAY_STAMP),$(FW_PAY_MODULES_LIST),$(FW_PAY_MAX_FILE_BYTES),$(FW_PAY_MAX_TOTAL_BYTES),))

# Meta target: runs both collections (parallel-friendly)
stage-firmware: $(FW_INIT_STAMP) $(FW_PAY_STAMP)
	@echo "==> [rootfs] firmware staged: $(FW_INIT_STAMP) + $(FW_PAY_STAMP)"

# --- Step 3: assets (init, busybox, config/files) ---
# Make the assets stamp a real target so other rules can depend on it.
$(ASSETS_STAMP): $(STAGE_ASSETS_SH) prereqs-busybox $(TOKEN_FILE) $(TINYOS_CONF) | $(INITRAMFS_DIR) $(PAYLOAD_DIR) $(META_STAMPS)
	$(call req-script,$(STAGE_ASSETS_SH))
	$(call ensure_stable_token)
	@echo "==> [rootfs] stage assets → $(INITRAMFS_DIR) and $(PAYLOAD_DIR)"
	@VERBOSE=$(V) "$(STAGE_ASSETS_SH)" \
	    --stage-root  "$(call strip_ws,$(STAGE_ROOT))" \
	    --init        "$(call strip_ws,$(INIT))" \
	    --busybox     "$(call strip_ws,$(BUSYBOX_BIN))" \
	    $(ASSETS_FLAGS) && \
	mkdir -p "$(dir $(STAGE_STAMP))" && \
	touch "$(ASSETS_STAMP)"

stage-assets: $(ASSETS_STAMP)

# --- Step 4: initramfs image ---
initramfs: $(INITRAMFS_IMG)
$(INITRAMFS_IMG): $(FW_INIT_STAMP) $(ASSETS_STAMP) $(TOKEN_FILE) $(TINYOS_CONF) | $(INITRAMFS_DIR)
	$(call req-script,$(PACK_INITRAMFS_SH))
	$(call ensure_stable_token)
	@echo "==> [rootfs] pack initramfs → $(INITRAMFS_IMG)"
	@VERBOSE=$(V) "$(PACK_INITRAMFS_SH)" --root "$(call strip_ws,$(INITRAMFS_DIR))" --out "$(call strip_ws,$(INITRAMFS_IMG))"

# --- Step 5: EFI glue (bzImage + initramfs → tinyos.efi flat in payload/) ---
stage-efi: $(EFI_OUT)
$(EFI_OUT): $(INITRAMFS_IMG) prereqs-linux $(TOKEN_FILE) $(TINYOS_CONF) | $(PAYLOAD_DIR)
	$(call req-script,$(STAGE_EFI_SH))
	$(call ensure_stable_token)
	@[ -f "$(BZIMAGE_STUB)" ] || { echo "ERROR: missing bzImage EFI stub: $(BZIMAGE_STUB)"; exit 1; }
	@echo "==> [rootfs] stage EFI payload in $(PAYLOAD_DIR) (→ $(EFI_OUT))"
	@VERBOSE=$(V) "$(STAGE_EFI_SH)" \
	    --payload-root "$(call strip_ws,$(PAYLOAD_DIR))" \
	    --tinyos-efi   "$(BZIMAGE_STUB)" \
	    --initramfs    "$(call strip_ws,$(INITRAMFS_IMG))" \
	    --out-name     "$(call strip_ws,$(INSTALL_NAME))"

# --- Step 6: Generate manifest
manifest: $(STAGE_STAMP)
$(STAGE_STAMP): $(EFI_OUT) $(ASSETS_STAMP) $(INITRAMFS_IMG) $(TOKEN_FILE) $(TINYOS_CONF)
	$(call ensure_stable_token)
	@VERBOSE=$(V) "$(MANIFEST_SH)" \
	  --tinyos-conf "$(TINYOS_CONF)" \
	  --payload "$(PAYLOAD_DIR)" \
	  --remove-stale \
	  --generate && \
	VERBOSE=$(V) "$(MANIFEST_SH)" \
	  --tinyos-conf "$(TINYOS_CONF)" \
	  --generate-stamp "$@.tmp" && \
	mv -f "$@.tmp" "$@"

# Ensure data directories exist when needed (order-only prerequisites)
$(STAGE_ROOT) $(INITRAMFS_DIR) $(PAYLOAD_DIR) \
$(META_STAMPS) $(LISTS_DIR) $(GRAPH_DIR):
	@mkdir -p "$@"

# Aggregate target (full pipeline)
staging: manifest $(EFI_OUT) $(FW_PAY_STAMP) $(MOD_PAY_STAMP) $(STAGE_STAMP)
	@echo "==> [rootfs] staging DAG complete: $(EFI_OUT)"

all: staging

clean:
	@echo "==> [rootfs] clean $(STAGE_ROOT)/"
	@rm -f  "$(STAGE_STAMP)"
	@rm -rf "$(META_STAMPS)/firmware.*.retry"
	@rm -rf "$(STAGE_ROOT)"
	@rm -f  "$(TINYOS_MK)"
	@VERBOSE=$(V) "$(MANIFEST_SH)" \
	  --tinyos-conf "$(TINYOS_CONF)" \
	  --payload "$(PAYLOAD_DIR)" \
	  --reset

mrproper: clean

