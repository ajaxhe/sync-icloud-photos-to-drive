#!/bin/bash
# ============================================================================
# guard-status.sh —— 导出「一眼体检」（**全程只读**，导出进行中也能随时跑）
#
# 【为什么单独做一个】
# 判断导出状态原本要拼 4~5 条命令（文件数 / du / df / 守卫日志尾 / 本轮 full
# 日志尾 + 各类计数），口径容易记错。最容易犯的两个错：
#   ① 把 `Skipping missing original` 多当成故障 —— 实测一轮 902 条 skip 里
#      679 条其实早已导出，是「原件不在本地、osxphotos 复核不了」的重走噪声
#      （gotchas 第 36 节）
#   ② 看到「退出码 4 / 建议重启 Mac」就信 —— 22:28 那次是彻头彻尾的误报
#      （gotchas 第 36、37 节）
# 本脚本把口径固化：一次输出 = 进度 + 速率 + 误报判别 + 该不该动手。
#
# 【用法】
#   bash scripts/guard-status.sh              # 从 sync.conf 读配置
#   bash scripts/guard-status.sh --json       # 机器可读（供定时任务调用）
#   bash scripts/guard-status.sh --fast       # 跳过 du（省几秒）
#
# 【退出码】
#   0  正常推进中，或已完整完成
#   2  没在跑，且没有完成迹象
#   3  内部盘空间低于 FLOOR（脉冲该休息了 / 或回收失败）
#   4  疑似真·取件通道失效（同轮 `Exported new file` 计数≈0 才可信）
#   6  前置不满足（外置盘没挂 / 配置缺 DEST_VOLUME）
# ============================================================================
set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

JSON=0; FAST=0
for a in "$@"; do
  case "$a" in
    --json) JSON=1 ;;
    --fast) FAST=1 ;;
  esac
done

# --- 配置（与 space_guard.sh 同源，不重复实现）------------------------------
SRC_LIBRARY=""; DEST_VOLUME=""; DEST_SUBDIR="iCloud导出"
SPACE_FLOOR_GIB=12; SPACE_CEIL_GIB=18; SPACE_HARD_MIN_GIB=6
CONF="${SYNC_CONF:-$HOME/.config/sync-icloud-photos-to-drive/sync.conf}"
CONF_LOADED=""
if [ -f "$CONF" ]; then
  # shellcheck disable=SC1090
  . "$CONF"
  CONF_LOADED="$CONF"
fi
[ -n "${DEST_VOLUME:-}" ] || { echo "❌ 未配置 DEST_VOLUME。检查 ${CONF}" >&2; exit 6; }

VOL="${DEST_VOLUME}"
DEST="${VOL}/${DEST_SUBDIR}"
REPORT_DIR="${DEST}/_导出报告"
LOG_DIR="${REPORT_DIR}/日志"
GUARD_LOG="${LOG_DIR}/space-guard.log"
DBDIR="${EXPORT_DB_DIR:-$HOME/.cache/osxphotos}"
EXPORT_DB="${DBDIR}/${DEST_SUBDIR}-export.db"

# ⚠️ bash 3.2：中文里插变量一律写 ${VAR}，否则高位字节会被并进变量名（第 5e 节）
free_gib() { df -k / | awk 'NR==2{printf "%d", $4/1024/1024}'; }
internal_total_gib() { df -k / | awk 'NR==2{printf "%d", $2/1024/1024}'; }
vol_free_gib() { df -k "$VOL" 2>/dev/null | awk 'NR==2{printf "%d", $4/1024/1024}'; }
dest_files() { find "$DEST" -type f ! -name '.*' ! -path '*/_导出报告/*' 2>/dev/null | wc -l | tr -d ' '; }
# pgrep 在受限环境里可能被拒 → 退回 ps 扫描
running_guard() {
  pgrep -f "space_guard.sh" >/dev/null 2>&1 && return 0
  ps ax 2>/dev/null | grep -v grep | grep -q "space_guard.sh" && return 0
  return 1
}
running_export() {
  pgrep -f "osxphotos export" >/dev/null 2>&1 && return 0
  ps ax 2>/dev/null | grep -v grep | grep -q "osxphotos export" && return 0
  return 1
}

