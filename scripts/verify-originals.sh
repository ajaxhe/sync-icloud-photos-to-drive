#!/usr/bin/env bash
# verify-originals.sh —— 离线核验「导出的到底是不是原件」
#
# 背景：Photos 设为「优化 Mac 储存空间」后，本地只留小副本，原件在 iCloud。
#      用户会担心导出拿到的是缩略/优化副本。本脚本用 osxphotos 续传库里
#      记录的【原件真实字节数】(original_filesize，来自 Photos 数据库)
#      与【实际导出的字节数】(dest_size) 逐条比对，给出定量结论。
#
# 依赖：osxphotos 的 -export.db（导出时用 --report 或 osxphotos 自动生成）。
#      不读 Photos 图库、不连 iCloud、不需要完全磁盘访问 → 可随时离线跑。
#
# 用法：
#   bash verify-originals.sh                    # 自动找 ~/.cache/osxphotos/*-export.db
#   bash verify-originals.sh <export.db>
#   bash verify-originals.sh <export.db> <导出目录>   # 额外核对磁盘上的实际字节
#
# 注：续传库里的 filepath 是【相对路径】(如 2008/05/IMG_7925.JPG)，
#     绝对位置取库里的 export_directory 表，或用第 2 个参数覆盖。
#
# 退出码：0 = 未发现可疑条目；1 = 发现可疑（导出文件小于原件）；2 = 无法运行

set -uo pipefail

PY="${OSXPHOTOS_PY:-$HOME/.local/share/pipx/venvs/osxphotos/bin/python}"
[ -x "$PY" ] || PY="$(command -v python3)"

DB="${1:-}"
DEST="${2:-}"

if [ -z "$DB" ]; then
  DB="$(ls -t "$HOME"/.cache/osxphotos/*-export.db 2>/dev/null | head -1)"
fi
if [ -z "$DB" ] || [ ! -f "$DB" ]; then
  echo "找不到续传库。请显式传入路径：bash $0 <xxx-export.db> [导出目录]" >&2
  exit 2
fi

echo "续传库 : $DB"
[ -n "$DEST" ] && echo "导出目录: $DEST"
echo

DB="$DB" DEST="$DEST" "$PY" - <<'PY'
import json, os, sqlite3, sys

db   = os.environ["DB"]
dest = os.environ.get("DEST") or ""

con = sqlite3.connect("file:" + db + "?mode=ro", uri=True)
con.row_factory = sqlite3.Row

info = {}
for r in con.execute("select uuid, photoinfo from photoinfo"):
    try:
        info[r["uuid"]] = json.loads(r["photoinfo"])
    except Exception:
        pass

# 导出根目录：命令行参数优先，否则取库里的 export_directory
base = dest
if not base:
    row = con.execute("select export_directory from export_directory limit 1").fetchone()
    base = row[0] if row else ""
print("导出根目录: %s" % (base or "<未知>"))

def abs_of(fp):
    if not fp:
        return fp
    if os.path.isabs(fp):
        return fp
    return os.path.join(base, fp) if base else fp

rows = list(con.execute(
    "select uuid, filepath, src_size, dest_size, digest from export_data"))

print("记录数 %d   涉及 UUID %d" % (len(rows), len(set(r["uuid"] for r in rows))))
if not rows:
    sys.exit(2)

faithful = []      # 字节 == 原件
extras   = []      # 字节 != 原件（一般是 edited 版本等「附加产物」）
suspect  = []      # 字节 < 原件 且无法解释 —— 唯一需要警惕的形态
missing_n = faithful_missing = 0

for r in rows:
    j = info.get(r["uuid"])
    if not j:
        continue
    o = j.get("original_filesize") or 0
    d = r["dest_size"] or 0
    if not o or not d:
        continue
    if j.get("ismissing"):
        missing_n += 1
    if d == o:
        faithful.append((r, j))
        if j.get("ismissing"):
            faithful_missing += 1
    else:
        fp = r["filepath"] or ""
        # 可解释：Photos 对「编辑版」的独立重编码产物，文件名带 _edited / _adjusted
        explainable = (d > o) or ("_edited" in fp) or ("_adjusted" in fp)
        rec = (r, j, d / o, explainable)
        extras.append(rec)
        if d < o and not explainable:
            suspect.append(rec)

