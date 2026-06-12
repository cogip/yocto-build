# Cogip Yocto kiosk image build helpers.
#
# Wraps kas to provide reproducible, one-command build / flash workflow.
# Per-deployment values and secrets (KIOSK_URL, Wi-Fi creds) live in a
# gitignored kas-local.yml overlay; see kas-local.yml.example.

BASE_CONFIG      ?= kas-cogip.yml
BUILD_DIR        ?= build
IMAGE            ?= cogip-kiosk-image
MACHINE          ?= raspberrypi4-64
SDCARD_DEV       ?= /dev/mmcblk0

# Shared, persistent Yocto caches kept OUTSIDE the build dir so they
# survive `make distclean` and are reused across projects. kas-container
# bind-mounts DL_DIR -> /downloads and SSTATE_DIR -> /sstate natively
# (it reads these env vars). ccache has no native support, so it is
# bind-mounted explicitly via --runtime-args and CCACHE_TOP_DIR=/ccache
# (set in kas-cogip.yml).
YOCTO_CACHE      ?= $(HOME)/.yocto
export DL_DIR    := $(YOCTO_CACHE)/downloads
export SSTATE_DIR := $(YOCTO_CACHE)/sstate-cache
CCACHE_HOST      := $(YOCTO_CACHE)/ccache
KAS_RUNTIME      := --runtime-args "-v $(CCACHE_HOST):/ccache"

# Pre-built Cogip app container image. `make app-image` builds it from
# the cogip-tools Dockerfile and drops the tarball into DL_DIR; the
# cogip-app-image recipe embeds it (checksum pinned in
# meta-cogip-app/.../cogip-app-image.inc). cogip-tools is only read,
# never modified: point COGIP_TOOLS_PATH at your checkout (default
# ../cogip-tools).
COGIP_TOOLS_PATH ?= ../cogip-tools
# Shipped image (deploy): cogip-console base + a self-contained /opt/.venv
# with the COGIP tools wheel installed. compose.yml references this tag.
APP_IMAGE_TAG    ?= cogip/cogip-tools:console
# Intermediate base built straight from the cogip-tools Dockerfile.
APP_IMAGE_BASE_TAG ?= cogip/cogip-tools:console-base
# Cross-compiled arm64 wheel produced by cogip-tools' build_wheel target.
APP_WHEEL        ?= cogip_tools-1.0.0-cp313-abi3-linux_aarch64.whl
APP_IMAGE_TAR    := $(DL_DIR)/cogip-app.image.tar.zst
APP_IMAGE_INC    := layers/meta-cogip-app/recipes-cogip/cogip-app-image/cogip-app-image.inc

# Include the Docker / cogip-tools app stack (1) or build a bare kiosk
# (0: Cog + networking only, no Docker, no app tarball needed -- handy
# for isolating Wi-Fi / display issues). Plumbed to bitbake via a
# generated kas overlay (env-var passthrough does not cross
# kas-container; only kas config env blocks do).
COGIP_APP        ?= 1
APP_OVERLAY      := .kas-cogip-app.yml

# kas merges colon-separated configs, later ones overriding earlier.
# Order: base, then the generated COGIP_APP overlay, then the local
# overlay (KIOSK_URL/WLAN/ROBOT_ID) when present.
LOCAL_CONFIG     := $(wildcard kas-local.yml)
KAS_CONFIG       := $(BASE_CONFIG):$(APP_OVERLAY)$(if $(LOCAL_CONFIG),:$(LOCAL_CONFIG))

# Self-contained venv managed by uv. Activate by sourcing it, or just
# call binaries through $(KAS) / $(KAS_CONTAINER) which already point
# inside it.
VENV_DIR         := .venv
KAS              := $(VENV_DIR)/bin/kas
# kas-container runs kas inside the Siemens Yocto image (Docker), so
# host doesn't need chrpath/diffstat/lz4/etc. Toggle off for native
# builds with: `make build USE_CONTAINER=0`
USE_CONTAINER    ?= 1
ifeq ($(USE_CONTAINER),1)
KAS_CMD          := $(VENV_DIR)/bin/kas-container
# Extra docker mount for the shared ccache (container mode only).
KAS_RUNTIME_FLAG := $(KAS_RUNTIME)
else
KAS_CMD          := $(KAS)
KAS_RUNTIME_FLAG :=
endif
# Prefer uv in $PATH; fall back to the default install location used by
# the official installer (~/.local/bin/uv) so the bootstrap works in
# the same `make setup` invocation that installed it.
UV               := $(shell command -v uv 2>/dev/null || echo $(HOME)/.local/bin/uv)

