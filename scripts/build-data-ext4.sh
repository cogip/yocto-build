#!/bin/bash
# Build the /data partition image with the Cogip container image ALREADY
# loaded into a Docker overlay2 store, so the Pi does not have to run the
# slow `docker load` at first boot.
#
# Why a transient dockerd: a usable Docker graph (overlay2 layers +
# image/repositories metadata) is only ever produced by dockerd itself --
# there is no offline "populate the graph" tool. So we run a throwaway,
# fully isolated daemon (its own data-root / socket / exec-root, no
# bridge, no iptables -- `docker load` needs no networking), load the
# image into it, stop it cleanly to flush the graph, then bake that graph
# into an ext4 image with mke2fs -d.
#
# Must run as root (dockerd + mke2fs preserving root-owned graph files).
# Invoke via `sudo make app-data`. The result is owned back to the caller.
#
# Portability note: the resulting overlay2 graph is consumed as-is by the
# Pi's docker-moby. Same storage driver (overlay2) on both -> normally
# fine, but this is the one thing only the board can confirm. cogip-app-load
# keeps its `docker image inspect` skip, so if the graph is rejected the
# first boot just falls back to loading the tarball (slow but correct).
set -euo pipefail

TARBALL="${1:?usage: build-data-ext4.sh <image.tar.zst> <out.ext4> [image-tag]}"
OUT="${2:?missing output ext4 path}"
TAG="${3:-cogip/cogip-tools:console}"

if [ "$(id -u)" -ne 0 ]; then
    echo "build-data-ext4: must run as root (dockerd + mke2fs). Use: make app-data" >&2
    exit 1
fi
[ -f "$TARBALL" ] || { echo "build-data-ext4: $TARBALL not found (run 'make app-image' first)" >&2; exit 1; }

WORK="$(mktemp -d)"
DOCKER_HOST_SOCK="unix://$WORK/docker.sock"
# Stop the transient dockerd via its OWN pid (from --pidfile), so SIGTERM
# reaches dockerd directly (graceful: flushes the graph) even though it
# runs under `unshare`. $NS_PID is the unshare wrapper we wait on.
stop_dockerd() {
    [ -f "$WORK/dockerd.pid" ] && kill "$(cat "$WORK/dockerd.pid")" 2>/dev/null || true
    [ -n "${NS_PID:-}" ] && wait "$NS_PID" 2>/dev/null || true
    NS_PID=""
}
cleanup() { stop_dockerd; rm -rf "$WORK"; }
trap cleanup EXIT

# fs root = $WORK/rootfs, which will contain a single "docker/" dir = the
# Pi's docker data-root (/data/docker, per cogip-docker-conf daemon.json).
ROOTFS="$WORK/rootfs"
DATAROOT="$ROOTFS/docker"
mkdir -p "$DATAROOT"

# Run the transient dockerd in its OWN network namespace (unshare --net).
# Even with --bridge=none, dockerd cleans up the default bridge at init,
# which would delete the HOST's docker0 and break the main daemon (and
# kas-container). A private netns makes that physically impossible; the
# docker client still reaches it over the unix socket (filesystem, not
# network). docker load needs no networking. lo is brought up for dockerd.
echo "build-data-ext4: starting transient dockerd (overlay2, isolated netns) ..."
cat > "$WORK/launch-dockerd.sh" <<EOF
#!/bin/bash
ip link set lo up 2>/dev/null || true
exec dockerd \\
    --data-root="$DATAROOT" \\
    --exec-root="$WORK/exec" \\
    --host="$DOCKER_HOST_SOCK" \\
    --pidfile="$WORK/dockerd.pid" \\
    --storage-driver=overlay2 \\
    --bridge=none --iptables=false
EOF
chmod +x "$WORK/launch-dockerd.sh"
unshare --net -- "$WORK/launch-dockerd.sh" >"$WORK/dockerd.log" 2>&1 &
NS_PID=$!

# Wait for the daemon to accept connections.
for _ in $(seq 1 60); do
    docker -H "$DOCKER_HOST_SOCK" info >/dev/null 2>&1 && break
    sleep 0.5
done
docker -H "$DOCKER_HOST_SOCK" info >/dev/null 2>&1 || {
    echo "build-data-ext4: transient dockerd did not come up. Log:" >&2
    cat "$WORK/dockerd.log" >&2
    exit 1
}

echo "build-data-ext4: loading $TARBALL into the transient store ..."
zstd -dc "$TARBALL" | docker -H "$DOCKER_HOST_SOCK" load
docker -H "$DOCKER_HOST_SOCK" image inspect "$TAG" >/dev/null \
    || { echo "build-data-ext4: $TAG not present after load" >&2; exit 1; }

# Stop the daemon cleanly so the graph + repositories.json are flushed.
echo "build-data-ext4: stopping transient dockerd to flush the graph ..."
stop_dockerd

# Size the ext4: graph size + 30% slack + 64 MiB headroom. The /data
# partition is larger; data.mount grows the fs to fill it at first boot.
SIZE_KB="$(du -sk "$ROOTFS" | cut -f1)"
SIZE_MB="$(( SIZE_KB / 1024 * 13 / 10 + 64 ))"

echo "build-data-ext4: building ext4 (${SIZE_MB} MiB) with the pre-loaded graph ..."
rm -f "$OUT"
mke2fs -q -t ext4 -L data -d "$ROOTFS" "$OUT" "${SIZE_MB}M"

# Hand the artifact back to the invoking user.
if [ -n "${SUDO_UID:-}" ]; then
    chown "${SUDO_UID}:${SUDO_GID}" "$OUT"
fi
echo "build-data-ext4: wrote $OUT ($(du -h "$OUT" | cut -f1)), docker graph pre-loaded at /docker."
