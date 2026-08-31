#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
revision=$(git -C "${repo_root}" rev-parse --short HEAD)
image="zzz-im-server:${revision}"
container="zzz-im-server"
env_file="/etc/zzz-im/server.env"
data_dir="/var/lib/zzz-im"

install -d -m 0700 /etc/zzz-im
install -d -m 0750 -o 10001 -g 10001 "${data_dir}" "${data_dir}/media"

docker build -t "${image}" "${repo_root}/server"

if [[ ! -s ${env_file} ]]; then
  umask 077
  {
    docker run --rm --entrypoint /usr/local/bin/zzz-im-vapid "${image}"
    echo "ZZZ_VAPID_SUBJECT=mailto:admin@icrad.ltd"
    echo "ZZZ_ACCESS_TOKEN=$(openssl rand -hex 32)"
  } >"${env_file}"
  echo "Generated ${env_file}; keep it private and backed up."
fi

docker rm -f "${container}" >/dev/null 2>&1 || true
docker run -d \
  --name "${container}" \
  --restart unless-stopped \
  --read-only \
  --tmpfs /tmp:size=16m,mode=1777 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --memory 384m \
  --cpus 1.0 \
  --log-opt max-size=10m \
  --log-opt max-file=3 \
  --publish 127.0.0.1:18080:8080 \
  --env-file "${env_file}" \
  --volume "${data_dir}:/data" \
  "${image}" >/dev/null

for _ in {1..20}; do
  if curl --fail --silent http://127.0.0.1:18080/health >/dev/null; then
    echo "ZZZ IM server ${revision} is healthy on 127.0.0.1:18080."
    exit 0
  fi
  sleep 1
done

docker logs --tail 100 "${container}" >&2
exit 1
