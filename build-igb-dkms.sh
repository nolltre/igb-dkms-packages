#!/usr/bin/env bash
set -eo pipefail

# Check our dependencies
for cmd in curl tar fpm dkms jq; do
  if ! command -v "$cmd" >/dev/null; then
    echo "Missing dependency: $cmd"
    exit 1
  fi
done

# Check if we want the git version
if [ -n "$1" -a "$1" = "git" ]; then
  URL="https://github.com/intel/ethernet-linux-igb/archive/refs/heads/main.zip"
  TARBALL=$(basename "${URL}")
  VERSION=git
else
  LATEST_RELEASE=$(curl -s https://api.github.com/repos/intel/ethernet-linux-igb/releases/latest)
  VERSION=$(echo "${LATEST_RELEASE}" | jq -r .tag_name | tr -d v)
  URL=$(echo "${LATEST_RELEASE}" | jq -r '.assets[].browser_download_url')
  TARBALL=$(echo "${LATEST_RELEASE}" | jq -r '.assets[].name')
fi

set -u

# Variables
NAME="igb"
ARCHITECTURE="amd64"

WORKDIR="$(mktemp -d)/build-${NAME}-${VERSION}"
BUILDDIR="$(pwd)/build-${NAME}-${VERSION}"
PKGROOT="${WORKDIR}/pkgroot"
SRCDIR="${PKGROOT}/usr/src/${NAME}-${VERSION}"
SCRIPTDIR="${WORKDIR}/scripts"

# Setup
mkdir -p "${SRCDIR}" "${SCRIPTDIR}"

pushd "${WORKDIR}" >/dev/null

# Download tarball
echo "Downloading ${URL}..."
curl --silent -L -o "${TARBALL}" "${URL}"

# Extract
echo "Extracting..."
case "${TARBALL}" in
*.zip)
  SRCDIR=$(mktemp -d)
  unzip "${TARBALL}" -d "${SRCDIR}"
  VERSION=$(cd "${SRCDIR}/ethernet-linux-igb-main" && grep "Version: " igb.spec | sed 's/Version: \(.*\)/\1/')
  OLD_SRC_DIR="${SRCDIR}/ethernet-linux-igb-main"
  export VERSION
  SRCDIR="${PKGROOT}/usr/src/${NAME}-${VERSION}"
  mkdir -p "${SRCDIR}"
  mv "${OLD_SRC_DIR}/"* "${SRCDIR}"
  rmdir "${OLD_SRC_DIR}"
  rmdir "${PKGROOT}/usr/src/${NAME}-git"
  ;;
*.tar.gz)
  tar -xzf "${TARBALL}" --strip-components=1 -C "${SRCDIR}"
  ;;
esac

# DKMS config
echo "Creating dkms.conf..."
cat >"${SRCDIR}/dkms.conf" <<EOF
PACKAGE_NAME="${NAME}"
PACKAGE_VERSION="${VERSION}"

BUILT_MODULE_NAME[0]="${NAME}"
BUILT_MODULE_LOCATION[0]="src"
DEST_MODULE_LOCATION[0]="/updates/dkms"

AUTOINSTALL="yes"

MAKE[0]="make -C \${kernel_source_dir} KVERSION=\$kernelver BUILD_KERNEL=\$kernelver M=/var/lib/dkms/\${PACKAGE_NAME}/\${PACKAGE_VERSION}/build/src modules"
CLEAN="make -C src clean"
EOF

# postinst
cat >"${SCRIPTDIR}/postinst" <<EOF
#!/bin/bash
set -e

dkms add -m ${NAME} -v ${VERSION} 2>/dev/null || true
dkms build -m ${NAME} -v ${VERSION}
dkms install -m ${NAME} -v ${VERSION}

exit 0
EOF

chmod +x "${SCRIPTDIR}/postinst"

# prerm
cat >"${SCRIPTDIR}/prerm" <<EOF
#!/bin/bash
set -e

dkms remove -m ${NAME} -v ${VERSION} --all 2>/dev/null || true
make -C /usr/src/${NAME}-${VERSION}/src clean || true
rm -f /usr/src/${NAME}-${VERSION}/src/kcompat_generated_defs.h || true

exit 0
EOF

chmod +x "${SCRIPTDIR}/prerm"

# Build package
echo "Building Debian package..."

fpm -s dir -t deb \
  -n ${NAME}-dkms \
  -v ${VERSION} \
  --description "Intel igb network driver (DKMS)" \
  --license "GPLv2" \
  --depends dkms \
  --depends build-essential \
  --depends linux-headers-${ARCHITECTURE} \
  --architecture ${ARCHITECTURE} \
  --after-install "${SCRIPTDIR}/postinst" \
  --before-remove "${SCRIPTDIR}/prerm" \
  -C "${PKGROOT}" \
  .

echo "Move the artifact to the build directory"
mkdir -p "${BUILDDIR}"
mv "${WORKDIR}/${NAME}-dkms_${VERSION}_${ARCHITECTURE}.deb" "${BUILDDIR}"
popd >/dev/null
echo "Removing temporary directory..."
rm -rf "${WORKDIR}"

echo ""
echo "Package built:"
cd "${BUILDDIR}"
ls -1 *.deb
