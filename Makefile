# TinyOS Makefile — Glorious Edition™ (restored & refined)
# - BusyBox + initramfs + EFI-stub kernel
# - devtmpfs-only (no mdev) initramfs
# - rEFInd passes cmdline (we do NOT embed one by default)
# - All install-time assets live under HP_TOOLS/EFI/tinyos/
#
# Layout:
#   ./                  (this Makefile)
#   ./linux/            (kernel tree)
#   ./linux-headers/    (generated UAPI headers)
#   ./busybox/          (BusyBox tree)
#   ./rootfs/           (initramfs and staging tree; has its own Makefile)
#   ./staging/          (build output: initramfs, EFI images, etc)
#   ./config/           (configuration files; all init variables and selected)
#                       (Makefile variables overridable via ./config/tinyos.conf)
#   ./config/files/     (optional overlay; copied verbatim into stage/install)
#   ./scripts/          (all helper scripts live here)

# ===================== Paths =====================
ROOT               := $(CURDIR)
CONFIG_DIR         := $(ROOT)/config
CONFIG_FILES_DIR   := $(CONFIG_DIR)/files
SCRIPTS_DIR        := $(ROOT)/scripts
LINUX_DIR          := $(ROOT)/linux
BUSYBOX_DIR        := $(ROOT)/busybox
ROOTFS_DIR         := $(ROOT)/rootfs
INIT               := $(ROOTFS_DIR)/init

PACKER             := $(SCRIPTS_DIR)/pack-initramfs.sh
PREPARE_KERNEL_SH  := $(SCRIPTS_DIR)/prepare-kernel.sh
PREPARE_BUSYBOX_SH := $(SCRIPTS_DIR)/prepare-busybox.sh
UPDATE_TINYOS_CONF := $(SCRIPTS_DIR)/update-tinyos-conf.sh
STAGE_EFI_SH       := $(SCRIPTS_DIR)/stage-efi.sh
STAGE_MODULES_SH   := $(SCRIPTS_DIR)/stage-modules.sh
COLLECT_FW_SH      := $(SCRIPTS_DIR)/collect-firmware.sh
DEPMOD_SAFE_SH     := $(SCRIPTS_DIR)/depmod-safe.sh
INSTALL_PAYLOAD_SH := $(SCRIPTS_DIR)/install-payload.sh

BZIMAGE            := $(LINUX_DIR)/arch/x86/boot/bzImage
KERNEL_CFGFILE     := $(LINUX_DIR)/.config
FW_REPO_DIR        := $(ROOT)/linux-firmware
BUSYBOX_BIN        := $(BUSYBOX_DIR)/busybox
BUSYBOX_CFGFILE    := $(BUSYBOX_DIR)/.config
STAGE_ROOT         := $(ROOT)/staging
PAYLOAD_DIR        := $(STAGE_ROOT)/payload
INITRAMFS          := $(STAGE_ROOT)/initramfs.img
STAGE_META_DIR     := $(STAGE_ROOT)/.meta
STAGE_STAMP        := $(STAGE_META_DIR)/.assets.stamp

# These are internal build paths; do not leak to sub-makes implicitly.
unexport STAGE_ROOT STAGE_META_DIR PAYLOAD_DIR STAGE_STAMP

HEADERS_DIR       := $(ROOT)/linux-headers
LINUX_HEAD_INC    := $(HEADERS_DIR)/include
HDR_STAMP         := $(HEADERS_DIR)/.stamp-headers

# Where we stage kernel modules (via modules_install) — keep inside project staging
STAGE_MOD_DIR     := $(STAGE_ROOT)/modules

# ===================== Config (tinyos.conf) =====================
# Source of truth (human-edited):
TINYOS_CONF ?= $(CONFIG_DIR)/tinyos.conf
# Machine-generated, whitespace-stripped copy for make to include:
TINYOS_MK   ?= $(CONFIG_DIR)/.tinyos.mk

