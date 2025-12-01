#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: generate-openvpn.sh --endpoint <proto://host:port> --client <name> [options]

Options
  --endpoint <value>     Value passed to ovpn_genconfig -u (e.g. udp://vpn.example.com:1194)
  --client <value>       Client/Common Name for the certificate
  --image <name>         Docker image to use (default: ghcr.io/kylemanna/docker-openvpn:2.6)
  --rebuild-ca           Wipe and recreate the entire PKI before issuing the client certificate
  --archive-pki          Produce a tar.gz snapshot of the full PKI directory
  --workdir <path>       Override working directory (defaults to \$PWD)
  -h, --help             Show this text

Environment
  CA_PASSPHRASE          Passphrase used during ovpn_initpki (use Jenkins credential binding)
EOF
}

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "缺少依赖: $cmd" >&2
    exit 10
  fi
}

VPN_ENDPOINT=""
CLIENT_NAME=""
DOCKER_IMAGE="${DOCKER_IMAGE:-ghcr.io/kylemanna/docker-openvpn:2.6}"
REBUILD_CA=false
ARCHIVE_PKI=false
WORK_DIR="${WORK_DIR:-$PWD}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --endpoint)
      VPN_ENDPOINT="$2"
      shift 2
      ;;
    --client)
      CLIENT_NAME="$2"
      shift 2
      ;;
    --image)
      DOCKER_IMAGE="$2"
      shift 2
      ;;
    --rebuild-ca)
      REBUILD_CA=true
      shift
      ;;
    --archive-pki)
      ARCHIVE_PKI=true
      shift
      ;;
    --workdir)
      WORK_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      usage
      exit 1
      ;;
  esac
done

[[ -n "$VPN_ENDPOINT" ]] || { echo "必须提供 --endpoint" >&2; exit 1; }
[[ -n "$CLIENT_NAME" ]] || { echo "必须提供 --client" >&2; exit 1; }
[[ -n "${CA_PASSPHRASE:-}" ]] || { echo "CA_PASSPHRASE 环境变量缺失" >&2; exit 2; }

require_cmd docker
require_cmd tar

STATE_DIR="$WORK_DIR/.openvpn"
ARTIFACT_DIR="$WORK_DIR/artifacts"
CLIENT_DIR="$ARTIFACT_DIR/$CLIENT_NAME"
PROFILE_PATH="$ARTIFACT_DIR/${CLIENT_NAME}.ovpn"

mkdir -p "$STATE_DIR" "$ARTIFACT_DIR"
rm -rf "$CLIENT_DIR"
mkdir -p "$CLIENT_DIR"
umask 077

log "拉取 Docker 镜像 $DOCKER_IMAGE"
docker pull "$DOCKER_IMAGE" >/dev/null

run_in_container() {
  docker run --rm -v "$STATE_DIR:/etc/openvpn" "$DOCKER_IMAGE" "$@"
}

init_pki() {
  log "初始化 PKI"
  run_in_container ovpn_genconfig -u "$VPN_ENDPOINT"
  log "运行 ovpn_initpki"
  printf '%s\n%s\n' "$CA_PASSPHRASE" "$CA_PASSPHRASE" | docker run --rm -i \
    -e EASYRSA_BATCH=1 \
    -v "$STATE_DIR:/etc/openvpn" \
    "$DOCKER_IMAGE" ovpn_initpki
}

if [[ "$REBUILD_CA" == true ]]; then
  log "应用户请求，删除旧 PKI"
  rm -rf "$STATE_DIR"
fi

if [[ ! -f "$STATE_DIR/pki/ca.crt" ]]; then
  mkdir -p "$STATE_DIR"
  init_pki
else
  log "沿用现有 PKI"
fi

log "生成客户端证书: $CLIENT_NAME"
docker run --rm \
  -e EASYRSA_BATCH=1 \
  -v "$STATE_DIR:/etc/openvpn" \
  "$DOCKER_IMAGE" easyrsa build-client-full "$CLIENT_NAME" nopass >/dev/null

log "导出客户端配置文件"
run_in_container ovpn_getclient "$CLIENT_NAME" > "$PROFILE_PATH"
cp "$PROFILE_PATH" "$CLIENT_DIR/"

cp "$STATE_DIR/pki/issued/${CLIENT_NAME}.crt" "$CLIENT_DIR/"
cp "$STATE_DIR/pki/private/${CLIENT_NAME}.key" "$CLIENT_DIR/"
cp "$STATE_DIR/pki/ca.crt" "$CLIENT_DIR/"
if [[ -f "$STATE_DIR/pki/ta.key" ]]; then
  cp "$STATE_DIR/pki/ta.key" "$CLIENT_DIR/"
fi

log "打包客户端素材"
tar -C "$CLIENT_DIR" -czf "$ARTIFACT_DIR/${CLIENT_NAME}-bundle.tgz" .

if [[ "$ARCHIVE_PKI" == true ]]; then
  log "额外归档完整 PKI"
  tar -C "$STATE_DIR" -czf "$ARTIFACT_DIR/pki-backup.tgz" .
fi

log "完成。输出目录: $ARTIFACT_DIR"

