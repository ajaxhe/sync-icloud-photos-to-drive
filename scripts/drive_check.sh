#!/bin/bash
# ============================================================================
# drive_check.sh —— 目标盘体检（导出照片/大文件之前必须先跑）
#
# 用法:
#   bash drive_check.sh <挂载点>            # 只读体检（默认）
#   bash drive_check.sh <挂载点> --speed    # 追加 1 GiB 写入测速（会创建再删除临时文件）
#
# 例:
#   bash drive_check.sh /Volumes/Expansion
#
# 设计原则:
#   - 默认只读。只有显式加 --speed 才会往盘上写东西。
#   - 所有触碰文件系统的调用都带超时。卷 I/O 挂起时快速失败并打印分层判据，
#     而不是让命令永久卡死。（macOS 无 GNU timeout，用 perl alarm 实现）
#
# 环境变量:
#   FS_TIMEOUT    单次文件系统调用超时秒数，默认 8
#   SPEED_TIMEOUT 写入测速超时秒数，默认 300
# ============================================================================
set -uo pipefail

VOL="${1:-}"
SPEED="${2:-}"
FS_TIMEOUT="${FS_TIMEOUT:-8}"
SPEED_TIMEOUT="${SPEED_TIMEOUT:-300}"
TIMEOUT_RC=142     # 128 + SIGALRM(14)

c_ok()   { printf "\033[32m✅ %s\033[0m\n" "$1"; }
c_warn() { printf "\033[33m⚠️  %s\033[0m\n" "$1"; }
c_err()  { printf "\033[31m❌ %s\033[0m\n" "$1"; }
hr()     { printf '%s\n' "============================================================"; }

t_run() {   # t_run <秒> <命令...>  → 原样执行
  local t="$1"; shift
  perl -e 'alarm shift; exec @ARGV' "$t" "$@"
}

fs_probe() {  # 成功回显 stdout；超时 return 124
  local t="$1"; shift
  local out rc
  out="$(perl -e 'alarm shift; exec @ARGV' "$t" "$@" 2>&1)"
  rc=$?
  [ "$rc" -eq "$TIMEOUT_RC" ] && return 124
  printf '%s\n' "$out"
  return "$rc"
}

print_hung_help() {
  echo
  c_err "该卷的文件系统 ${FS_TIMEOUT} 秒内无响应 —— I/O 挂起了"
  echo
  echo "  分层判据（这就是判定方法，不是猜的）："
  echo "    mount 读得到、diskutil 正常  →  盘和 USB 层都还在"
  echo "    但 df / stat / ls 全部阻塞   →  卡在文件系统实现里"
  echo
  echo "  常见诱因：外置盘或 USB 桥接休眠后唤不醒 / 盘掉线但挂载项还在 /"
  echo "            exFAT(FSKit 用户态服务) 卡死"
  echo
  echo "  处置顺序（每步做完重跑本脚本验证）："
  echo "    1) 先试正常推出：访达里点该盘旁的 ⏏"
  echo "       不行则强制卸载：sudo diskutil unmount force \"$VOL\""
  echo "    2) 仍卡住 → 拔掉 USB 重新插（换机身直连口，别走 hub），或重启"
  echo "    3) 重插后先急救：diskutil verifyVolume /dev/diskXsY，或磁盘工具「急救」"
  echo
  c_warn "重插后仍无响应、或反复出现 → 别把它当作唯一落点。"
}

if [ -z "$VOL" ]; then
  echo "用法: bash $0 <挂载点> [--speed]"
  echo "例:   bash $0 /Volumes/Expansion"
  exit 1
fi

if [ ! -d "$VOL" ]; then
  c_err "$VOL 不存在或未挂载。先确认硬盘已插好。"
  echo "当前已挂载的卷:"; ls -1 /Volumes/
  exit 1
fi

hr; echo "目标盘体检: $VOL"; hr

# --- 0. 分层响应测试（最先做，用来判断卡在哪一层）---------------------------
echo "[0/5] 分层响应测试"
MOUNT_LINE="$(mount | grep " on $VOL " || true)"
if [ -n "$MOUNT_LINE" ]; then
  echo "  ① 挂载表      : 在（纯读内核表，不碰文件系统）"