# Rule to (re)generate .tinyos.mk from tinyos.conf
$(TINYOS_MK): $(SCRIPTS_DIR)/tinyos-conf-to-mk.sh $(TINYOS_CONF)
	@echo "==> regen .tinyos.mk from $(TINYOS_CONF)"
	@"$(SCRIPTS_DIR)/tinyos-conf-to-mk.sh" \
	  --in  "$(TINYOS_CONF)" \
	  --out "$(TINYOS_MK).tmp" && \
	mv -f "$(TINYOS_MK).tmp" "$(TINYOS_MK)"

# ============ Normalization helpers ============
# Trim whitespace aggressively, then (for paths) drop trailing slash.
strip_ws = $(strip $(1))
drop_trailing_slash = $(patsubst %/,%,$(1))
drop_leading_slash  = $(patsubst /%,%,$(1))

# ===================== Knobs =====================
EMBED_CMDLINE     ?= 0
CMDLINE           ?= console=tty0 acpi_backlight=native noresume
CMDLINE_EXTRA     ?=
CMDLINE_FILE      ?=

TOOLS_MOUNT       ?= /boot/hp_tools
TINYOS_REL        ?= EFI/tinyos
INSTALL_NAME      ?= tinyos.efi

# Install behavior knobs (write manifest and backup existing EFI applications)
# Housekeeping names inside destination directory
INSTALL_MANIFEST  ?= .tinyos.manifest
INSTALL_BACKUPS   ?= .backup

# Include the generated mk (make will auto-rebuild it if missing/outdated).
# This keeps values normalized at parse time and avoids trailing whitespace bugs.
-include $(TINYOS_MK)

# ===================== Post-config normalization =====================
# Strip whitespace first, then path-shape tweaks (idempotent).
TOOLS_MOUNT       := $(call strip_ws,$(TOOLS_MOUNT))
TINYOS_REL        := $(call strip_ws,$(TINYOS_REL))
ESP_MOUNT         := $(call strip_ws,$(ESP_MOUNT))
INSTALL_NAME      := $(call strip_ws,$(INSTALL_NAME))

# BOOTDIR may be overridden on the command line; otherwise derive from tinyos.conf
BOOTDIR           ?= $(TOOLS_MOUNT)/$(TINYOS_REL)
# Normalize BOOTDIR (strip whitespace then trailing '/')
BOOTDIR           := $(call drop_trailing_slash,$(call strip_ws,$(BOOTDIR)))

EFI_IMAGE          = $(PAYLOAD_DIR)/$(INSTALL_NAME)

# Fix path forms
TOOLS_MOUNT       := $(call drop_trailing_slash,$(TOOLS_MOUNT))
TINYOS_REL        := $(call drop_leading_slash,$(TINYOS_REL))
TINYOS_REL        := $(call drop_trailing_slash,$(TINYOS_REL))
ESP_MOUNT         := $(call drop_trailing_slash,$(ESP_MOUNT))

J                 ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
LIST_ARCHIVE      ?= 0

# Firmware policy knobs
# FIRMWARE_INCLUDE: explicit list of blobs allowed into staging.
# FIRMWARE_EXCLUDE: explicit list of blobs to block even if included.
# Together these provide fine-grained control over staged firmware.
HEAVY_BYTES       ?= 1048576   # 1 MiB per-file warning threshold
RAMFS_MAX_BYTES   ?= 0         # forbid firmware in initramfs by default

