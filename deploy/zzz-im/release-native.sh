#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Build and deploy the native ZZZ IM services from the local workstation.

Usage:
  ./deploy/zzz-im/release-native.sh build
  ./deploy/zzz-im/release-native.sh deploy user@host

Commands:
  build   Test, build, and smoke-test Linux x86_64 artifacts locally.
  deploy  Run build, upload artifacts only, then install them remotely.
  push    Alias for deploy.

Environment:
  ZZZ_MUSL_CC        x86_64 musl C compiler (auto-detected by default)
  ZZZ_OUTPUT_DIR     Artifact directory (default: <repo>/dist)
  ZZZ_DEPLOY_TARGET  SSH target used when deploy has no positional target
  ZZZ_RELEASE_BRANCH Remote branch required for deploy (default: master)
  ZZZ_SKIP_TESTS=1   Skip local Go and asset checks
  ZZZ_SKIP_CI_CHECK=1
                     Skip the successful GitHub Actions check
  ZZZ_SMOKE_IMAGE    Linux smoke-test image (default: alpine:3.22)

Production hosts receive binaries, checksums, service units, and installer
scripts only. Source code is never uploaded or compiled on the server.
USAGE
}

log() {
  printf '[native-release] %s\n' "$*"
}

die() {
  printf '[native-release] error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
output_dir=${ZZZ_OUTPUT_DIR:-${repo_root}/dist}
smoke_image=${ZZZ_SMOKE_IMAGE:-alpine:3.22}
release_branch=${ZZZ_RELEASE_BRANCH:-master}
action=${1:-build}
target=${2:-${ZZZ_DEPLOY_TARGET:-}}

case ${action} in
  build)
    [[ $# -le 1 ]] || die "build does not accept an SSH target"
    ;;
  deploy | push)
    [[ $# -le 2 ]] || die "too many arguments"
    [[ -n ${target} ]] || die "deploy requires user@host or ZZZ_DEPLOY_TARGET"
    [[ ${target} != -* && ${target} != *[[:space:]]* ]] || die "invalid SSH target"
    ;;
  -h | --help | help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    die "unknown command: ${action}"
    ;;
esac

require_command git
require_command go
require_command file
require_command shasum
require_command docker

release_sha=$(git -C "${repo_root}" rev-parse HEAD)
release_id=${release_sha:0:12}
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/zzz-native-release.XXXXXX")
artifact_dir=${work_dir}/artifacts
package_root=${work_dir}/package
checkout_root=${work_dir}/checkout
release_server_root=${checkout_root}/server

cleanup() {
  rm -rf -- "${work_dir}"
}
trap cleanup EXIT

resolve_musl_compiler() {
  if [[ -n ${ZZZ_MUSL_CC:-} ]]; then
    command -v "${ZZZ_MUSL_CC}" || return 1
    return
  fi
  local candidate
  for candidate in x86_64-linux-musl-gcc x86_64-unknown-linux-musl-gcc; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      command -v "${candidate}"
      return
    fi
  done
  return 1
}

prepare_release_checkout() {
  log "Checking out committed release ${release_id} in a temporary workspace."
  git clone --quiet --shared --no-checkout "${repo_root}" "${checkout_root}"
  git -C "${checkout_root}" checkout --quiet --detach "${release_sha}"
}

run_local_checks() {
  if [[ ${ZZZ_SKIP_TESTS:-0} == 1 ]]; then
    log 'Local tests skipped by ZZZ_SKIP_TESTS=1.'
    return
  fi
  log 'Running Go tests and vet.'
  (
    cd "${release_server_root}"
    go test ./...
    go vet ./...
  )
  require_command node
  node --check "${release_server_root}/internal/admin/assets/app.js"
  bash -n \
    "${repo_root}/deploy/zzz-im/deploy-native.sh" \
    "${repo_root}/deploy/zzz-im/deploy-fairy-native.sh"
}

verify_artifact() {
  local path=$1
  local description
  description=$(file -b "${path}")
  case ${description} in
    *'ELF 64-bit LSB executable'*'x86-64'*'statically linked'*) ;;
    *) die "unexpected artifact format for ${path}: ${description}" ;;
  esac
}

build_artifacts() {
  local musl_cc
  musl_cc=$(resolve_musl_compiler) || die \
    'x86_64 musl compiler not found; install musl-cross or set ZZZ_MUSL_CC'
  mkdir -p "${artifact_dir}"
  log "Building Linux x86_64 server with CGO using ${musl_cc}."
  (
    cd "${release_server_root}"
    env CGO_ENABLED=1 GOOS=linux GOARCH=amd64 CC="${musl_cc}" \
      go build -trimpath \
      -ldflags='-s -w -linkmode external -extldflags "-static"' \
      -o "${artifact_dir}/zzz-im-server-linux-amd64" ./cmd/server
    env CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
      go build -trimpath -ldflags='-s -w' \
      -o "${artifact_dir}/zzz-im-vapid-linux-amd64" ./cmd/vapid
    env CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
      go build -trimpath -ldflags='-s -w' \
      -o "${artifact_dir}/zzz-im-fairy-linux-amd64" ./cmd/fairy
  )
  verify_artifact "${artifact_dir}/zzz-im-server-linux-amd64"
  verify_artifact "${artifact_dir}/zzz-im-vapid-linux-amd64"
  verify_artifact "${artifact_dir}/zzz-im-fairy-linux-amd64"
  (
    cd "${artifact_dir}"
    shasum -a 256 \
      zzz-im-server-linux-amd64 \
      zzz-im-vapid-linux-amd64 \
      zzz-im-fairy-linux-amd64 >SHA256SUMS
  )
}

smoke_test_sqlite() {
  docker version >/dev/null 2>&1 || die 'Docker is required for Linux SQLite smoke testing'
  log 'Starting the Linux x86_64 server with a temporary SQLite database.'
  local smoke_container
  smoke_container=$(docker create --platform linux/amd64 \
    "${smoke_image}" /bin/sh -ec '
      mkdir -p /tmp/media
      /release/zzz-im-server-linux-amd64 \
        -addr 127.0.0.1:18080 \
        -driver sqlite \
        -dsn /tmp/zzz-smoke.db \
        -media-dir /tmp/media >/tmp/zzz-smoke.log 2>&1 &
      server_pid=$!
      trap '\''kill "${server_pid}" >/dev/null 2>&1 || true'\'' EXIT
      ready=0
      for attempt in $(seq 1 20); do
        if wget -q -O /tmp/health http://127.0.0.1:18080/health 2>/dev/null && grep -qx ok /tmp/health; then
          ready=1
          break
        fi
        if ! kill -0 "${server_pid}" >/dev/null 2>&1; then
          cat /tmp/zzz-smoke.log >&2
          exit 1
        fi
        sleep 1
      done
      if [ "${ready}" -ne 1 ]; then
        cat /tmp/zzz-smoke.log >&2
        exit 1
      fi
      test -s /tmp/zzz-smoke.db
      /release/zzz-im-vapid-linux-amd64 >/tmp/vapid.env
      grep -q "^ZZZ_VAPID_PUBLIC_KEY=" /tmp/vapid.env
      grep -q "^ZZZ_VAPID_PRIVATE_KEY=" /tmp/vapid.env
    ')
  if ! docker cp "${artifact_dir}/." "${smoke_container}:/release"; then
    docker rm --force "${smoke_container}" >/dev/null 2>&1 || true
    die 'could not copy artifacts into the Linux smoke-test container'
  fi
  if ! docker start --attach "${smoke_container}"; then
    docker rm --force "${smoke_container}" >/dev/null 2>&1 || true
    die 'Linux x86_64 SQLite smoke test failed'
  fi
  docker rm "${smoke_container}" >/dev/null
}

publish_artifacts() {
  install -d "${output_dir}"
  install -m 0755 \
    "${artifact_dir}/zzz-im-server-linux-amd64" \
    "${output_dir}/zzz-im-server-linux-amd64"
  install -m 0755 \
    "${artifact_dir}/zzz-im-vapid-linux-amd64" \
    "${output_dir}/zzz-im-vapid-linux-amd64"
  install -m 0755 \
    "${artifact_dir}/zzz-im-fairy-linux-amd64" \
    "${output_dir}/zzz-im-fairy-linux-amd64"
  install -m 0644 "${artifact_dir}/SHA256SUMS" "${output_dir}/SHA256SUMS"
  log "Artifacts published to ${output_dir}."
}

github_slug() {
  local remote_url
  remote_url=$(git -C "${repo_root}" remote get-url origin)
  case ${remote_url} in
    https://github.com/*)
      remote_url=${remote_url#https://github.com/}
      ;;
    git@github.com:*)
      remote_url=${remote_url#git@github.com:}
      ;;
    ssh://git@github.com/*)
      remote_url=${remote_url#ssh://git@github.com/}
      ;;
    *) return 1 ;;
  esac
  printf '%s\n' "${remote_url%.git}"
}

ensure_deployable_commit() {
  local changes remote_sha slug workflow_runs
  changes=$(git -C "${repo_root}" status --porcelain --untracked-files=all -- \
    server deploy/zzz-im .github/workflows/deploy-pages.yml)
  [[ -z ${changes} ]] || die \
    'server or native deployment files are not committed; deploy only traceable commits'
  remote_sha=$(git -C "${repo_root}" ls-remote origin "refs/heads/${release_branch}" | awk 'NR == 1 {print $1}')
  [[ ${remote_sha} == "${release_sha}" ]] || die \
    "HEAD ${release_id} is not origin/${release_branch}; push it before deploy"
  if [[ ${ZZZ_SKIP_CI_CHECK:-0} == 1 ]]; then
    log 'GitHub Actions check skipped by ZZZ_SKIP_CI_CHECK=1.'
    return
  fi
  require_command curl
  require_command jq
  slug=$(github_slug) || die 'origin is not a supported GitHub URL'
  workflow_runs=$(curl --fail --silent --show-error \
    "https://api.github.com/repos/${slug}/actions/runs?head_sha=${release_sha}&per_page=10")
  jq -e --arg sha "${release_sha}" '
    any(.workflow_runs[];
      .head_sha == $sha and
      .name == "CI/CD" and
      .status == "completed" and
      .conclusion == "success")
  ' <<<"${workflow_runs}" >/dev/null || die \
    "CI/CD has not succeeded for ${release_id}"
}

prepare_package() {
  mkdir -p "${package_root}/dist" "${package_root}/deploy/zzz-im"
  install -m 0755 \
    "${artifact_dir}/zzz-im-server-linux-amd64" \
    "${package_root}/dist/zzz-im-server-linux-amd64"
  install -m 0755 \
    "${artifact_dir}/zzz-im-vapid-linux-amd64" \
    "${package_root}/dist/zzz-im-vapid-linux-amd64"
  install -m 0755 \
    "${artifact_dir}/zzz-im-fairy-linux-amd64" \
    "${package_root}/dist/zzz-im-fairy-linux-amd64"
  install -m 0755 \
    "${repo_root}/deploy/zzz-im/deploy-native.sh" \
    "${package_root}/deploy/zzz-im/deploy-native.sh"
  install -m 0755 \
    "${repo_root}/deploy/zzz-im/deploy-fairy-native.sh" \
    "${package_root}/deploy/zzz-im/deploy-fairy-native.sh"
  install -m 0644 \
    "${repo_root}/deploy/zzz-im/zzz-im.service" \
    "${package_root}/deploy/zzz-im/zzz-im.service"
  install -m 0644 \
    "${repo_root}/deploy/zzz-im/zzz-fairy.service" \
    "${package_root}/deploy/zzz-im/zzz-fairy.service"
  (
    cd "${package_root}"
    shasum -a 256 \
      dist/zzz-im-server-linux-amd64 \
      dist/zzz-im-vapid-linux-amd64 \
      dist/zzz-im-fairy-linux-amd64 \
      deploy/zzz-im/deploy-native.sh \
      deploy/zzz-im/deploy-fairy-native.sh \
      deploy/zzz-im/zzz-im.service \
      deploy/zzz-im/zzz-fairy.service >SHA256SUMS
  )
}

deploy_artifacts() {
  require_command ssh
  require_command scp
  prepare_package
  log "Creating remote staging directory on ${target}."
  local remote_stage
  remote_stage=$(ssh -o BatchMode=yes "${target}" \
    'mktemp -d /tmp/zzz-im-release.XXXXXX')
  [[ ${remote_stage} =~ ^/tmp/zzz-im-release\.[A-Za-z0-9]+$ ]] || \
    die "unsafe remote staging path: ${remote_stage}"
  ssh -o BatchMode=yes "${target}" \
    "install -d -m 0700 '${remote_stage}/repo'"
  scp -q -r "${package_root}/." "${target}:${remote_stage}/repo/"
  log 'Artifacts uploaded; starting remote install with rollback protection.'
  if ! ssh -o BatchMode=yes "${target}" bash -s -- \
    "${remote_stage}/repo" "${release_id}" <<'REMOTE'
set -Eeuo pipefail

package_root=$1
release_id=$2

fail() {
  printf '[native-install] error: %s\n' "$*" >&2
  exit 1
}

for command_name in sha256sum systemctl curl grep openssl; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "missing ${command_name}"
done
[[ $(uname -m) == x86_64 ]] || fail 'production host is not x86_64'
[[ ${package_root} == /tmp/zzz-im-release.*/repo ]] || fail 'unsafe package path'
[[ ${release_id} =~ ^[0-9a-f]{12}$ ]] || fail 'invalid release id'

(
  cd "${package_root}"
  sha256sum --check SHA256SUMS
)

backup_dir=/var/backups/zzz-im/${release_id}-$(date +%Y%m%d%H%M%S)
install -d -m 0700 "${backup_dir}"
for source_path in \
  /usr/local/bin/zzz-im-server \
  /usr/local/bin/zzz-im-vapid \
  /usr/local/bin/zzz-im-fairy \
  /etc/zzz-im/server.env \
  /etc/zzz-im/fairy.env \
  /etc/systemd/system/zzz-im.service \
  /etc/systemd/system/zzz-fairy.service; do
  [[ -e ${source_path} ]] || fail "production prerequisite missing: ${source_path}"
  cp -a "${source_path}" "${backup_dir}/$(basename "${source_path}")"
done

success=0
rollback() {
  status=$?
  trap - ERR
  if [[ ${success} -eq 0 ]]; then
    printf '[native-install] restoring %s\n' "${backup_dir}" >&2
    install -m 0755 "${backup_dir}/zzz-im-server" /usr/local/bin/zzz-im-server.rollback
    install -m 0755 "${backup_dir}/zzz-im-vapid" /usr/local/bin/zzz-im-vapid.rollback
    install -m 0755 "${backup_dir}/zzz-im-fairy" /usr/local/bin/zzz-im-fairy.rollback
    mv -f /usr/local/bin/zzz-im-server.rollback /usr/local/bin/zzz-im-server
    mv -f /usr/local/bin/zzz-im-vapid.rollback /usr/local/bin/zzz-im-vapid
    mv -f /usr/local/bin/zzz-im-fairy.rollback /usr/local/bin/zzz-im-fairy
    install -m 0600 "${backup_dir}/server.env" /etc/zzz-im/server.env
    install -m 0600 "${backup_dir}/fairy.env" /etc/zzz-im/fairy.env
    install -m 0644 "${backup_dir}/zzz-im.service" /etc/systemd/system/zzz-im.service
    install -m 0644 "${backup_dir}/zzz-fairy.service" /etc/systemd/system/zzz-fairy.service
    systemctl daemon-reload || true
    systemctl restart zzz-im.service || true
    systemctl restart zzz-fairy.service || true
  fi
  exit "${status}"
}
trap rollback ERR

ZZZ_SERVER_BINARY=${package_root}/dist/zzz-im-server-linux-amd64 \
ZZZ_VAPID_BINARY=${package_root}/dist/zzz-im-vapid-linux-amd64 \
  "${package_root}/deploy/zzz-im/deploy-native.sh"
ZZZ_FAIRY_BINARY=${package_root}/dist/zzz-im-fairy-linux-amd64 \
  "${package_root}/deploy/zzz-im/deploy-fairy-native.sh"

cmp --silent \
  "${package_root}/dist/zzz-im-server-linux-amd64" \
  /usr/local/bin/zzz-im-server
cmp --silent \
  "${package_root}/dist/zzz-im-fairy-linux-amd64" \
  /usr/local/bin/zzz-im-fairy
curl --fail --silent http://127.0.0.1:18080/admin/ | \
  grep -q 'id="view-fairy"'
fairy_token=$(sed -n 's/^FAIRY_ADMIN_TOKEN=//p' /etc/zzz-im/fairy.env | head -n 1)
[[ -n ${fairy_token} ]]
fairy_payload=$(curl --fail --silent --show-error \
  -H "Authorization: Bearer ${fairy_token}" \
  http://127.0.0.1:18081/admin/config)
grep -Fq '"connected":true' <<<"${fairy_payload}"
! grep -Fq '"model_api_key":' <<<"${fairy_payload}"
grep -Fq '"id":"zzz-profile"' <<<"${fairy_payload}"
[[ $(systemctl is-active zzz-im.service) == active ]]
[[ $(systemctl is-active zzz-fairy.service) == active ]]

success=1
trap - ERR
printf '[native-install] release %s active; backup %s\n' \
  "${release_id}" "${backup_dir}"
REMOTE
  then
    log "Remote install failed; staging retained at ${target}:${remote_stage}."
    return 1
  fi
  ssh -o BatchMode=yes "${target}" "rm -rf -- '${remote_stage}'"
  log "Release ${release_id} deployed to ${target}."
}

if [[ ${action} == deploy || ${action} == push ]]; then
  ensure_deployable_commit
fi

prepare_release_checkout
run_local_checks
build_artifacts
smoke_test_sqlite
publish_artifacts

if [[ ${action} == deploy || ${action} == push ]]; then
  deploy_artifacts
fi

log "Release ${release_id} complete."
