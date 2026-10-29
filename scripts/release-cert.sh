#!/usr/bin/env bash
# 一次性：创建发布用自签名证书 "Nekro TouchOS Release"（docs/decisions.md D3），
# 导出 p12 到 ~/.touchos-release/（务必另行备份，丢失后用户更新需重新授权辅助功能），
# 并写入仓库 Actions Secrets：MACOS_SIGNING_P12、MACOS_SIGNING_PASSWORD。已存在时不覆盖。
set -euo pipefail
NAME="Nekro TouchOS Release"
DIR="$HOME/.touchos-release"
P12="$DIR/release.p12"
REPO="${REPO:-NekroAI/touchos}"
if [ -f "$P12" ]; then echo "已存在 $P12，不重新创建"; exit 0; fi
mkdir -p "$DIR"; chmod 700 "$DIR"
PASS="$(openssl rand -hex 16)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
O = NekroAI
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 7300 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg" 2>/dev/null
/usr/bin/openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -passout "pass:$PASS" -out "$P12" 2>/dev/null \
  || /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -passout "pass:$PASS" -out "$P12"
printf '%s' "$PASS" > "$DIR/password.txt"
chmod 600 "$P12" "$DIR/password.txt"
base64 -i "$P12" | gh secret set MACOS_SIGNING_P12 --repo "$REPO"
printf '%s' "$PASS" | gh secret set MACOS_SIGNING_PASSWORD --repo "$REPO"
echo "已创建 $P12 并写入 $REPO 的 Actions Secrets"