ts() { date '+%Y-%m-%d %H:%M:%S'; }
FG="$(free_gib)"

# --- 外置盘 ----------------------------------------------------------------
if [ ! -d "$VOL" ]; then
  echo "❌ 外置盘未挂载：$VOL"
  echo "   插好盘再跑；导出不会因此丢进度（续传库在内部盘）。"
  exit 6
fi

# --- 产物 ------------------------------------------------------------------
N="$(dest_files)"
if [ "$FAST" = "1" ]; then
  SIZE="(--fast 跳过)"
else
  # `du -sh` 的输出带一个前导空格，直接拼进对齐的标签里会整体右移一格
  SIZE="$(du -sh "$DEST" 2>/dev/null | cut -f1 | tr -d ' ')"
  [ -n "$SIZE" ] || SIZE="-"
fi

# --- 最新一轮导出日志 --------------------------------------------------------
# 只看**本轮**（最新那个 full-*.log）的计数。跨轮累加没有意义，还会把
# 「上一轮出了 2756 个」错记到本轮头上。
L="$(ls -t "${LOG_DIR}"/full-*.log 2>/dev/null | head -1)"
L_NAME="-"; L_MTIME="-"; L_AGE="-"; EXP_CNT=0; SKIP_CNT=0; ERR_CNT=0; ERR_SUM=""; TAIL3=""; TOTAL_ENUM=""
if [ -n "${L:-}" ]; then
  L_NAME="$(basename "$L")"
  L_MTIME="$(date -r "$L" '+%m-%d %H:%M:%S' 2>/dev/null)"
  # 本轮日志静默时长：**纯信息展示**，不参与结论/退出码。
  # 为什么需要它：本脚本的「在跑」判据是 pgrep 进程存在性，而 gotchas 13d 早已
  # 证明「进程活着/探针绿」不等于有产出。导出大体积视频时日志会静默十几分钟属正常，
  # 故只显示不断言；连续静默 >30 分钟时才值得人工看一眼。
  L_TS="$(date -r "$L" +%s 2>/dev/null)"
  [ -n "${L_TS:-}" ] && L_AGE=$(( ( $(date +%s) - L_TS ) / 60 ))
  EXP_CNT="$(grep -c 'Exported new file' "$L" 2>/dev/null | tr -d ' ')"
  SKIP_CNT="$(grep -c 'Skipping missing' "$L" 2>/dev/null | tr -d ' ')"
  # ⚠️ 错误数不能用 `grep -ci error`：收尾那行 `Processed: … error: 0`
  #    里也有 "error"，会被算成 1 条，看起来像出了错。
  #    优先用收尾汇总行里的权威字段；没有汇总行（轮次被杀）时才退化为
  #    数「大写 E 开头的 Error 行」。
  ERR_SUM="$(grep -oE 'error: *[0-9]+' "$L" 2>/dev/null | tail -1 | tr -dc '0-9')"
  ERR_CNT="$(grep -c 'Error' "$L" 2>/dev/null | tr -d ' ')"
  TAIL3="$(tail -3 "$L" 2>/dev/null)"
  # 枚举总数：从 `(1234/17124)` 里取分母最大值
  TOTAL_ENUM="$(grep -oE '\([0-9]+/[0-9]+\)' "$L" 2>/dev/null | sed 's|.*/||; s|)||' | sort -n | tail -1)"
fi

# 守卫日志最后写入距今多少分钟：用来识别「有守卫在跑，但跑的是别的导出目录」
G_AGE="-"
if [ -f "$GUARD_LOG" ]; then
  G_TS="$(date -r "$GUARD_LOG" +%s 2>/dev/null)"
  [ -n "${G_TS:-}" ] && G_AGE=$(( ( $(date +%s) - G_TS ) / 60 ))
fi

