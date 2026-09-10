#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Build and deploy the ZZZ IM PWA from the local workstation.

Usage:
  ./deploy/zzz-im/release-pwa.sh validate
  ./deploy/zzz-im/release-pwa.sh build
  ./deploy/zzz-im/release-pwa.sh deploy user@host

Commands:
  validate
          Test and package the current worktree without publishing.
  build   Test, package, and keep the PWA archive locally.
  deploy  Run build, upload the archive only, then activate it remotely.
  push    Alias for deploy.

Environment:
  ZZZ_PWA_OUTPUT_DIR Artifact directory
                     (default: /Volumes/ssd01/tmp/codex/zzz-pwa-release/artifacts)
  ZZZ_TMP_ROOT       Writable local temporary root (default: /Volumes/ssd01/tmp/codex)
  ZZZ_DEPLOY_TARGET  SSH target used when deploy has no positional target
  ZZZ_RELEASE_BRANCH Remote branch required for deploy (default: master)
  ZZZ_PWA_RELEASE_ID Remote release directory name (default: 12-char HEAD)
  ZZZ_PWA_BASE_HREF  Production base href (default: /)
  ZZZ_SERVER_URL     Flutter dart-define for the IM websocket
                     (default: wss://icrad.ltd/im/ws)
  ZZZ_SKIP_TESTS=1   Skip local Flutter/JavaScript checks
  ZZZ_SKIP_CI_CHECK=1
                     Skip the successful GitHub Actions check

Each PWA build stamps What's New from assets/data/im_release_notes.json.
Production deploys prepend this build's user-facing git subjects and use
pubspec version plus the release id as the dismiss key, so the prompt
appears once per deploy. The generated Dart file is restored afterwards.

Production hosts receive the PWA archive, checksums, and installer script
only. Flutter is never run on the server.
USAGE
}

log() {
  printf '[pwa-release] %s\n' "$*"
}