print()
print("【1】字节数与原件完全一致 : %d 条  (%.1f%%)" %
      (len(faithful), 100.0 * len(faithful) / max(1, len(faithful) + len(extras))))
print("【2】字节数与原件不同     : %d 条" % len(extras))
print("      其中可解释(编辑版等附加产物) : %d 条" % (len(extras) - len(suspect)))
print("      其中无法解释、需人工看       : %d 条" % len(suspect))

print()
print("【3】导出时本地没有、需从 iCloud 现拉 : %d 条" % missing_n)
print("      这些里面仍然是逐字节原件的   : %d 条  (%.1f%%)" %
      (faithful_missing, 100.0 * faithful_missing / max(1, missing_n)))
print("      → 这一项直接回答「优化存储会不会让我拿到压缩件」")

# 非一致条目：按「原容器 → 导出容器」归类，区分可解释与不可解释
if extras:
    print()
    print("【4】字节数不同的条目分布")
    bucket = {}
    for r, j, ratio, explainable in extras:
        k = "%s -> %s  adj=%s" % (j.get("uti_original"), j.get("uti"), j.get("adjustment_type"))
        b = bucket.setdefault(k, [0, [], []])
        b[0] += 1
        b[1].append(ratio)
        b[2].append(1 if explainable else 0)
    for k in sorted(bucket, key=lambda x: -bucket[x][0]):
        cnt, rs, ex = bucket[k]
        rs.sort()
        print("  %-44s %4d 条  可解释 %d  比值 %.2f~%.2f" %
              (k, cnt, sum(ex), rs[0], rs[-1]))
    print("  说明：导出名带 _edited/_adjusted、或导出字节大于原件 → 是 Photos 对")
    print("        「编辑版」的独立重编码产物；同一条目的逐字节原件也在导出目录里。")

if suspect:
    print()
    print("【5】⚠ 小于原件、且无法用「编辑版」解释（最多列 20 条）")
    for r, j, ratio, _ in suspect[:20]:
        print("  %.3f  %s  dest=%d  orig=%d  %s" %
              (ratio, j.get("original_filename"), r["dest_size"],
               j["original_filesize"], os.path.basename(r["filepath"])))
    print("  判读：uti_original == uti 且比值明显 < 1 → 可能是优化/派生素材。")
else:
    print()
    print("【5】未发现「小于原件且不可解释」的条目 ✔")

# 可选：核对磁盘上文件的实际字节，捕获拷贝截断/损坏
if base and os.path.isdir(base):
    print()
    print("【6】磁盘实际字节核对")
    bad = chk = 0
    for r in rows:
        fp = abs_of(r["filepath"])
        if not fp:
            continue
        chk += 1
        try:
            real = os.path.getsize(fp)
        except OSError:
            bad += 1
            if bad <= 10:
                print("  缺失/不可读: %s" % os.path.basename(fp))
            continue
        if real != (r["dest_size"] or -1):
            bad += 1
            if bad <= 10:
                print("  大小不符 %d != %d : %s" % (real, r["dest_size"], os.path.basename(fp)))
    print("  核对 %d 个文件，异常 %d 个" % (chk, bad))
elif base:
    print()
    print("【6】导出目录不可访问（移动硬盘未挂载？）: %s" % base)
else:
    print()
    print("【6】跳过磁盘核对：库里没有 export_directory，也没传第 2 个参数")

print()
print("结论口径：以【1】占比与【3】的比例为准。")
print("  【1】接近 100% 且【3】的比例也高 → 优化存储下导出的确实是原件，放心。")
sys.exit(1 if suspect else 0)
PY
rc=$?
echo
if [ "$rc" = "0" ]; then
  echo "==== 核验通过：未发现小于原件的条目 ===="
elif [ "$rc" = "1" ]; then
  echo "==== 有可疑条目，见上面【5】 ===="
else
  echo "==== 无法完成核验（rc=${rc}）===="
fi
exit "$rc"