else
  echo "  ① 挂载表      : 不在"
  c_err "$VOL 未挂载。当前已挂载的卷:"; ls -1 /Volumes/ | sed 's/^/      /'
  exit 1
fi

if fs_probe 10 diskutil list >/dev/null 2>&1; then
  echo "  ② 磁盘/分区层 : 有响应（kernel 层）"
else
  echo "  ② 磁盘/分区层 : ❌ diskutil 超时"
  print_hung_help
  exit 3
fi

if DF_RAW="$(fs_probe "$FS_TIMEOUT" df -k "$VOL")"; then
  echo "  ③ 文件系统层  : 有响应"
else
  echo "  ③ 文件系统层  : ❌ 无响应"
  print_hung_help
  exit 3
fi
echo

# --- 1. 挂载与文件系统 -----------------------------------------------------
DEV="$(printf '%s' "$DF_RAW" | awk 'NR==2{print $1}')"
echo "[1/5] 挂载信息"
echo "  设备        : $DEV"
echo "  挂载参数    : ${MOUNT_LINE#*\(}"
if printf '%s' "$MOUNT_LINE" | grep -q 'read-only'; then
  FS_RO=1; c_err "该卷以只读方式挂载 —— 现在写不进去！"
else
  FS_RO=0; c_ok "可读写"
fi

# diskutil 的 Partition Type 常与实际 FS 不一致（出厂分区标志未更新），
# 一律以 File System Personality 为准。
if command -v diskutil >/dev/null 2>&1 && [ -n "$DEV" ]; then
  INFO="$(fs_probe "$FS_TIMEOUT" diskutil info "$DEV")"
  FSP="$(printf '%s' "$INFO" | awk -F': *' '/File System Personality/{print $2}')"
  PTYPE="$(printf '%s' "$INFO" | awk -F': *' '/Partition Type/{print $2}')"
  VRO="$(printf '%s' "$INFO" | awk -F': *' '/Volume Read-Only/{print $2}')"
  PROTO="$(printf '%s' "$INFO" | awk -F': *' '/Protocol/{print $2}')"
  SMART="$(printf '%s' "$INFO" | awk -F': *' '/SMART Status/{print $2}')"
  echo "  实际文件系统: ${FSP:-未知}"
  echo "  分区类型标志: ${PTYPE:-未知}"
  echo "  Volume Read-Only: ${VRO:-?}"
  echo "  接口        : ${PROTO:-?}"
  echo "  SMART       : ${SMART:-?}"
  # APFS 卷的 Partition Type 显示为 GUID，与 Personality 天然不同，不算异常
  if [ -n "$PTYPE" ] && [ -n "$FSP" ] && [ "$PTYPE" != "$FSP" ] && [ "$FSP" != "APFS" ]; then
    c_warn "分区类型标志($PTYPE)与实际文件系统($FSP)不一致 —— 以实际文件系统为准，这是出厂分区标志未更新导致的"
  fi
  case "${PROTO:-}" in
    *USB*) : ;;
  esac
  if [ "${SMART:-}" = "Not Supported" ]; then
    c_warn "读不到 SMART（USB 桥接盘常见）→ 无法预判物理故障，不要用这块盘承载唯一备份"
  fi
fi

# --- 2. 格式建议 -----------------------------------------------------------
echo
echo "[2/5] 格式判断"
case "${FSP:-}" in
  ExFAT|exfat)
    c_ok "exFAT —— 跨 Win/Mac 可用，单文件无 4GB 限制"
    c_warn "但 exFAT 无日志：断电/热拔易损。拔盘前务必先 eject"
    c_warn "且 exFAT 不支持硬链接/扩展属性 → 【不能存放 .photoslibrary】，只能放导出的散文件"
    ;;
  APFS|apfs)
    c_ok "APFS —— Mac 专用最佳选择，可存放 .photoslibrary"
    echo "  注意：Windows 无法读取"
    ;;
  "Mac OS Extended (Journaled)"|"HFS+"|hfs)
    c_ok "HFS+ —— 可存放 .photoslibrary"
    ;;
  NTFS|ntfs)
    c_ok "NTFS"
    c_warn "macOS 原生只读。要写入须装第三方驱动（Paragon/Tuxera），"
    c_warn "而第三方 NTFS 驱动在大批量写入时有元数据损坏风险 —— 不适合承载唯一备份。"
    c_warn "更稳的做法是备份数据后重新格式化为 exFAT。"
    ;;
  FAT32|fat32|"MS-DOS FAT32")
    c_err "FAT32 —— 单文件上限 4 GB，大视频必然失败。不要用于本任务。"
    ;;
  *)
    echo "  未识别的文件系统: ${FSP:-未知}，请人工确认"
    ;;
