#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi

archive=${1:-}
release=${2:-}
site_root=/srv/www/zzz-im
release_dir=${site_root}/releases/${release}

if [[ ! -f ${archive} ]]; then
  echo "Usage: $0 <pwa-archive.tar.gz> <release-id>" >&2
  exit 1
fi
if [[ ! ${release} =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Release ID may contain only letters, digits, dots, underscores, and hyphens." >&2
  exit 1
fi
if [[ -e ${release_dir} ]]; then
  echo "Release already exists: ${release_dir}" >&2
  exit 1
fi

install -d -m 0755 "${site_root}/releases"
install -d -m 0755 "${release_dir}"
tar -xzf "${archive}" -C "${release_dir}" --no-same-owner

if [[ ! -f ${release_dir}/index.html ||
      ! -f ${release_dir}/manifest.json ||
      ! -f ${release_dir}/app-sw.js ||
      ! -f ${release_dir}/canvaskit/canvaskit.wasm ]]; then
  echo "Archive does not contain a Flutter PWA build." >&2
  exit 1
fi
if ! grep -Fq 'canvasKitBaseUrl: "canvaskit/"' "${release_dir}/flutter_bootstrap.js"; then
  echo "Flutter PWA is not configured to use local CanvasKit assets." >&2
  exit 1
fi

find "${release_dir}" -type f \
  \( -name '*.js' -o -name '*.css' -o -name '*.json' -o \
     -name '*.wasm' -o -name '*.ttf' -o -name '*.otf' -o \
     -name '*.svg' \) \
  -size +1024c -exec gzip -9 -k -f {} +

chmod -R a=rX,u+w "${release_dir}"
ln -s "releases/${release}" "${site_root}/.current-${release}"
mv -Tf "${site_root}/.current-${release}" "${site_root}/current"

echo "Activated PWA release ${release} at ${site_root}/current."
