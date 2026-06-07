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

# Pre-built Cogip app container image (built out-of-band, embedded in the
# rootfs by meta-cogip-app's cogip-app-image recipe). REPO_ROOT is the
# cogip-tools checkout that holds the Dockerfile / docker-compose.yml.
REPO_ROOT        ?= ../cogip-tools
APP_IMAGE_TAG    ?= cogip/cogip-tools:console
APP_IMAGE_DIR    := layers/meta-cogip-app/files-prebuilt
APP_IMAGE_TAR    := $(APP_IMAGE_DIR)/cogip-app.image.tar.zst

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
else
KAS_CMD          := $(KAS)
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

# Build the arm64 cogip-console container from the repo Dockerfile and
# save it (zstd-compressed) where the cogip-app-image recipe expects it.
# Run on the dev host / CI before `make build`. Uses buildx + QEMU for
# cross-platform if the host is not arm64.
app-image:
	@mkdir -p $(APP_IMAGE_DIR)
	docker buildx build --platform linux/arm64 \
	    --target cogip-console \
	    -t $(APP_IMAGE_TAG) \
	    --load \
	    $(REPO_ROOT)
	docker save $(APP_IMAGE_TAG) | zstd -T0 -19 -o $(APP_IMAGE_TAR)
	@echo "Saved $(APP_IMAGE_TAR) ($$(du -h $(APP_IMAGE_TAR) | cut -f1))"

build: $(KAS)
	@if [ ! -f "$(APP_IMAGE_TAR)" ]; then \
	  echo "ERROR: $(APP_IMAGE_TAR) is missing." >&2; \
	  echo "Build the container image first:  make app-image" >&2; \
	  exit 1; \
	fi
	$(KAS_CMD) build $(KAS_CONFIG)

shell: $(KAS)
	$(KAS_CMD) shell $(KAS_CONFIG)

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