# Config fragment knobs (support conf.d directories)
KERNEL_FRAG_DIR   ?= $(CONFIG_DIR)/kernel.conf.d
BUSYBOX_FRAG_DIR  ?= $(CONFIG_DIR)/busybox.conf.d
# Auto-discover fragments (allow *.fragment or *.frag), sorted for deterministic merge order
KERNEL_FRAGMENTS  ?= $(sort $(wildcard $(KERNEL_FRAG_DIR)/*.fragment) $(wildcard $(KERNEL_FRAG_DIR)/*.frag))
BUSYBOX_FRAGMENTS ?= $(sort $(wildcard $(BUSYBOX_FRAG_DIR)/*.fragment) $(wildcard $(BUSYBOX_FRAG_DIR)/*.frag))
# Turn lists into repeated --fragment args
KFRAG_ARGS        := $(foreach f,$(KERNEL_FRAGMENTS),--fragment "$(abspath $(f))")
BFRAG_ARGS        := $(foreach f,$(BUSYBOX_FRAGMENTS),--fragment "$(abspath $(f))")

# Upstreams for first-time shallow clones
LINUX_REMOTE      ?= https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git
LINUX_FW_REMOTE   ?= https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware
BUSYBOX_REMOTE    ?= https://git.busybox.net/busybox

# Make the git binary override visible to all sub-makes and scripts.
GIT               ?= git
export GIT

# BusyBox toolchain: prefer musl, fall back to BusyBox defaults if not found.
# Users may override by setting BUSYBOX_CC explicitly (e.g., BUSYBOX_CC=x86_64-linux-musl-gcc).
MUSL_CC_CANDIDATES := $(strip \
  $(if $(MUSL_CC),$(MUSL_CC)) \
  x86_64-linux-musl-gcc \
  musl-gcc \
  x86_64-linux-musl-clang \
  clang)
BUSYBOX_CC ?= $(firstword $(foreach c,$(MUSL_CC_CANDIDATES),$(if $(shell command -v $(c) 2>/dev/null),$(c))))
# Use UAPI headers we just installed (headers_install)
BB_CC_INCLUDES    := $(if $(LINUX_HEAD_INC),-isystem $(LINUX_HEAD_INC))

# Safer defaults: stop on errors and propagate pipe failures when bash is available
ifneq (,$(wildcard /bin/bash))
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
endif

.DELETE_ON_ERROR:

# ===================== Phony =====================
.PHONY: all help help-dag \
        linux linux-config linux-headers linux-modules-install \
        busybox-config busybox bootstrap \
        staging-prep staging write-tinyos-conf install \
        linux-pull busybox-pull pull firmware-init firmware-pull \
        list clean mrproper distclean print-%

# ===================== Top-level =====================
all: $(BZIMAGE) linux-headers $(BUSYBOX_BIN) staging

help:
	@echo "Targets:"
	@echo "  linux             - build kernel bzImage via kernel's own Makefile"
	@echo "  linux-config      - generate tuned .config via prepare-kernel.sh"
	@echo "                      (fragments from $(KERNEL_FRAG_DIR)/)"
	@echo "  linux-headers     - install kernel UAPI headers into ./linux-headers/include"
	@echo "  linux-modules-install - build & install kernel modules into rootfs/staging/modules/"
	@echo "  busybox-config    - merge BusyBox fragments via prepare-busybox.sh then oldconfig"
	@echo "                      (fragments from $(BUSYBOX_FRAG_DIR)/)"
	@echo "  busybox           - meta target; builds $(BUSYBOX_BIN)"
	@echo "                      (defaults to musl toolchain if available)"
	@echo "  staging-prep      - prepare to run staging, but do not actually run it"
	@echo "  staging           - run rootfs DAG → $(INITRAMFS) and $(EFI_IMAGE); writes/merges tinyos.conf"
	@echo "  write-tinyos-conf - merge updated boot path into tinyos.conf"
	@echo "  install           - **read-only**; uses tinyos.conf BOOTDIR, verifies EFI by content, then rsync"
	@echo "                      (backs up existing EFI apps; writes $(INSTALL_MANIFEST) of desired contents)"
	@echo "  linux-pull        - shallow clone/pull kernel tree (auto-clone if missing)"
	@echo "  busybox-pull      - shallow clone/pull busybox tree (auto-clone if missing)"
	@echo "  pull              - update kernel + busybox"
	@echo "  firmware-init     - prepare sparse (cone) linux-firmware repo (no fetch)"
	@echo "  firmware-full     - full (non-sparse) clone or update of linux-firmware"
	@echo "  firmware-pull     - update existing linux-firmware repo (sparse or full); suggest init if missing"
	@echo "  bootstrap         - update kernel + busybox and then build all"
	@echo "  help-dag          - show resolved artifacts + quick DAG view/status"
	@echo "  list              - list key knobs/paths"
	@echo "  clean             - remove rootfs staging artifacts"
	@echo "  mrproper          - clean + invoke 'make mrproper' in linux/, busybox/, and rootfs/"
	@echo "  distclean         - restore repository to pristine state (remove linux/, busybox/, headers/)"
	@echo "  print-%           - make print-VARNAME (debug)"

help-dag:
	@echo "Artifacts:"
	@echo "  BZIMAGE           = $(BZIMAGE)  [$$(if $$(wildcard $(BZIMAGE)),ok,missing)]"
	@echo "  BUSYBOX_BIN       = $(BUSYBOX_BIN)  [$$(if $$(wildcard $(BUSYBOX_BIN)),ok,missing)]"
	@echo "  INITRAMFS         = $(INITRAMFS)  [$$(if $$(wildcard $(INITRAMFS)),ok,missing)]"
	@echo "  EFI_IMAGE         = $(EFI_IMAGE)  [$$(if $$(wildcard $(EFI_IMAGE)),ok,missing)]"
	@echo "  KERNEL_FRAG_DIR   = $(KERNEL_FRAG_DIR)"
	@echo "  KERNEL_FRAGMENTS  = $(KERNEL_FRAGMENTS)"
	@echo "  BUSYBOX_FRAG_DIR  = $(BUSYBOX_FRAG_DIR)"
	@echo "  BUSYBOX_FRAGMENTS = $(BUSYBOX_FRAGMENTS)"
	@echo "  STAGE_ROOT        = $(STAGE_ROOT)"
	@echo "  PAYLOAD_DIR       = $(PAYLOAD_DIR)"
	@echo "  STAGE_META_DIR    = $(STAGE_META_DIR)"
	@echo "  STAGE_STAMP       = $(STAGE_STAMP)  [$$(if $$(wildcard $(STAGE_STAMP)),ok,missing)]"
	@echo "  STAGE_MOD_DIR     = $(STAGE_MOD_DIR)"
	@echo "  LINUX_MODULES_DIR = $(STAGE_MOD_DIR)/lib/modules/ (auto KVER)"
	@echo
	@echo "Conceptual dependency edges:"
	@echo "  linux-config → $(KERNEL_CFGFILE) → $(BZIMAGE)"
	@echo "  busybox-config → $(BUSYBOX_CFGFILE) → $(BUSYBOX_BIN)"
	@echo "  rootfs/staging (modules+firmware+assets+initramfs+efi) → $(INITRAMFS), $(EFI_IMAGE)"
	@echo
	@echo "tinyos.conf (if present):"
	@echo "  TINYOS_CONF = $(TINYOS_CONF)"
	@echo "  TOOLS_MOUNT = $(TOOLS_MOUNT)"
	@echo "  TINYOS_REL  = $(TINYOS_REL)"
	@echo "  BOOTDIR     = $(BOOTDIR)"

# ===================== Kernel =====================
linux: $(BZIMAGE)

linux-config: $(PREPARE_KERNEL_SH)
	@echo "==> enter linux/: configure"
	@if [ -f "$(KERNEL_CFGFILE)" ]; then \
	  echo "==> Kernel: using existing .config (left untouched)"; \
	else \
	  echo "==> Kernel: merge fragments → .config (from $(KERNEL_FRAG_DIR)/)"; \
	    cd "$(LINUX_DIR)" && VERBOSE=$(V) \
	      "$(PREPARE_KERNEL_SH)" $(KFRAG_ARGS); \
	fi
	@echo "<== leave linux/: configure"

$(KERNEL_CFGFILE): linux-config
	@:

$(BZIMAGE): $(KERNEL_CFGFILE)
	@echo "==> enter linux/: build"
	@$(MAKE) -C "$(LINUX_DIR)" -j "$(J)" V= all
	@echo "<== leave linux/: build"
	@[ -s "$(BZIMAGE)" ] || { echo "ERROR: kernel bzImage not found at $(BZIMAGE)"; exit 1; }

# Build & install kernel modules into a known staging area (rootfs/staging/modules)
linux-modules-install: $(BZIMAGE)
	@echo "==> enter linux/: modules_install → $(STAGE_MOD_DIR)"
	@# Ensure a single KVER staged at a time (avoid mixed trees)
	@rm -rf "$(STAGE_MOD_DIR)/lib/modules" 2>/dev/null || true
	@mkdir -p "$(STAGE_MOD_DIR)"
	@# Suppress kernel's internal depmod to avoid hard failure on benign cycles; we run our own next.
	@$(MAKE) -C "$(LINUX_DIR)" -j "$(J)" V= modules_install INSTALL_MOD_PATH="$(STAGE_MOD_DIR)" DEPMOD=true
	@echo "<== leave linux/: modules_install"
	@echo "==> depmod (robust) for staged modules"
	@VERBOSE=$(V) "$(DEPMOD_SAFE_SH)" --modules-dir "$(STAGE_MOD_DIR)/lib/modules"
	@echo "<== depmod done"

linux-headers: $(HDR_STAMP)
$(HDR_STAMP): $(KERNEL_CFGFILE)
	@echo "==> enter linux/: headers_install → $(LINUX_HEAD_INC)"
	@mkdir -p "$(HEADERS_DIR)"
	@$(MAKE) -C "$(LINUX_DIR)" -j $(J) V= headers_install INSTALL_HDR_PATH="$(HEADERS_DIR)"
	@echo "<== leave linux/: headers_install"
	@touch "$(HDR_STAMP)"

# ===================== BusyBox =====================

busybox-config: $(PREPARE_BUSYBOX_SH) linux-headers
	@echo "==> enter busybox/: configure"
	@if [ -f "$(BUSYBOX_CFGFILE)" ]; then \
	  echo "==> BusyBox: using existing .config (left untouched)"; \
	else \
	  echo "==> BusyBox: merge fragments → .config (from $(BUSYBOX_FRAG_DIR)/)"; \
	  ( cd "$(BUSYBOX_DIR)" && \
	    VERBOSE=$(V) "$(PREPARE_BUSYBOX_SH)" \
	      $(BFRAG_ARGS) \
	      --out .config ); \
	fi
	@echo "<== leave busybox/: configure"

$(BUSYBOX_CFGFILE): busybox-config
	@:

$(BUSYBOX_BIN): $(BUSYBOX_CFGFILE)
	@echo "==> enter busybox/: build (J=$(J))"
	@$(MAKE) -C "$(BUSYBOX_DIR)" -j "$(J)" V= \
	    $(if $(BUSYBOX_CC),CC="$(BUSYBOX_CC)") \
	    EXTRA_CFLAGS="$(BB_CC_INCLUDES)" \
	    EXTRA_CPPFLAGS="$(BB_CC_INCLUDES)"
	@echo "<== leave busybox/: build"
	@[ -x "$(BUSYBOX_BIN)" ] || { echo "ERROR: busybox binary missing at $(BUSYBOX_BIN)"; exit 1; }

busybox: $(BUSYBOX_BIN)

# ===================== Staging (delegates to rootfs) =====================
staging-prep: write-tinyos-conf $(BZIMAGE) linux-headers linux-modules-install $(BUSYBOX_BIN)
	@echo "==> staging preparation complete. When ready, run"
	@echo make -C "$(ROOTFS_DIR)" V=$(V) J=$(J) \
	    STAGE_META_DIR="$(STAGE_META_DIR)" \
	    STAGE_STAMP="$(STAGE_STAMP)" \
	    INSTALL_NAME="$(INSTALL_NAME)" \
	    STAGE_ROOT="$(STAGE_ROOT)" \
	    staging

staging: write-tinyos-conf $(BZIMAGE) linux-headers linux-modules-install $(BUSYBOX_BIN)
	@echo "==> enter rootfs/: staging DAG → $(STAGE_ROOT)"
	@$(MAKE) -C "$(ROOTFS_DIR)" V=$(V) J=$(J) \
	    STAGE_META_DIR="$(STAGE_META_DIR)" \
	    STAGE_STAMP="$(STAGE_STAMP)" \
	    INSTALL_NAME="$(INSTALL_NAME)" \
	    STAGE_ROOT="$(STAGE_ROOT)" \
	    staging

	@echo "<== leave rootfs/: staging"

write-tinyos-conf:
	@$(UPDATE_TINYOS_CONF) \
	  --tinyos-conf  "$(call strip_ws,$(TINYOS_CONF))" \
	  --tools-mount  "$(call strip_ws,$(TOOLS_MOUNT))" \
	  --tinyos-rel   "$(call strip_ws,$(TINYOS_REL))" \
	  --bootdir      "$(call strip_ws,$(BOOTDIR))" \
	  --install-name "$(call strip_ws,$(INSTALL_NAME))" \
	  $(if $(ESP_MOUNT),--esp-mount "$(call strip_ws,$(ESP_MOUNT))") \
	  $(if $(V),--verbose)
	@# Keep the parse-time include in sync within the same invocation.
	@echo "==> refresh .tinyos.mk"
	@"$(SCRIPTS_DIR)/tinyos-conf-to-mk.sh" \
	  --in  "$(TINYOS_CONF)" \
	  --out "$(TINYOS_MK).tmp" && \
	mv -f "$(TINYOS_MK).tmp" "$(TINYOS_MK)"

# ===================== Install =================================================
# Read-only: uses tinyos.conf as source of truth (TOOLS_MOUNT/TINYOS_REL), verifies
# an actual EFI application exists in payload by content (via file(1) if available),
# then rsyncs payload into the target directory.
install:
	@VERBOSE=$(V) "$(INSTALL_PAYLOAD_SH)" \
	  --stage-stamp "$(STAGE_STAMP)" \
	  --payload     "$(PAYLOAD_DIR)" \
	  --tools-mount "$(TOOLS_MOUNT)" \
	  --tinyos-rel  "$(TINYOS_REL)" \
	  --manifest    "$(INSTALL_MANIFEST)" \
	  --backups     "$(INSTALL_BACKUPS)"

# ===================== Git helpers & utilities =====================
linux-pull:
	@echo "==> Updating kernel tree"
	@if [ -d "$(LINUX_DIR)/.git" ]; then \
	  $(GIT) -C "$(LINUX_DIR)" pull --ff-only --depth=1; \
	elif [ -d "$(LINUX_DIR)" ]; then \
	  echo "Kernel dir exists but is not a git repo; replacing with shallow clone…"; \
	  rm -rf "$(LINUX_DIR)"; \
	  $(GIT) clone --depth=1 "$(LINUX_REMOTE)" "$(LINUX_DIR)"; \
	else \
	  echo "Kernel tree missing; shallow-cloning…"; \
	  $(GIT) clone --depth=1 "$(LINUX_REMOTE)" "$(LINUX_DIR)"; \
	fi

busybox-pull:
	@echo "==> Updating busybox tree"
	@if [ -d "$(BUSYBOX_DIR)/.git" ]; then \
	  $(GIT) -C "$(BUSYBOX_DIR)" pull --ff-only --depth=1; \
	elif [ -d "$(BUSYBOX_DIR)" ]; then \
	  echo "BusyBox dir exists but is not a git repo; replacing with shallow clone…"; \
	  rm -rf "$(BUSYBOX_DIR)"; \
	  $(GIT) clone --depth=1 "$(BUSYBOX_REMOTE)" "$(BUSYBOX_DIR)"; \
	else \
	  echo "BusyBox tree missing; shallow-cloning…"; \
	  $(GIT) clone --depth=1 "$(BUSYBOX_REMOTE)" "$(BUSYBOX_DIR)"; \
	fi

pull: linux-pull busybox-pull

# Prepare a sparse-checkout repo (cone mode) without fetching (used by on-demand sparse pulls)
firmware-init:
	@echo "==> firmware-init: preparing sparse (cone) linux-firmware repo at $(FW_REPO_DIR) (no fetch)"
	@mkdir -p "$(FW_REPO_DIR)"
	@if [ ! -d "$(FW_REPO_DIR)/.git" ]; then \
	  $(GIT) -C "$(FW_REPO_DIR)" init; \
	  $(GIT) -C "$(FW_REPO_DIR)" remote add origin "$(LINUX_FW_REMOTE)".git; \
	fi
	@# Ensure we have a tracking branch (main) so later pulls work:
	@{ \
	  $(GIT) -C "$(FW_REPO_DIR)" rev-parse --verify main >/dev/null 2>&1 \
	  || { $(GIT) -C "$(FW_REPO_DIR)" fetch --depth=1 origin main && \
	       $(GIT) -C "$(FW_REPO_DIR)" switch -c main --track origin/main; }; \
	}
	@# Enable sparse-checkout **cone mode**; abort if unsupported.
	@$(GIT) -C "$(FW_REPO_DIR)" sparse-checkout init --cone >/dev/null 2>&1 \
	  || { echo "ERROR: your git lacks sparse-checkout CONE mode. Upgrade git, or run: make firmware-full (full clone)"; exit 3; }

firmware-full:
	@echo "==> (Full) Clone or update linux-firmware into $(FW_REPO_DIR) (non-sparse)"
	@if [ -d "$(FW_REPO_DIR)/.git" ]; then \
	  # Ensure branch exists, then fetch and hard-reset to origin/main (works for full or sparse trees)
	  { $(GIT) -C "$(FW_REPO_DIR)" rev-parse --verify main >/dev/null 2>&1 \
	    || $(GIT) -C "$(FW_REPO_DIR)" switch -c main --track origin/main >/dev/null 2>&1 || true; }; \
	  $(GIT) -C "$(FW_REPO_DIR)" fetch --depth=1 origin main; \
	  $(GIT) -C "$(FW_REPO_DIR)" switch main >/dev/null 2>&1 || true; \
	  $(GIT) -C "$(FW_REPO_DIR)" reset --hard origin/main; \
	  # If the repo was previously sparse, convert it to full by disabling sparse-checkout
	  $(GIT) -C "$(FW_REPO_DIR)" config core.sparseCheckout false || true; \
	  rm -f "$(FW_REPO_DIR)/.git/info/sparse-checkout" 2>/dev/null || true; \
	else \
	  $(GIT) clone --depth=1 "$(LINUX_FW_REMOTE)".git "$(FW_REPO_DIR)"; \
	  $(GIT) -C "$(FW_REPO_DIR)" switch -c main --track origin/main >/dev/null 2>&1 || true; \
	fi

# Update whatever repo currently exists (sparse or full). If none, suggest init.
firmware-pull:
	@echo "==> firmware-pull: update linux-firmware in $(FW_REPO_DIR) (sparse or full)"
	@if [ -d "$(FW_REPO_DIR)/.git" ]; then \
	  # Ensure a main branch exists locally, then fast-forward to origin/main.
	  { $(GIT) -C "$(FW_REPO_DIR)" rev-parse --verify main >/dev/null 2>&1 \
	    || $(GIT) -C "$(FW_REPO_DIR)" switch -c main --track origin/main >/dev/null 2>&1 || true; }; \
	  $(GIT) -C "$(FW_REPO_DIR)" fetch --depth=1 origin main; \
	  $(GIT) -C "$(FW_REPO_DIR)" switch -q main >/dev/null 2>&1 || true; \
	  $(GIT) -C "$(FW_REPO_DIR)" reset --hard -q origin/main; \
	  # If this is a sparse repo, we do NOT change sparse paths here; we just refresh what’s present.
	  # If this is a full repo, the above acts like firmware-full without toggling sparse state.
	else \
	  echo "No linux-firmware repo at '$(FW_REPO_DIR)'."; \
	  echo "Hint: initialize a sparse (cone) repo with:  make firmware-init"; \
	  echo "      or do a full clone with:               make firmware-full"; \
	  exit 2; \
	fi

bootstrap: pull all

list:
	@echo "ROOT=$(ROOT)"; \
	echo "CONFIG_DIR=$(CONFIG_DIR)"; \
	echo "CONFIG_FILES_DIR=$(CONFIG_FILES_DIR)"; \
	echo "LINUX_DIR=$(LINUX_DIR)"; \
	echo "BUSYBOX_DIR=$(BUSYBOX_DIR)"; \
	echo "BUSYBOX_CC=$(BUSYBOX_CC)"; \
	echo "ROOTFS_DIR=$(ROOTFS_DIR)"; \
	echo "SCRIPTS_DIR=$(SCRIPTS_DIR)"; \
	echo "STAGE_ROOT=$(STAGE_ROOT)"; \
	echo "PAYLOAD_DIR=$(PAYLOAD_DIR)"; \
	echo "STAGE_META_DIR=$(STAGE_META_DIR)" \
	echo "STAGE_STAMP=$(STAGE_STAMP)"; \
	echo "INITRAMFS=$(INITRAMFS)"; \
	echo "EFI_IMAGE=$(EFI_IMAGE)"; \
	echo "STAGE_MOD_DIR=$(STAGE_MOD_DIR)"; \
	echo "LINUX_MODULES_DIR=$(STAGE_MOD_DIR)/lib/modules/ (auto KVER)"; \
	echo "TINYOS_CONF=$(TINYOS_CONF)"; \
	echo "TOOLS_MOUNT=$(TOOLS_MOUNT)"; \
	echo "TINYOS_REL=$(TINYOS_REL)"; \
	echo "ESP_MOUNT=$(ESP_MOUNT)"; \
	echo "BOOTDIR=$(BOOTDIR)"; \
	echo "INSTALL_NAME=$(INSTALL_NAME)"; \
	echo "FIRMWARE_SRC=$(FIRMWARE_SRC)"; \
	echo "RAMFS_MAX_BYTES=$(RAMFS_MAX_BYTES)"; \
	echo "HEAVY_BYTES=$(HEAVY_BYTES)"

clean:
	@echo "==> enter rootfs/: clean"
	@$(MAKE) -C "$(ROOTFS_DIR)" clean
	@echo "<== leave rootfs/: clean"
	@rm -f "$(TINYOS_MK)"

mrproper: clean
	@echo "==> mrproper: linux/, busybox/, rootfs/, headers"
	@{ echo "==> enter linux/: mrproper";   [ -d "$(LINUX_DIR)" ] && $(MAKE) -C "$(LINUX_DIR)" mrproper   || true; echo "<== leave linux/: mrproper"; }
	@{ echo "==> enter busybox/: mrproper"; [ -d "$(BUSYBOX_DIR)" ] && $(MAKE) -C "$(BUSYBOX_DIR)" mrproper || true; echo "<== leave busybox/: mrproper"; }
	@{ echo "==> enter rootfs/: mrproper";  [ -f "$(ROOTFS_DIR)/Makefile" ] && $(MAKE) -C "$(ROOTFS_DIR)" mrproper || true; echo "<== leave rootfs/: mrproper"; }
	@rm -rf "$(HEADERS_DIR)"
	@echo "==> mrproper done."

distclean: mrproper
	@echo "==> Distclean: removing linux/, busybox/"
	@rm -rf "$(LINUX_DIR)" "$(BUSYBOX_DIR)"

print-%:
	@echo $*=$($*)
