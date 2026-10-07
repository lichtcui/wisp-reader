#!/usr/bin/env bash
# Deploy the remote TTS service to a VPS. Run as root ON the VPS.
# Net is walled: pip must use the Tsinghua mirror. GitHub/HF/pypi.org are unreachable.
set -euo pipefail

SRV_DIR="${SRV_DIR:-/root/tts/server}"
API_KEY="${X_API_KEY:-}"   # set to enable X-API-Key auth; empty = no auth (tailscale only)

echo "==> install fastapi/uvicorn (Tsinghua mirror)"
pip3 install -i https://pypi.tuna.tsinghua.edu.cn/simple --upgrade fastapi uvicorn

echo "==> copy app into ${SRV_DIR}"
mkdir -p "${SRV_DIR}"
cp app.py requirements.txt "${SRV_DIR}/"

echo "==> install systemd unit"
install -m 0644 tts.service /etc/systemd/system/tts.service
if [ -n "${API_KEY}" ]; then
  sed -i "s/^Environment=X_API_KEY=.*/Environment=X_API_KEY=${API_KEY}/" /etc/systemd/system/tts.service
fi
systemctl daemon-reload
systemctl enable --now tts

sleep 2
echo "==> health check"
curl -s "http://127.0.0.1:9880/health" || echo "(curl failed)"
systemctl status tts --no-pager | head -n 12
echo
echo "==> done. Set the app's 'API Key' to: ${API_KEY:-<none, auth disabled>}"