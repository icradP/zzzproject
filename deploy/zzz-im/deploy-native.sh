#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
server_binary=${ZZZ_SERVER_BINARY:-${repo_root}/dist/zzz-im-server-linux-amd64}
vapid_binary=${ZZZ_VAPID_BINARY:-${repo_root}/dist/zzz-im-vapid-linux-amd64}
env_file=/etc/zzz-im/server.env
data_dir=/var/lib/zzz-im

if [[ ! -x ${server_binary} || ! -x ${vapid_binary} ]]; then
  echo "Linux amd64 server and VAPID binaries are required." >&2
  exit 1
fi

if ! id zzz-im >/dev/null 2>&1; then
  useradd --system --home-dir "${data_dir}" --shell /usr/sbin/nologin zzz-im
fi

install -d -m 0700 /etc/zzz-im
install -d -m 0750 -o zzz-im -g zzz-im "${data_dir}" "${data_dir}/media"
install -m 0755 "${server_binary}" /usr/local/bin/zzz-im-server
install -m 0755 "${vapid_binary}" /usr/local/bin/zzz-im-vapid

if [[ ! -s ${env_file} ]]; then
  umask 077
  {
    /usr/local/bin/zzz-im-vapid
    echo "ZZZ_VAPID_SUBJECT=mailto:admin@icrad.ltd"
    echo "ZZZ_ACCESS_TOKEN=$(openssl rand -hex 32)"
    echo "ZZZ_ADMIN_TOKEN=$(openssl rand -hex 32)"
    echo "ZZZ_ADMIN_PUBLIC_PATH=/im/admin"
    echo "ZZZ_FAIRY_ADMIN_URL=http://127.0.0.1:18081/admin"
    echo "ZZZ_FAIRY_ADMIN_TOKEN=$(openssl rand -hex 32)"
    echo "ZZZ_INVITE_CODE=diaogan"
  } >"${env_file}"
  echo "Generated ${env_file}; keep it private and backed up."
fi

if ! grep -q '^ZZZ_ADMIN_TOKEN=' "${env_file}"; then
  umask 077
  echo "ZZZ_ADMIN_TOKEN=$(openssl rand -hex 32)" >>"${env_file}"
fi
if ! grep -q '^ZZZ_ADMIN_PUBLIC_PATH=' "${env_file}"; then
  umask 077
  echo "ZZZ_ADMIN_PUBLIC_PATH=/im/admin" >>"${env_file}"
fi
if ! grep -q '^ZZZ_FAIRY_ADMIN_URL=' "${env_file}"; then
  umask 077
  echo "ZZZ_FAIRY_ADMIN_URL=http://127.0.0.1:18081/admin" >>"${env_file}"
fi
if ! grep -q '^ZZZ_FAIRY_ADMIN_TOKEN=' "${env_file}"; then
  umask 077
  echo "ZZZ_FAIRY_ADMIN_TOKEN=$(openssl rand -hex 32)" >>"${env_file}"
fi

install -m 0644 "${repo_root}/deploy/zzz-im/zzz-im.service" /etc/systemd/system/zzz-im.service
systemctl daemon-reload
systemctl enable zzz-im.service
systemctl restart zzz-im.service

for _ in {1..20}; do
  if curl --fail --silent http://127.0.0.1:18080/health >/dev/null; then
    echo "ZZZ IM server is healthy on 127.0.0.1:18080."
    exit 0
  fi
  sleep 1
done

journalctl --unit zzz-im.service --no-pager --lines 100 >&2
exit 1