# --- 进度百分比 --------------------------------------------------------------
# ⚠️ 尾段跳转（space_guard 的 AUTO_SKIP_DONE）生效后，osxphotos 只枚举
#    「FROM_DATE 之后」的子集，本轮日志里 `(1/1255)` 的分母就只剩剩余项。
#    这时若仍用 N/分母，会打印出「完成 1262.9%」这种荒谬值（2026-10-08 实测踩到）。
#    正确口径：全库 ≈ 已落地 N + 本轮枚举剩余 → 拿它当分母。
#    ⚠️ 匹配要用宽口径 `FROM_DATE=`（不带前缀）：守卫有三种措辞 ——
#      「本轮 FROM_DATE=」(旧) / 「本轮自动取续传库最新日期 → FROM_DATE=」(2026-10-09 起) /
#      「沿用你指定的 FROM_DATE=」。只认第一种会读到**早已作废的旧值**
#      （2026-10-09 实测：实际已跳到 2026-04-07，这里还显示 03-14）。
FROM_DATE="$(grep -oE 'FROM_DATE=[0-9]{4}-[0-9]{2}-[0-9]{2}' "$GUARD_LOG" 2>/dev/null \
             | tail -1 | sed 's/.*=//')"
#    ⚠️⚠️ 但「N + 本轮分母」只在**跳转轮**成立。全量复核轮（如 `FROM_DATE=2008-01-01`）
#    会把整个库枚举一遍，此时本轮分母**本身就是全库**，再加 N 就翻倍 ——
#    2026-10-10 04:0x 实测踩到：17119 落地 / 分母算成 34248 → 打印「完成 50.0%」，
#    而真实是 99.9%。分界看「本轮分母 vs 已落地数」：
#      TOTAL_ENUM >= N  ⇒ 本轮枚举的就是全库（全量轮）→ 分母 = TOTAL_ENUM
#      TOTAL_ENUM <  N  ⇒ 本轮只枚举了尾段（跳转轮）→ 分母 = N + TOTAL_ENUM
PCT="-"; DENOM=""; REM=""
if [ -n "${TOTAL_ENUM:-}" ] && [ "${TOTAL_ENUM:-0}" -gt 0 ]; then
  if [ "$TOTAL_ENUM" -ge "$N" ]; then
    DENOM="$TOTAL_ENUM"; REM=$(( TOTAL_ENUM - N ))
    PCT="$(awk -v n="$N" -v t="$DENOM" 'BEGIN{printf "%.1f", 100*n/t}')%"
    [ "$REM" -gt 0 ] && PCT="${PCT}（剩 ${REM} 项，本轮为全量枚举）"
  else
    DENOM=$(( N + TOTAL_ENUM )); REM="$TOTAL_ENUM"
    PCT="$(awk -v n="$N" -v t="$DENOM" 'BEGIN{printf "%.1f", 100*n/t}')%"
    if [ -n "${FROM_DATE:-}" ]; then
      PCT="${PCT}（剩 ${REM} 项，本轮跳至 ${FROM_DATE}）"
    else
      PCT="${PCT}（剩 ${REM} 项）"
    fi
  fi
fi

# --- 速率（只统计【本次启动之后】的采样）-------------------------------------
# 守卫每 20 次巡检打一行 `[MM-DD HH:MM:SS]  …工作进行中：已落地 N 个文件`。
# ⚠️ 必须遇到「space_guard 启动」就清空样本 —— 否则会把上一次会话的 8505 个
#    也算进本次，算出荒谬的速率（实测把 22:28 之前的 80 分钟混了进来）。
RATE=""; RATE_DN=0; RATE_DT=0; RATE_PER_H="-"
if [ -f "$GUARD_LOG" ]; then
  RATE="$(perl -ne '
    if (/space_guard 启动/) { @s = (); @n = (); }
    # ⚠️ 时间键必须带日期：只取 HH:MM:SS 会在跨零点时变小（23:08 → 01:00 变成负数），
    #    $dt<=0 被夹成 1 秒，速率放大成百万级（2026-10-08 01:09 实测打印过 3542400 个/小时）。
    if (/^\[(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\].*已落地 (\d+) 个文件/) {
      push @s, ((($1*31)+$2)*86400 + $3*3600 + $4*60 + $5); push @n, $6;
    }
    END {
      if (@s >= 2) {
        my $dt = $s[-1] - $s[0]; $dt = 1 if $dt <= 0;
        my $dn = $n[-1] - $n[0];
        printf "%d %.1f", $dn, $dn*3600/$dt;
      }
    }' "$GUARD_LOG" 2>/dev/null)"
  if [ -n "$RATE" ]; then
    RATE_DN="$(printf '%s' "$RATE" | awk '{print $1}')"
    RATE_PER_H="$(printf '%s' "$RATE" | awk '{print $2}')"
  fi
fi

# --- 守卫日志尾部 + 结局关键词 ----------------------------------------------
GUARD_TAIL=""
[ -f "$GUARD_LOG" ] && GUARD_TAIL="$(tail -6 "$GUARD_LOG" 2>/dev/null)"
# 结局判定：按最后出现的标志性语句，取最靠后的那一类
VERDICT="unknown"
if [ -f "$GUARD_LOG" ]; then
  LAST_OUTCOME="$(grep -nE '全部完成。已落地|取件通道持续失效|内部盘空间无法回收|外置盘未挂载|达到轮次上限' "$GUARD_LOG" 2>/dev/null | tail -1)"
  case "${LAST_OUTCOME:-}" in
    *全部完成*|*达到轮次上限*) VERDICT="finished" ;;
    *取件通道持续失效*)       VERDICT="channel" ;;
    *空间无法回收*)           VERDICT="space" ;;
    *外置盘未挂载*)           VERDICT="nodrive" ;;
    *)                        VERDICT="unknown" ;;
  esac
