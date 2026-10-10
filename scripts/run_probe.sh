#!/bin/bash
# 缺口探针一键入口：在【终端】里跑（终端需有完全磁盘访问权限）。
# 用法: bash ~/.workbuddy/skills/sync-icloud-photos-to-drive/scripts/run_probe.sh
# 输出: /tmp/probe_out.txt（主报告） + /tmp/missing_uuids.tsv（全量明细）
set -u
SKILL_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-/tmp/probe_out.txt}"
TSV="${TSV:-/tmp/missing_uuids.tsv}"

# 日志定位：LOG 环境变量 > 从 sync.conf 读导出目录取最新 full-*.log
if [ -z "${LOG:-}" ]; then
  CONF="$HOME/.config/sync-icloud-photos-to-drive/sync.conf"
  DEST_VOL=""; DEST_SUB=""
  [ -f "$CONF" ] && {
    DEST_VOL=$(grep -E '^DEST_VOLUME=' "$CONF" | tail -1 | cut -d= -f2)
    DEST_SUB=$(grep -E '^DEST_SUBDIR='  "$CONF" | tail -1 | cut -d= -f2)
  }
  LOGDIR="${DEST_VOL}/${DEST_SUB}/_导出报告/日志"
  LOG=$(ls -t "$LOGDIR"/full-*.log 2>/dev/null | head -1 || true)
fi
if [ -z "${LOG:-}" ] || [ ! -f "$LOG" ]; then
  echo "找不到导出日志：请用 LOG=<full-*.log 路径> 环境变量指定，或确认 sync.conf 的 DEST_VOLUME/DEST_SUBDIR" >&2
  exit 6
fi
# 续传库：DB 环境变量 > 按 DEST_SUB 推导
if [ -z "${DB:-}" ]; then
  [ -f "$CONF" ] && DEST_SUB="${DEST_SUB:-$(grep -E '^DEST_SUBDIR=' "$CONF" | tail -1 | cut -d= -f2)}"
  DB="$HOME/.cache/osxphotos/${DEST_SUB:+${DEST_SUB}-}export.db"
fi

# python: 优先 pipx 的 osxphotos venv（photoscript 已随装），回退系统 python3
PY="$HOME/.local/share/pipx/venvs/osxphotos/bin/python"
[ -x "$PY" ] || PY="${PYTHON_FALLBACK:-$(command -v python3)}"

rm -f "$OUT" "$TSV"
echo "[run_probe] $(date '+%F %T') python=$PY" | tee "$OUT"
# 25 分钟看门狗（macOS 无 GNU timeout，用 perl alarm）
PYTHONUNBUFFERED=1 /usr/bin/perl -e 'alarm 1500; exec @ARGV' "$PY" \
  "$SKILL_DIR/probe_missing.py" \
  --log "$LOG" --exportdb "$DB" --out "$OUT" --tsv "$TSV" >> "$OUT" 2>&1
rc=$?
echo "PROBE_EXIT=$rc" >> "$OUT"
echo "完成（退出码 $rc）。主报告: $OUT  全量明细: $TSV"
tail -8 "$OUT"