esac

# --- 3. 容量 ---------------------------------------------------------------
echo
echo "[3/5] 容量"
AVAIL_KB="$(printf '%s' "$DF_RAW" | awk 'NR==2{print $4}')"
TOTAL_KB="$(printf '%s' "$DF_RAW" | awk 'NR==2{print $2}')"
AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))
TOTAL_GB=$(( TOTAL_KB / 1024 / 1024 ))
echo "  总容量: ${TOTAL_GB} GiB"
echo "  可用  : ${AVAIL_GB} GiB"
echo "  已用  : $(( (TOTAL_KB - AVAIL_KB) * 100 / TOTAL_KB ))%"
if [ "$AVAIL_GB" -lt 300 ]; then
  c_err "可用空间不足 300 GiB，装不下几百 GB 的照片库"
elif [ "$AVAIL_GB" -lt 400 ]; then
  c_warn "可用空间偏紧，全量导出前确认图库实际体量"
else
  c_ok "空间充足"
fi
if [ "$(( AVAIL_KB * 100 / TOTAL_KB ))" -lt 10 ]; then
  c_warn "剩余空间低于 10%：exFAT 在这个区间碎片化严重、写入显著变慢"
fi

# --- 4. 已有内容（避免和旧备份混在一起）------------------------------------
echo
echo "[4/5] 顶层已有内容"
TOP_LIST="$(fs_probe "$FS_TIMEOUT" ls -1 "$VOL")"
if [ $? -eq 124 ]; then
  c_err "列目录超时 —— 文件系统不稳定，先跑 doctor 处置"
  exit 3
fi
printf '%s\n' "$TOP_LIST" | head -20 | sed 's/^/  /'
N_TOP="$(printf '%s\n' "$TOP_LIST" | grep -c . || true)"
[ "${N_TOP:-0}" -gt 20 ] && echo "  ...（共 $N_TOP 项）"
echo "  建议：新导出的目录用独立命名（如 iCloud导出-YYYY），与旧备份物理隔离"

# --- 5. 写入测速（可选）----------------------------------------------------
echo
if [ "$SPEED" = "--speed" ]; then
  echo "[5/5] 写入测速（1 GiB 顺序写 + fsync，会创建并在结束后删除临时文件）"
  TMPF="$VOL/.drive_check_speedtest.bin"
  if [ -e "$TMPF" ]; then
    c_err "$TMPF 已存在，跳过测速以免覆盖未知文件"
  else
    t_run "$SPEED_TIMEOUT" dd if=/dev/zero of="$TMPF" bs=1m count=1024 conv=fsync 2>&1 \
      | tail -1 | sed 's/^/  /'
    DRC=${PIPESTATUS[0]}
    [ "$DRC" -eq "$TIMEOUT_RC" ] && c_err "写入测速超时（${SPEED_TIMEOUT}s）—— 卷已经不稳定，别再往里写数据"
    if fs_probe "$FS_TIMEOUT" rm -f "$TMPF" >/dev/null 2>&1; then
      if fs_probe "$FS_TIMEOUT" test -e "$TMPF" >/dev/null 2>&1; then
        c_err "临时文件清理失败: $TMPF —— 请手动删除"
      else
        echo "  ✅ 临时文件已清理"
      fi
    else
      c_err "清理临时文件超时，请手动删除: $TMPF"
    fi
    echo "  参考：机械 USB3 盘 80-130 MB/s 为正常；如果是 SSD 却低于 200 MB/s，检查是否走了 USB 2.0 或 hub"
  fi
else
  echo "[5/5] 跳过写入测速（如需实测: 加 --speed）"
fi

hr
if [ "$FS_RO" -eq 1 ]; then
  c_err "结论：该盘当前不可写，先解决只读问题再开跑"
  exit 2
fi
c_ok "结论：体检通过。可以把大文件写到这里。"
echo
echo "提醒：导出全程请插电、别合盖；拔盘前先 eject。"