fi

IS_RUNNING=0
if running_guard; then IS_RUNNING=1; fi
IS_EXPORTING=0
if running_export; then IS_EXPORTING=1; fi

# --- 判定 -------------------------------------------------------------------
# 核心：退出码 4 是否可信，只看【同轮 Exported new file 的条数】+【尾部是否停在半句】。
TAIL_HALF=0
printf '%s' "$TAIL3" | grep -qE 'Exporting .*\(' && TAIL_HALF=1
RC=0; ACTION=""
if [ "$IS_RUNNING" = "1" ]; then
  VERDICT="running"
  if [ "${G_AGE:-0}" != "-" ] && [ "${G_AGE:-0}" -gt 10 ]; then
    ACTION="有 space_guard 在跑，但本目录的守卫日志已 ${G_AGE} 分钟没更新 —— 可能跑的是别的导出目录，先确认。"
  else
    ACTION="正常在跑，不用干预。"
  fi
elif [ "$VERDICT" = "finished" ]; then
  ACTION="已完整收尾。可做补漏：bash ${SKILL_DIR}/scripts/icloud_export.sh full"
elif [ "$VERDICT" = "channel" ]; then
  if [ "${EXP_CNT:-0}" -gt 100 ] || [ "$TAIL_HALF" = "1" ]; then
    RC=0; VERDICT="channel-likely-false"
    ACTION="⚠️ 疑似误报：本轮还出了 ${EXP_CNT} 个文件。直接重跑守卫，别动 Photos、别重启 Mac。"
  else
    RC=4; VERDICT="channel-likely-real"
    ACTION="本轮 Exported≈${EXP_CNT} 且尾部无半句 → 判据可信。按序试：① 重开「照片」并重跑 ② 重启 Mac ③ OSXPHOTOS_PHOTOKIT=1 重跑"
  fi
elif [ "$VERDICT" = "space" ]; then
  RC=3; ACTION="空间回收失败：确认「照片 → 设置 → iCloud → 优化 Mac 储存空间」。"
else
  RC=2
  if [ "$FG" -lt "$SPACE_FLOOR_GIB" ]; then
    RC=3; ACTION="内部盘仅 ${FG} GiB（< FLOOR=${SPACE_FLOOR_GIB}）：腾空间或调低阈值后再启动。"
  else
    ACTION="没在跑。启动：caffeinate -is bash ${SKILL_DIR}/scripts/space_guard.sh"
  fi
fi