# Find the wic image + its block map produced by the build. The deploy
# dir is tmp-glibc (glibc distro) and the image carries a .rootfs infix;
# use the stable symlinks Yocto maintains to the latest build.
DEPLOY_DIR       = $(BUILD_DIR)/tmp-glibc/deploy/images/$(MACHINE)
WIC_IMAGE        = $(DEPLOY_DIR)/$(IMAGE)-$(MACHINE).rootfs.wic.bz2
WIC_BMAP         = $(DEPLOY_DIR)/$(IMAGE)-$(MACHINE).rootfs.wic.bmap

.PHONY: help setup build shell flash clean distclean app-image

help:
	@echo "Targets:"
	@echo "  setup     bootstrap uv + .venv with kas (idempotent)"
	@echo "  app-image build the arm64 cogip container + save it for embedding"
	@echo "  build     build the kiosk image (default target)"
	@echo "  shell     enter a kas/bitbake shell"
	@echo "  flash     bmaptool the built image to SDCARD_DEV ($(SDCARD_DEV))"
	@echo "  clean     remove build/tmp"
	@echo "  distclean wipe entire $(BUILD_DIR) (forces full re-fetch)"
	@echo ""
	@echo "Per-deployment values (KIOSK_URL, WLAN_SSID, WLAN_PSK) go in"
	@echo "kas-local.yml (copy from kas-local.yml.example). Detected: $(if $(LOCAL_CONFIG),yes,no)"
	@echo ""
	@echo "Variables (override on command line):"
	@echo "  SDCARD_DEV=$(SDCARD_DEV)"
	@echo "  USE_CONTAINER=$(USE_CONTAINER)   # 0 to run kas natively on host"

setup: $(KAS)

# Install uv via the official installer to ~/.local/bin if missing.
# Idempotent: re-running just no-ops once uv is on disk.
$(UV):
	@if ! command -v uv >/dev/null 2>&1 && [ ! -x "$(UV)" ]; then \
	  echo "Installing uv to $(HOME)/.local/bin ..."; \
	  curl -LsSf https://astral.sh/uv/install.sh | sh; \
	  echo ""; \
	  echo "uv installed. Add this to your shell rc if not already done:"; \
	  echo "  export PATH=\"\$$HOME/.local/bin:\$$PATH\""; \
	fi

# `uv sync` reads pyproject.toml + uv.lock, materializes .venv with the
# pinned dependency set. Re-run any time pyproject.toml or uv.lock
# changes; uv handles the diff incrementally.
$(KAS): $(UV) pyproject.toml
	$(UV) sync

