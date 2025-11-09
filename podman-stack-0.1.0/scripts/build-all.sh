#!/usr/bin/env bash
set -euo pipefail

# This script builds a full Podman stack into $DESTDIR/opt/podman-${PODMAN_VERSION}
# It is intended to be invoked by debian/rules.
# Network access is required (clones upstream repos).

: "${DESTDIR:?DESTDIR is required}"
: "${DEB_HOST_ARCH:?DEB_HOST_ARCH is required}"

# Discover latest Podman tag unless provided
if [[ -z "${PODMAN_VERSION:-}" ]]; then
  PODMAN_VERSION="$(git ls-remote --tags https://github.com/containers/podman.git     | sed 's|.*refs/tags/||' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -n1)"
fi

PREFIX="${DESTDIR}/opt/podman-${PODMAN_VERSION}"
mkdir -p "${PREFIX}"
echo "Building into PREFIX=${PREFIX}"

# Detect Go arch from DEB_HOST_ARCH
case "${DEB_HOST_ARCH}" in
  amd64) GO_ARCH="amd64" ;;
  arm64) GO_ARCH="arm64" ;;
  armhf|armel) GO_ARCH="armv6l" ;; # not targeted by this package
  *) echo "Unsupported arch: ${DEB_HOST_ARCH}" >&2; exit 1 ;;
esac

# Ensure Go (local toolchain for build)
GO_VER="${GO_VER:-1.23.3}"
mkdir -p /tmp/go-tool
curl -fsSLO "https://go.dev/dl/go${GO_VER}.linux-${GO_ARCH}.tar.gz"
rm -rf /tmp/go-tool/go
tar -C /tmp/go-tool -xzf "go${GO_VER}.linux-${GO_ARCH}.tar.gz"
export PATH="/tmp/go-tool/go/bin:${PATH}"

# Build flags
export CGO_ENABLED=1
export GOFLAGS="-buildvcs=false -trimpath -mod=readonly -modcacherw -ldflags=-s -ldflags=-w"

# Work directory
WRK="$(mktemp -d)"
trap 'rm -rf "${WRK}"' EXIT
pushd "${WRK}" >/dev/null

# crun
git clone https://github.com/containers/crun.git
pushd crun >/dev/null
git fetch --tags --force
CRUN_TAG="$(git tag -l '1.*' | sort -V | tail -n1)"
git switch --detach "${CRUN_TAG}"
./autogen.sh
./configure --prefix="${PREFIX}"
make -j"$(nproc)"
make install
popd >/dev/null

# conmon
git clone https://github.com/containers/conmon.git
pushd conmon >/dev/null
git fetch --tags --force
CONMON_TAG="$(git tag -l 'v[0-9]*' | sort -V | tail -n1)"
git switch --detach "${CONMON_TAG}"
make -j"$(nproc)" GIT_COMMIT=unknown
make install PREFIX="${PREFIX}"
popd >/dev/null

# netavark
git clone https://github.com/containers/netavark.git
pushd netavark >/dev/null
git fetch --tags --force
NAV_TAG="$(git tag -l 'v[0-9]*' | sort -V | tail -n1)"
git switch --detach "${NAV_TAG}"
make -j"$(nproc)"
make install PREFIX="${PREFIX}"
popd >/dev/null

# aardvark-dns
git clone https://github.com/containers/aardvark-dns.git
pushd aardvark-dns >/dev/null
git fetch --tags --force
AARD_TAG="$(git tag -l 'v[0-9]*' | sort -V | tail -n1)"
git switch --detach "${AARD_TAG}"
make -j"$(nproc)"
make install PREFIX="${PREFIX}"
popd >/dev/null

# passt/pasta
git clone https://passt.top/passt
pushd passt >/dev/null
make -j"$(nproc)"
make prefix="${PREFIX}" install
popd >/dev/null

# podman
git clone https://github.com/containers/podman.git
pushd podman >/dev/null
git fetch --tags
git switch --detach "${PODMAN_VERSION}"
make clean
make BUILDTAGS="apparmor seccomp systemd containers_image_ostree_stub"
env "PATH=${PREFIX}/bin:/tmp/go-tool/go/bin:${PATH}"   make install PREFIX="${PREFIX}"
env "PATH=${PREFIX}/bin:/tmp/go-tool/go/bin:${PATH}"   make install.systemd PREFIX="${PREFIX}"
popd >/dev/null

# System glue (installed by package, not in DESTDIR rootfs files)
# Only place profile and ld.so data in staging.
install -d "${DESTDIR}/etc/profile.d" "${DESTDIR}/etc/ld.so.conf.d"
cat > "${DESTDIR}/etc/profile.d/zz-podman.sh" <<EOF
export PATH=/opt/podman/bin:/opt/podman/libexec/podman:\$PATH
EOF
echo "/opt/podman/lib" > "${DESTDIR}/etc/ld.so.conf.d/podman.conf"

popd >/dev/null
echo "Build completed."
