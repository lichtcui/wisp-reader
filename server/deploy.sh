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
cp app.py tts_cache.py pregen_test.py requirements.txt "${SRV_DIR}/"

# The worker is a second process (never loaded by app.py): it holds the 3.3 GB torch +
# GPT-SoVITS weights and must not be able to take the live VITS service down with it.
GSV_DIR="${GSV_DIR:-/root/tts/gsv}"
if [ -d "${GSV_DIR}" ]; then
  echo "==> copy the pre-generation worker into ${GSV_DIR}"
  cp tts_cache.py "${GSV_DIR}/"
  cp job_worker.py "${GSV_DIR}/"
fi

echo "==> install systemd units"
install -m 0644 tts.service /etc/systemd/system/tts.service
install -m 0644 tts-job.service /etc/systemd/system/tts-job.service
if [ -n "${API_KEY}" ]; then
  sed -i "s/^Environment=X_API_KEY=.*/Environment=X_API_KEY=${API_KEY}/" /etc/systemd/system/tts.service
fi
systemctl daemon-reload
systemctl enable --now tts
# The batch worker stays disabled on purpose: it needs ~3.3 GB and ~28 min per 1500 chars,
# so it must never run unattended. Start it explicitly: systemctl start tts-job
systemctl disable --now tts-job >/dev/null 2>&1 || true

sleep 2
echo "==> health check"
curl -s "http://127.0.0.1:9880/health" || echo "(curl failed)"
systemctl status tts --no-pager | head -n 12
echo
echo "==> done. Set the app's 'API Key' to: ${API_KEY:-<none, auth disabled>}"
echo "==> batch worker (disabled): systemctl start tts-job; journalctl -u tts-job -f"
echo "==> acceptance harness: python3 ${SRV_DIR}/pregen_test.py stats | gen <file> --wait"