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
APP_IMAGE_TAG    ?= cogip/cogip-tools:console
APP_IMAGE_TAR    := $(DL_DIR)/cogip-app.image.tar.zst
APP_IMAGE_INC    := layers/meta-cogip-app/recipes-cogip/cogip-app-image/cogip-app-image.inc

# kas merges colon-separated configs, later ones overriding earlier.
# Append the local overlay automatically when present so its env block
# (KIOSK_URL, WLAN_SSID, WLAN_PSK) wins over kas-cogip.yml defaults.
LOCAL_CONFIG     := $(wildcard kas-local.yml)
KAS_CONFIG       := $(BASE_CONFIG)$(if $(LOCAL_CONFIG),:$(LOCAL_CONFIG))

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

# Find the wic image produced by the build. The deploy dir is tmp-glibc
# (glibc distro) and the image carries a .rootfs infix; use the stable
# symlink Yocto maintains to the latest build.
WIC_IMAGE        = $(BUILD_DIR)/tmp-glibc/deploy/images/$(MACHINE)/$(IMAGE)-$(MACHINE).rootfs.wic.bz2

.PHONY: help setup build shell flash clean distclean app-image

help:
	@echo "Targets:"
	@echo "  setup     bootstrap uv + .venv with kas (idempotent)"
	@echo "  app-image build the arm64 cogip container + save it for embedding"
	@echo "  build     build the kiosk image (default target)"
	@echo "  shell     enter a kas/bitbake shell"
	@echo "  flash     write the built .wic.bz2 to SDCARD_DEV ($(SDCARD_DEV))"
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

# Build the arm64 cogip-console container from the cogip-tools Dockerfile
# (COGIP_TOOLS_PATH, read-only), save it (zstd) into DL_DIR, and pin its
# checksum in cogip-app-image.inc so the recipe (and provenance) follow.
# Uses buildx + QEMU for cross-build when the host is not arm64.
app-image:
	@test -f "$(COGIP_TOOLS_PATH)/Dockerfile" || { \
	  echo "ERROR: no Dockerfile at COGIP_TOOLS_PATH=$(COGIP_TOOLS_PATH)" >&2; \
	  echo "Point COGIP_TOOLS_PATH at your cogip-tools checkout." >&2; exit 1; }
	@mkdir -p $(DL_DIR)
	docker buildx build --platform linux/arm64 \
	    --target cogip-console \
	    -t $(APP_IMAGE_TAG) \
	    --load \
	    $(COGIP_TOOLS_PATH)
	docker save $(APP_IMAGE_TAG) | zstd -T0 -19 -o $(APP_IMAGE_TAR)
	@sha=$$(sha256sum $(APP_IMAGE_TAR) | cut -d' ' -f1); \
	 sed -i "s/^COGIP_APP_IMAGE_SHA256 = .*/COGIP_APP_IMAGE_SHA256 = \"$$sha\"/" $(APP_IMAGE_INC); \
	 echo "Saved $(APP_IMAGE_TAR) ($$(du -h $(APP_IMAGE_TAR) | cut -f1)), sha256 $$sha pinned in cogip-app-image.inc"

build: $(KAS)
	@if [ ! -f "$(APP_IMAGE_TAR)" ]; then \
	  echo "ERROR: $(APP_IMAGE_TAR) is missing (DL_DIR has no container image)." >&2; \
	  echo "Build it first:  make app-image" >&2; \
	  exit 1; \
	fi
	@mkdir -p $(CCACHE_HOST)
	$(KAS_CMD) $(KAS_RUNTIME_FLAG) build $(KAS_CONFIG)

shell: $(KAS)
	@mkdir -p $(CCACHE_HOST)
	$(KAS_CMD) $(KAS_RUNTIME_FLAG) shell $(KAS_CONFIG)

flash: $(WIC_IMAGE)
	@if [ ! -b "$(SDCARD_DEV)" ]; then \
	  echo "$(SDCARD_DEV) is not a block device. Set SDCARD_DEV=/dev/..." >&2; \
	  exit 1; \
	fi
	bzip2 -dc $(WIC_IMAGE) | sudo dd of=$(SDCARD_DEV) bs=4M status=progress conv=fsync
	sync

clean:
	rm -rf $(BUILD_DIR)/tmp

distclean:
	rm -rf $(BUILD_DIR) $(VENV_DIR)