# --- 输出 -------------------------------------------------------------------
if [ "$JSON" = "1" ]; then
  cat <<JSONEOF
{"time":"$(ts)","running_guard":${IS_RUNNING},"running_export":${IS_EXPORTING},
 "verdict":"${VERDICT}","files":${N},"size":"${SIZE}","enumerated":${TOTAL_ENUM:-0},"denom":${DENOM:-0},"pct":"${PCT}","from_date":"${FROM_DATE}",
 "internal_free_gib":${FG},"internal_total_gib":$(internal_total_gib),"vol_free_gib":$(vol_free_gib),
 "session_delta":${RATE_DN},"per_hour":"${RATE_PER_H}",
 "round_log":"${L_NAME}","exported":${EXP_CNT},"skipping":${SKIP_CNT},"errors":${ERR_CNT},
 "error_summary":"${ERR_SUM}","guard_log_age_min":"${G_AGE}","round_log_age_min":"${L_AGE}",
 "exit":${RC},"action":"${ACTION}"}
JSONEOF
  exit "$RC"
fi

echo "============================================================"
echo " iCloud 导出体检   $(ts)"
echo "------------------------------------------------------------"
# ⚠️ 中文是双宽字符，printf 的 %-14s 按字节数补空格，列会对不齐。
#    这里手工补空格，标签统一占 12 个显示列（= 6 个汉字宽）。
echo " 配置      ${CONF_LOADED:-（内置默认值）}"
echo " 目标目录  ${DEST}"
echo " 续传库    ${EXPORT_DB}"
echo "------------------------------------------------------------"
echo " 落地文件  ${N} 个${TOTAL_ENUM:+　（完成 ${PCT}）}"
echo " 体积      ${SIZE}"
echo " 本轮日志  ${L_NAME}   最后写入 ${L_MTIME}"
# 纯信息行（不参与结论）：导出大体积视频时日志静默十几分钟属正常
[ "${L_AGE}" != "-" ] && echo " 日志静默  ${L_AGE} 分钟（大文件导出期间静默属正常；连续 >30 分钟才值得看一眼）"
if [ -n "${ERR_SUM:-}" ]; then
  echo " 本轮计数  Exported ${EXP_CNT}   Skipping ${SKIP_CNT}   汇总 error=${ERR_SUM}"
else
  echo " 本轮计数  Exported ${EXP_CNT}   Skipping ${SKIP_CNT}   Error行 ${ERR_CNT}（本轮未收尾，无汇总值）"
fi
echo " 当前会话  净增 ${RATE_DN} 个，约 ${RATE_PER_H} 个/小时"
echo "------------------------------------------------------------"
echo " 内部盘    可用 ${FG} GiB / 共 $(internal_total_gib) GiB  (FLOOR=${SPACE_FLOOR_GIB}  CEIL=${SPACE_CEIL_GIB})"
echo " 外置盘    可用 $(vol_free_gib) GiB"
echo " 进程      space_guard=$([ "${IS_RUNNING}" = 1 ] && echo 在跑 || echo 未跑)  osxphotos export=$([ "${IS_EXPORTING}" = 1 ] && echo 在跑 || echo 未跑)  守卫日志 ${G_AGE} 分钟前更新"
echo "------------------------------------------------------------"
if [ -n "${TAIL3:-}" ]; then
  echo " 本轮日志尾部："
  printf '%s\n' "$TAIL3" | sed 's/^/   /'
  echo "------------------------------------------------------------"
fi
if [ -n "${GUARD_TAIL:-}" ]; then
  echo " 守卫日志尾部："
  printf '%s\n' "$GUARD_TAIL" | sed 's/^/   /'
  echo "------------------------------------------------------------"
fi

# 只列不删：残留的试跑目录与 AppleDouble 伴生文件
RESIDUE_DIRS="$(ls -d "${VOL}"/_试跑-* 2>/dev/null | wc -l | tr -d ' ')"
RESIDUE_FILES="$(ls "${DEST}"/._* 2>/dev/null | wc -l | tr -d ' ')"
if [ "${RESIDUE_DIRS:-0}" != "0" ] || [ "${RESIDUE_FILES:-0}" != "0" ]; then
  echo " 残留（只列不删，确认后再清）："
  echo "   ${VOL}/_试跑-*  ${RESIDUE_DIRS} 个目录"
  echo "   ${DEST}/._*     ${RESIDUE_FILES} 个伴生文件"
  echo "------------------------------------------------------------"
fi

echo " 结论：${ACTION}"
echo "============================================================"
exit "$RC"
