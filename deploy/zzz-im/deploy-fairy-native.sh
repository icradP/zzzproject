#!/usr/bin/env bash
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this script as root." >&2
  exit 1
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fairy_binary=${ZZZ_FAIRY_BINARY:-${repo_root}/dist/zzz-im-fairy-linux-amd64}
env_file=/etc/zzz-im/fairy.env
server_env=/etc/zzz-im/server.env
data_dir=/var/lib/zzz-fairy

if [[ ! -x ${fairy_binary} ]]; then
  echo "Linux amd64 Fairy binary is required: ${fairy_binary}" >&2
  exit 1
fi
if [[ ! -s ${server_env} ]]; then
  echo "ZZZ IM server environment is required first: ${server_env}" >&2
  exit 1
fi
if ! id zzz-fairy >/dev/null 2>&1; then
  useradd --system --home-dir "${data_dir}" --shell /usr/sbin/nologin zzz-fairy
fi

install -d -m 0700 /etc/zzz-im
install -d -m 0750 -o zzz-fairy -g zzz-fairy "${data_dir}"
install -m 0755 "${fairy_binary}" /usr/local/bin/zzz-im-fairy.next
mv -f /usr/local/bin/zzz-im-fairy.next /usr/local/bin/zzz-im-fairy

admin_token=$(sed -n 's/^ZZZ_FAIRY_ADMIN_TOKEN=//p' "${server_env}" | head -n 1)
if [[ -z ${admin_token} ]]; then
  echo "ZZZ_FAIRY_ADMIN_TOKEN is required in ${server_env}." >&2
  exit 1
fi

if [[ ! -s ${env_file} ]]; then
  invite_code=$(sed -n 's/^ZZZ_INVITE_CODE=//p' "${server_env}" | head -n 1)
  if [[ -z ${invite_code} ]]; then
    echo "ZZZ_INVITE_CODE is required to provision the Fairy account." >&2
    exit 1
  fi
  umask 077
  {
    echo "FAIRY_SERVER_URL=ws://127.0.0.1:18080/ws"
    echo "FAIRY_USER_ID=fairy"
    echo "FAIRY_PASSWORD=$(openssl rand -hex 24)"
    echo "FAIRY_INVITE_CODE=${invite_code}"
    echo "FAIRY_NICKNAME=Fairy"
    echo "FAIRY_AVATAR_URL=https://icrad.ltd/assets/assets/characters/temp/Fairy.png"
    echo "FAIRY_BIO=ZZZ IM 智能助手。私聊直接提问，群聊请先 @Fairy。"
    echo "FAIRY_STATE_FILE=${data_dir}/state.json"
    echo "FAIRY_CONFIG_FILE=${data_dir}/config.json"
    echo "FAIRY_TRACE_DB=${data_dir}/fairy.db"
    echo "FAIRY_FACT_DB=${data_dir}/facts.db"
    echo "FAIRY_TRACE_KEY_FILE=${data_dir}/trace.key"
    echo "FAIRY_ZZZ_ACCOUNT_DB=${data_dir}/zzz-accounts.db"
    echo "FAIRY_ZZZ_CREDENTIAL_KEY_FILE=${data_dir}/zzz-credentials.key"
    echo "FAIRY_HEALTH_ADDR=127.0.0.1:18081"
    echo "FAIRY_ADMIN_TOKEN=${admin_token}"
    echo "FAIRY_GROUP_DEFAULT_ENABLED=true"
    echo "FAIRY_AI_ROLLOUT_MODE=off"
    echo "FAIRY_MODEL_DAILY_LIMIT=200"
    echo "FAIRY_CONTEXT_TTL=30m"
    echo "FAIRY_CONTEXT_MESSAGES=12"
  } >"${env_file}"
  echo "Generated ${env_file}; add model settings there when a provider is selected."
fi

if ! grep -q '^FAIRY_CONFIG_FILE=' "${env_file}"; then
  umask 077
  echo "FAIRY_CONFIG_FILE=${data_dir}/config.json" >>"${env_file}"
fi
if ! grep -q '^FAIRY_TRACE_DB=' "${env_file}"; then
  umask 077
  echo "FAIRY_TRACE_DB=${data_dir}/fairy.db" >>"${env_file}"
fi
if ! grep -q '^FAIRY_TRACE_KEY_FILE=' "${env_file}"; then
  umask 077
  echo "FAIRY_TRACE_KEY_FILE=${data_dir}/trace.key" >>"${env_file}"
fi
if ! grep -q '^FAIRY_FACT_DB=' "${env_file}"; then
  umask 077
  echo "FAIRY_FACT_DB=${data_dir}/facts.db" >>"${env_file}"
fi
if ! grep -q '^FAIRY_ZZZ_ACCOUNT_DB=' "${env_file}"; then
  umask 077
  echo "FAIRY_ZZZ_ACCOUNT_DB=${data_dir}/zzz-accounts.db" >>"${env_file}"
fi
if ! grep -q '^FAIRY_ZZZ_CREDENTIAL_KEY_FILE=' "${env_file}"; then
  umask 077
  echo "FAIRY_ZZZ_CREDENTIAL_KEY_FILE=${data_dir}/zzz-credentials.key" >>"${env_file}"
fi
if ! grep -q '^FAIRY_ADMIN_TOKEN=' "${env_file}"; then
  umask 077
  echo "FAIRY_ADMIN_TOKEN=${admin_token}" >>"${env_file}"
elif [[ $(sed -n 's/^FAIRY_ADMIN_TOKEN=//p' "${env_file}" | head -n 1) != "${admin_token}" ]]; then
  echo "Fairy and server admin tokens do not match; reconcile ${env_file} and ${server_env}." >&2
  exit 1
fi

install -m 0644 "${repo_root}/deploy/zzz-im/zzz-fairy.service" /etc/systemd/system/zzz-fairy.service
systemctl daemon-reload
systemctl enable zzz-fairy.service
systemctl restart zzz-fairy.service

for _ in {1..30}; do
  if curl --fail --silent http://127.0.0.1:18081/ready >/dev/null; then
    echo "Fairy is connected to ZZZ IM and ready on 127.0.0.1:18081."
    exit 0
  fi
  sleep 1
done

journalctl --unit zzz-fairy.service --no-pager --lines 100 >&2
exit 1