# Build the shipped Cogip app image and save it (zstd) into DL_DIR, then
# pin its checksum in cogip-app-image.inc so the recipe / provenance
# follow. cogip-tools is only ever READ (COGIP_TOOLS_PATH), never
# modified. Three steps:
#   1. Cross-compile the arm64 wheel with cogip-tools' own build_wheel
#      service (debian + aarch64 cross-gcc -> fast, no QEMU C++ build).
#   2. Build the cogip-console base (arm64) from the cogip-tools Dockerfile.
#   3. Build the deploy image (Dockerfile.deploy): base + a /opt/.venv
#      with the wheel installed, tagged as the shipped image.
app-image:
	@test -f "$(COGIP_TOOLS_PATH)/Dockerfile" || { \
	  echo "ERROR: no Dockerfile at COGIP_TOOLS_PATH=$(COGIP_TOOLS_PATH)" >&2; \
	  echo "Point COGIP_TOOLS_PATH at your cogip-tools checkout." >&2; exit 1; }
	@mkdir -p $(DL_DIR)
	# 1. Cross-compiled wheel -> $(COGIP_TOOLS_PATH)/dist/$(APP_WHEEL)
	cd $(COGIP_TOOLS_PATH) && UID=$$(id -u) GID=$$(id -g) \
	    docker compose run --rm --build build_wheel
	@test -f "$(COGIP_TOOLS_PATH)/dist/$(APP_WHEEL)" || { \
	  echo "ERROR: wheel not produced: $(COGIP_TOOLS_PATH)/dist/$(APP_WHEEL)" >&2; exit 1; }
	# 2. cogip-console base
	docker buildx build --platform linux/arm64 \
	    --target cogip-console \
	    -t $(APP_IMAGE_BASE_TAG) \
	    --load \
	    $(COGIP_TOOLS_PATH)
	# 3. deploy image (base + /opt/.venv with the wheel)
	cp $(COGIP_TOOLS_PATH)/dist/$(APP_WHEEL) ./$(APP_WHEEL)
	docker buildx build --platform linux/arm64 \
	    -f Dockerfile.deploy \
	    --build-arg BASE=$(APP_IMAGE_BASE_TAG) \
	    --build-arg WHEEL=$(APP_WHEEL) \
	    -t $(APP_IMAGE_TAG) \
	    --load \
	    .
	rm -f ./$(APP_WHEEL)
	docker save $(APP_IMAGE_TAG) | zstd -f -T0 -19 -o $(APP_IMAGE_TAR)
	@sha=$$(sha256sum $(APP_IMAGE_TAR) | cut -d' ' -f1); \
	 sed -i "s/^COGIP_APP_IMAGE_SHA256 = .*/COGIP_APP_IMAGE_SHA256 = \"$$sha\"/" $(APP_IMAGE_INC); \
	 echo "Saved $(APP_IMAGE_TAR) ($$(du -h $(APP_IMAGE_TAR) | cut -f1)), sha256 $$sha pinned in cogip-app-image.inc"

# Regenerate the COGIP_APP overlay every invocation so the value tracks
# the make variable (kas reads env blocks from config files, not the
# calling environment, when running in a container).
.PHONY: $(APP_OVERLAY)
$(APP_OVERLAY):
	@printf 'header:\n  version: 14\nenv:\n  COGIP_APP: "%s"\n' "$(COGIP_APP)" > $@

build: $(KAS) $(APP_OVERLAY)
	@if [ "$(COGIP_APP)" = "1" ] && [ ! -f "$(APP_IMAGE_TAR)" ]; then \
	  echo "ERROR: $(APP_IMAGE_TAR) is missing (DL_DIR has no container image)." >&2; \
	  echo "Build it first:  make app-image   (or build a bare kiosk: make build COGIP_APP=0)" >&2; \
	  exit 1; \
	fi
	@mkdir -p $(CCACHE_HOST)
	$(KAS_CMD) $(KAS_RUNTIME_FLAG) build $(KAS_CONFIG)

shell: $(KAS) $(APP_OVERLAY)
	@mkdir -p $(CCACHE_HOST)
	$(KAS_CMD) $(KAS_RUNTIME_FLAG) shell $(KAS_CONFIG)

flash: $(WIC_IMAGE)
	@if [ ! -b "$(SDCARD_DEV)" ]; then \
	  echo "$(SDCARD_DEV) is not a block device. Set SDCARD_DEV=/dev/..." >&2; \
	  exit 1; \
	fi
	@command -v bmaptool >/dev/null 2>&1 || { \
	  echo "bmaptool not found: sudo apt install bmap-tools" >&2; exit 1; }
	# Unmount any auto-mounted partition of the target disk first, so
	# bmaptool writes to a quiescent device. lsblk lists the disk then its
	# partitions (full paths); skip the disk line, umount the rest.
	@for part in $$(lsblk -lnpo NAME $(SDCARD_DEV) | tail -n +2); do \
	  if findmnt -rn -S "$$part" >/dev/null 2>&1; then \
	    echo "unmounting $$part"; sudo umount "$$part" || exit 1; \
	  fi; \
	done
	# bmaptool decompresses the .wic.bz2 on the fly, writes only mapped
	# blocks (fast, skips the mostly-empty data partition) and verifies
	# the sha256 of each block against the .bmap.
	sudo bmaptool copy --bmap $(WIC_BMAP) $(WIC_IMAGE) $(SDCARD_DEV)
	sync

clean:
	rm -rf $(BUILD_DIR)/tmp

distclean:
	rm -rf $(BUILD_DIR) $(VENV_DIR)