die() {
  printf '[pwa-release] error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

pwa_input_paths=(
  lib
  web
  assets
  packages/onebot_flutter
  tool
  pubspec.yaml
  pubspec.lock
  deploy/zzz-im/deploy-pwa.sh
  deploy/zzz-im/release-pwa.sh
  deploy/zzz-im/release.sh
)

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp_root=${ZZZ_TMP_ROOT:-/Volumes/ssd01/tmp/codex}
output_dir=${ZZZ_PWA_OUTPUT_DIR:-${tmp_root}/zzz-pwa-release/artifacts}
release_branch=${ZZZ_RELEASE_BRANCH:-master}
base_href=${ZZZ_PWA_BASE_HREF:-/}
server_url=${ZZZ_SERVER_URL:-wss://icrad.ltd/im/ws}
action=${1:-build}
target=${2:-${ZZZ_DEPLOY_TARGET:-}}

case ${action} in
  validate | build)
    [[ $# -le 1 ]] || die "${action} does not accept an SSH target"
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
require_command flutter
require_command node
require_command tar
require_command shasum

[[ -d ${tmp_root} && -w ${tmp_root} ]] || die \
  "temporary root is not writable: ${tmp_root}"
if [[ ! ${base_href} =~ ^/[A-Za-z0-9._/-]*$ || ${base_href} != */ ]]; then
  die 'ZZZ_PWA_BASE_HREF must be an absolute path ending in /.'
fi
[[ ${server_url} == wss://* || ${server_url} == ws://* ]] || die \
  'ZZZ_SERVER_URL must be a ws:// or wss:// URL'

release_sha=$(git -C "${repo_root}" rev-parse HEAD)
release_id=${release_sha:0:12}
pwa_release_id=${ZZZ_PWA_RELEASE_ID:-${release_id}}
[[ ${pwa_release_id} =~ ^[A-Za-z0-9._-]+$ ]] || die 'invalid PWA release id'
work_dir=$(mktemp -d "${tmp_root}/zzz-pwa-release.XXXXXX")
web_dir=${work_dir}/web
artifact_dir=${work_dir}/artifacts
package_root=${work_dir}/package
notes_generated=${repo_root}/lib/src/im/data/im_release_notes.g.dart
notes_backup=${work_dir}/im_release_notes.g.dart.bak

cleanup() {
  if [[ -f ${notes_backup} ]]; then
    cp "${notes_backup}" "${notes_generated}"
  fi
  rm -rf -- "${work_dir}"
}
trap cleanup EXIT

pwa_changes() {
  git -C "${repo_root}" status --porcelain --untracked-files=all -- \
    "${pwa_input_paths[@]}"
}

prepare_release_checkout() {
  local changes
  changes=$(pwa_changes)
  [[ -z ${changes} ]] || die \
    'PWA or deploy-pwa inputs are not committed; commit them before build/deploy'
  log "Building committed PWA ${pwa_release_id} from the local worktree."
}

prepare_validation_worktree() {
  log "Validating the current worktree at ${release_id}; artifacts will not be published."
}

run_local_checks() {
  bash -n \
    "${repo_root}/deploy/zzz-im/deploy-pwa.sh" \
    "${repo_root}/deploy/zzz-im/release-pwa.sh"
  if [[ ${ZZZ_SKIP_TESTS:-0} == 1 ]]; then
    log 'Local tests skipped by ZZZ_SKIP_TESTS=1.'
    return
  fi
  log 'Running Flutter and PWA asset checks.'
  (
    cd "${repo_root}"
    flutter pub get
    flutter analyze --no-fatal-infos --no-fatal-warnings
    flutter test
    node --check web/app-sw.js
    node --check web/loading.js
    node --check web/push_client.js
    node --check web/push-sw.js
    node --check tool/generate_web_asset_manifest.mjs
    node --check tool/generate_release_notes.mjs
    node --test tool/*_test.*
    node tool/generate_release_notes.mjs --check
    node -e "JSON.parse(require('fs').readFileSync('web/manifest.json', 'utf8'))"
    node -e "JSON.parse(require('fs').readFileSync('assets/data/im_release_notes.json', 'utf8'))"
  )
}

stamp_release_notes() {
  [[ -f ${notes_generated} ]] || die "missing ${notes_generated}"
  cp "${notes_generated}" "${notes_backup}"
  log "Stamping What's New for PWA ${pwa_release_id}."
  node "${repo_root}/tool/generate_release_notes.mjs" \
    --root "${repo_root}" \
    --apply \
    --release-id "${pwa_release_id}"
}

build_archive() {
  mkdir -p "${web_dir}" "${artifact_dir}"
  stamp_release_notes
  log "Building Flutter PWA with base href ${base_href}."
  flutter --version
  (
    cd "${repo_root}"
    flutter build web --release \
      --base-href "${base_href}" \
      --no-web-resources-cdn \
      --no-wasm-dry-run \
      --output "${web_dir}" \
      --dart-define="ZZZ_SERVER_URL=${server_url}"
    node tool/generate_web_asset_manifest.mjs "${web_dir}"
  )
  node --check "${web_dir}/app-sw.js"
  node --check "${web_dir}/flutter_bootstrap.js"
  node --check "${web_dir}/loading.js"
  node -e "JSON.parse(require('fs').readFileSync('${web_dir}/startup-assets.json', 'utf8'))"
  grep -Fq 'canvasKitBaseUrl: "canvaskit/"' "${web_dir}/flutter_bootstrap.js" || \
    die 'Flutter PWA is not configured to use local CanvasKit assets.'
  grep -Fq "<base href=\"${base_href}\">" "${web_dir}/index.html" || \
    die "PWA base href is not ${base_href}."
  for required in index.html manifest.json app-sw.js loading.js \
    startup-assets.json canvaskit/canvaskit.wasm; do
    [[ -f ${web_dir}/${required} ]] || die "missing PWA file: ${required}"
  done
  COPYFILE_DISABLE=1 tar -czf "${artifact_dir}/zzz-pwa.tar.gz" -C "${web_dir}" .
  (
    cd "${artifact_dir}"
    shasum -a 256 zzz-pwa.tar.gz >SHA256SUMS
  )
  log "Packaged PWA archive $(wc -c <"${artifact_dir}/zzz-pwa.tar.gz" | tr -d ' ') bytes."
}

publish_artifacts() {
  install -d "${output_dir}"
  install -m 0644 "${artifact_dir}/zzz-pwa.tar.gz" \
    "${output_dir}/zzz-pwa-${pwa_release_id}.tar.gz"
  install -m 0644 "${artifact_dir}/SHA256SUMS" \
    "${output_dir}/SHA256SUMS"
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
  changes=$(pwa_changes)
  [[ -z ${changes} ]] || die \
    'PWA or deploy-pwa files are not committed; deploy only traceable commits'
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
  install -m 0644 \
    "${artifact_dir}/zzz-pwa.tar.gz" \
    "${package_root}/dist/zzz-pwa.tar.gz"
  install -m 0755 \
    "${repo_root}/deploy/zzz-im/deploy-pwa.sh" \
    "${package_root}/deploy/zzz-im/deploy-pwa.sh"
  (
    cd "${package_root}"
    shasum -a 256 \
      dist/zzz-pwa.tar.gz \
      deploy/zzz-im/deploy-pwa.sh >SHA256SUMS
  )
}

deploy_archive() {
  require_command ssh
  require_command scp
  prepare_package
  log "Creating remote staging directory on ${target}."
  local remote_stage
  remote_stage=$(ssh -o BatchMode=yes "${target}" \
    'mktemp -d /tmp/zzz-im-pwa.XXXXXX')
  [[ ${remote_stage} =~ ^/tmp/zzz-im-pwa\.[A-Za-z0-9]+$ ]] || \
    die "unsafe remote staging path: ${remote_stage}"
  ssh -o BatchMode=yes "${target}" \
    "install -d -m 0700 '${remote_stage}/repo'"
  scp -q -r "${package_root}/." "${target}:${remote_stage}/repo/"
  log 'Archive uploaded; activating the remote PWA release.'
  if ! ssh -o BatchMode=yes "${target}" \
    env ZZZ_PWA_BASE_HREF="${base_href}" bash -s -- \
    "${remote_stage}/repo" "${pwa_release_id}" <<'REMOTE'
set -Eeuo pipefail

package_root=$1
release_id=$2
base_href=${ZZZ_PWA_BASE_HREF:-/}

fail() {
  printf '[pwa-install] error: %s\n' "$*" >&2
  exit 1
}

for command_name in sha256sum tar gzip grep python3; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "missing ${command_name}"
done
[[ ${package_root} == /tmp/zzz-im-pwa.*/repo ]] || fail 'unsafe package path'
[[ ${release_id} =~ ^[A-Za-z0-9._-]+$ ]] || fail 'invalid release id'
[[ ! -e /srv/www/zzz-im/releases/${release_id} ]] || \
  fail "release already exists: ${release_id}"

(
  cd "${package_root}"
  sha256sum --check SHA256SUMS
)

previous=$(readlink /srv/www/zzz-im/current 2>/dev/null || true)
ZZZ_PWA_BASE_HREF=${base_href} \
  "${package_root}/deploy/zzz-im/deploy-pwa.sh" \
  "${package_root}/dist/zzz-pwa.tar.gz" \
  "${release_id}"

[[ $(readlink /srv/www/zzz-im/current) == releases/${release_id} ]] || \
  fail 'current symlink was not switched'
grep -Fq "<base href=\"${base_href}\">" /srv/www/zzz-im/current/index.html || \
  fail 'installed PWA base href is incorrect'
python3 - <<'PY'
import json
from pathlib import Path
manifest = json.loads(Path("/srv/www/zzz-im/current/startup-assets.json").read_text())
missing = [
    name for name in (
        "main.dart.js",
        "canvaskit/canvaskit.wasm",
        "app-sw.js",
        "loading.js",
    )
    if name not in manifest.get("resources", {})
]
if missing:
    raise SystemExit("startup-assets.json missing " + ", ".join(missing))
print(manifest["version"], manifest["build_bytes"], manifest["resource_count"])
PY

printf '[pwa-install] release %s active; previous %s\n' \
  "${release_id}" "${previous:-none}"
REMOTE
  then
    log "Remote install failed; staging retained at ${target}:${remote_stage}."
    return 1
  fi
  ssh -o BatchMode=yes "${target}" "rm -rf -- '${remote_stage}'"
  log "PWA ${pwa_release_id} deployed to ${target}."
}

if [[ ${action} == deploy || ${action} == push ]]; then
  ensure_deployable_commit
fi

if [[ ${action} == validate ]]; then
  prepare_validation_worktree
else
  prepare_release_checkout
fi
run_local_checks
build_archive

if [[ ${action} != validate ]]; then
  publish_artifacts
fi

if [[ ${action} == deploy || ${action} == push ]]; then
  deploy_archive
fi

if [[ ${action} == validate ]]; then
  log "Worktree PWA validation at ${release_id} complete."
else
  log "PWA release ${pwa_release_id} complete."
fi
