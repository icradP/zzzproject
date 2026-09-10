#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Build and deploy ZZZ IM production artifacts from the local workstation.

Usage:
  ./deploy/zzz-im/release.sh validate
  ./deploy/zzz-im/release.sh build
  ./deploy/zzz-im/release.sh deploy user@host
  ./deploy/zzz-im/release.sh native validate|build|deploy [user@host]
  ./deploy/zzz-im/release.sh pwa validate|build|deploy [user@host]

Commands:
  validate  Run native then PWA validation without publishing.
  build     Build native Linux artifacts and the PWA archive locally.
  deploy    Build both, then install native services before activating the PWA.
  push      Alias for deploy.
  native    Pass the remaining arguments to release-native.sh.
  pwa       Pass the remaining arguments to release-pwa.sh.

Native services are installed first so a new PWA never points at an older
protocol. The production host receives binaries and the PWA archive only;
it never compiles Go or Flutter.

See release-native.sh and release-pwa.sh for environment variables.
USAGE
}

die() {
  printf '[release] error: %s\n' "$*" >&2
  exit 1
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
native_script=${script_dir}/release-native.sh
pwa_script=${script_dir}/release-pwa.sh
action=${1:-}

[[ -x ${native_script} && -x ${pwa_script} ]] || die 'release helper scripts are missing'

case ${action} in
  '' | -h | --help | help)
    usage
    exit 0
    ;;
  native)
    shift
    exec "${native_script}" "$@"
    ;;
  pwa)
    shift
    exec "${pwa_script}" "$@"
    ;;
  validate | build)
    [[ $# -le 1 ]] || die "${action} does not accept an SSH target"
    "${native_script}" "${action}"
    "${pwa_script}" "${action}"
    ;;
  deploy | push)
    [[ $# -le 2 ]] || die "too many arguments"
    [[ $# -ge 2 || -n ${ZZZ_DEPLOY_TARGET:-} ]] || \
      die "deploy requires user@host or ZZZ_DEPLOY_TARGET"
    if [[ $# -ge 2 ]]; then
      "${native_script}" "${action}" "$2"
      "${pwa_script}" "${action}" "$2"
    else
      "${native_script}" "${action}"
      "${pwa_script}" "${action}"
    fi
    ;;
  *)
    usage >&2
    die "unknown command: ${action}"
    ;;
esac
