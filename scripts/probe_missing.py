#!/usr/bin/env python3
"""缺口探针 v2：对导出日志里的 missing 资产做全量定性。

数据源（三个，均为只读）：
  1) 导出日志          —— 解析 "Skipping missing original photo <name> (<uuid>)" 得到缺口清单
  2) Photos.sqlite     —— immutable 只读：ZASSET 记录 / 尺寸 / 云状态 / originals/ 磁盘存在性
  3) osxphotos 续传库  —— 已落地件（export_data + photoinfo JSON）的尺寸，用于同名判定

探针动作：
  PART 1  解析日志 → 缺口 UUID 清单
  PART 2  Photos.sqlite 聚合 + 全量明细 TSV（含 originals/ 磁盘存在性）
  PART 3  同名判定：同名同尺寸（重复嫌疑）/ 同名异尺寸（撞名）/ 无同名
  PART 4  AppleScript 全量寻址扫描：Photos 应用到底能不能看见这些 UUID
          （对照组必须通过，否则 PART 4 结果不可信）
  PART 5  结论汇总

输出：
  --out  主报告文本
  --tsv  全量明细（uuid/name/尺寸/磁盘存在/判定/可寻址）

用法（终端里跑，终端需有「完全磁盘访问」+「照片」自动化权限）：
  python3 probe_missing.py \
    --log /Volumes/Expansion/iCloud导出-2026/_导出报告/日志/full-YYYYMMDD-HHMMSS.log \
    --exportdb ~/.cache/osxphotos/<导出名>-export.db \
    --out /tmp/probe_out.txt --tsv /tmp/missing_uuids.tsv
"""
import argparse, collections, datetime, json, os, re, sqlite3, subprocess, sys, time, traceback

# AppleScript 里 media item id 的固定后缀（macOS 10.15+）
ID_SUFFIX = "/L0/001"
# 对照组：已知已成功导出的资产，用于验证探针链路本身
CONTROLS = [
    ("对照组·2022/09 已导出", "E84F962B-09EF-4E7B-AF4E-6978BA66F71A"),
    ("对照组·2016/03 已导出", "CB5777C3-B79F-434B-882A-EF81E172BC84"),
]

def log(*a):
    print(time.strftime("[%H:%M:%S]"), *a, flush=True)

def core_date(v):
    """Photos.sqlite 的 Core Data 时间戳（2001-01-01 起的秒，个别版本是纳秒）→ ISO"""
    if v is None:
        return ""
    try:
        v = float(v)
        if v > 1e12:  # 纳秒
            v /= 1e9
        return (datetime.datetime(2001, 1, 1) + datetime.timedelta(seconds=v)).strftime("%Y-%m-%d %H:%M:%S")
    except Exception:
        return str(v)

# ---------- PART 1: 日志 → 缺口清单 ----------
def parse_log(path):
    pat = re.compile(r"Skipping missing original photo (.+?) \(([0-9A-F-]{36})\)")
    uuid2name = {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            m = pat.search(line)
            if m:
                uuid2name.setdefault(m.group(2), m.group(1))
    return uuid2name

# ---------- PART 2: Photos.sqlite ----------
def photos_db_scan(uuid2name, lib_path, orig_dir, tsv_path):
    """返回 uuid → dict(ZASSET 明细 + 磁盘存在性)，并写 TSV 前半部分"""
    con = sqlite3.connect(f"file:{lib_path}?immutable=1", uri=True)
    con.row_factory = sqlite3.Row
    cur = con.cursor()
    cur.execute("SELECT name FROM pragma_table_info('ZASSET')")
    cols = [r[0] for r in cur.fetchall()]
    namecol = "ZORIGINALFILENAME" if "ZORIGINALFILENAME" in cols else "ZFILENAME"
    log(f"  ZASSET 文件名列实际为: {namecol}（不同 macOS 版本 schema 有差异，别写死）")
    pick = [c for c in ("ZUUID", "ZDIRECTORY", "ZFILENAME", namecol, "ZWIDTH", "ZHEIGHT",
                        "ZKIND", "ZTRASHED", "ZHIDDEN", "ZCLOUDLOCALSTATE",
                        "ZCLOUDDOWNLOADREQUESTS", "ZADDEDDATE", "ZDATECREATED") if c in cols]
    out = {}
    stats = collections.Counter()
    for uuid, name in uuid2name.items():
        cur.execute(f"SELECT {','.join(pick)} FROM ZASSET WHERE ZUUID=?", (uuid,))
        r = cur.fetchone()
        if r is None:
            out[uuid] = {"name": name, "db": "ZASSET无记录"}
            stats["ZASSET无记录"] += 1
            continue
        d = dict(r)
        zdir, zfname = d.get("ZDIRECTORY"), d.get("ZFILENAME")
        disk_exists = False
        if zdir and zfname:
            disk_exists = os.path.exists(os.path.join(orig_dir, zdir, zfname))
        d["_disk_exists"] = disk_exists
        d["_name"] = name
        out[uuid] = d
        stats["originals在盘" if disk_exists else "originals缺文件"] += 1
        stats[f"ZCLOUDLOCALSTATE={d.get('ZCLOUDLOCALSTATE')}"] += 1
        stats[f"ZTRASHED={d.get('ZTRASHED')}"] += 1
        if not zdir or not zfname:
            stats["DB无本地路径"] += 1
    con.close()
    return out, stats, namecol

# ---------- PART 3: 同名判定 ----------
def landed_dims_map(exportdb):
    """续传库 → 文件名 → [(相对路径, 宽, 高, 字节数)]；photoinfo JSON 里的 original_width/height"""
    con = sqlite3.connect(exportdb)
    cur = con.cursor()
    cur.execute("SELECT filepath, uuid FROM export_data")
    rows = cur.fetchall()
    uuid_cache = {}
    def dims_of(uuid):
        if uuid not in uuid_cache:
            cur.execute("SELECT photoinfo FROM photoinfo WHERE uuid=?", (uuid,))
            r = cur.fetchone()
            w = h = sz = date = None
            if r and r[0]:
                try:
                    j = json.loads(r[0])
                    w = j.get("original_width"); h = j.get("original_height")
                    sz = j.get("filesize"); date = j.get("date")
                except Exception:
                    pass
            uuid_cache[uuid] = (w, h, sz, date)
        return uuid_cache[uuid]
    m = collections.defaultdict(list)
    seen = set()
    for filepath, uuid in rows:
        if not filepath or (filepath, uuid) in seen:
            continue
        seen.add((filepath, uuid))
        base = os.path.basename(filepath)
        w, h, sz, date = dims_of(uuid)
        m[base].append((filepath, w, h, sz, date))
    con.close()
    return m

def _iso_to_epoch(s):
    if not s:
        return None
    try:
        return datetime.datetime.fromisoformat(s).timestamp()
    except Exception:
        return None

def _core_to_epoch(v):
    """Photos.sqlite Core Data 时间戳（2001-01-01 UTC 起的秒，兼容纳秒）→ Unix epoch"""
    if v is None:
        return None
    try:
        v = float(v)
        if v > 1e12:
            v /= 1e9
        return v + datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc).timestamp()
    except Exception:
        return None

def same_name_verdict(uuid2name, pdb, landed, date_tol=300):
    verdicts = {}
    detail = collections.Counter()
    for uuid, name in uuid2name.items():
        d = pdb.get(uuid, {})
        w, h = d.get("ZWIDTH"), d.get("ZHEIGHT")
        miss_epoch = _core_to_epoch(d.get("ZDATECREATED"))
        cands = landed.get(name, [])
        if not cands:
            verdicts[uuid] = ("无同名", w, h, "")
            detail["无同名"] += 1
            continue
        match_eq, match_ne = [], []
        for relp, lw, lh, lsz, ldate in cands:
            if w is not None and lw == w and lh == h:
                land_epoch = _iso_to_epoch(ldate)
                if miss_epoch and land_epoch and abs(miss_epoch - land_epoch) <= date_tol:
                    match_eq.append(f"{relp}[拍摄时间吻合]")
                else:
                    match_eq.append(relp)
            else:
                match_ne.append(f"{relp}({lw}x{lh})")
        if w is None:
            verdicts[uuid] = ("同名·缺尺寸", w, h, ";".join(match_eq[:3]))
            detail["同名·缺尺寸"] += 1
        elif match_eq:
            n_time = sum(1 for c in match_eq if "拍摄时间吻合" in c)
            v = "同名同尺寸+时间吻合(重复)" if n_time else "同名同尺寸(重复嫌疑·时间不吻合)"
            verdicts[uuid] = (v, w, h, ";".join(match_eq[:3]))
            detail[v] += 1
        else:
            verdicts[uuid] = ("同名异尺寸(撞名)", w, h, ";".join(match_ne[:3]))
            detail["同名异尺寸(撞名)"] += 1
    return verdicts, detail

# ---------- PART 4: AppleScript 全量寻址扫描 ----------
APPLESCRIPT_TMPL = '''
set uuids to {%s}
set oklist to {}
tell application "Photos"
  repeat with u in uuids
    try
      if (exists media item id (u & "%s")) then set end of oklist to (contents of u)
    end try
  end repeat
end tell
set AppleScript's text item delimiters to linefeed
return oklist as text
'''

def as_sweep(uuid_list, chunk=150):
    """分块跑 exists media item id；返回可寻址 uuid 集合"""
    addressable = set()
    for i in range(0, len(uuid_list), chunk):
        part = uuid_list[i:i + chunk]
        script = APPLESCRIPT_TMPL % (",".join(f'"{u}"' for u in part), ID_SUFFIX)
        t0 = time.time()
        try:
            r = subprocess.run(["osascript", "-"], input=script, capture_output=True,
                               text=True, timeout=600)
            if r.returncode != 0:
                log(f"  块{i//chunk+1} osascript 失败({time.time()-t0:.0f}s): {r.stderr.strip()[:200]}")
                continue
            got = [x for x in r.stdout.strip().splitlines() if x]
            addressable.update(got)
            log(f"  块{i//chunk+1}: {len(part)} 个中可寻址 {len(got)} 个 ({time.time()-t0:.0f}s)")
        except Exception as e:
            log(f"  块{i//chunk+1} 异常: {type(e).__name__}: {str(e)[:150]}")
    return addressable

# ---------- main ----------
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--log", required=True, help="导出日志路径（解析 missing 清单）")
    ap.add_argument("--exportdb", required=True, help="osxphotos 续传库路径")
    ap.add_argument("--out", default="/tmp/probe_out.txt")
    ap.add_argument("--tsv", default="/tmp/missing_uuids.tsv")
    ap.add_argument("--skip-as", action="store_true", help="跳过 AppleScript 寻址扫描")
    args = ap.parse_args()

    lib_path = os.path.expanduser("~/Pictures/Photos Library.photoslibrary/database/Photos.sqlite")
    orig_dir = os.path.expanduser("~/Pictures/Photos Library.photoslibrary/originals")

    log("=" * 72)
    log("PART 1: 解析导出日志")
    uuid2name = parse_log(args.log)
    log(f"  missing UUID: {len(uuid2name)} 个（日志行去重后）")
    if not uuid2name:
        log("  日志里没有 missing 记录——检查 --log 路径是否正确")
        return

    log("=" * 72)
    log("PART 2: Photos.sqlite 全量扫描")
    pdb, stats, namecol = photos_db_scan(uuid2name, lib_path, orig_dir, args.tsv)
    for k, v in stats.most_common(20):
        log(f"    {k}: {v}")
    # 对照组的 ZASSET 状态（用于对比 ZCLOUDLOCALSTATE 等字段是否有判别力）
    con = sqlite3.connect(f"file:{lib_path}?immutable=1", uri=True)
    cur = con.cursor()
    for tag, cuuid in CONTROLS:
        cur.execute(f"SELECT ZDIRECTORY,ZFILENAME,ZWIDTH,ZHEIGHT,ZCLOUDLOCALSTATE FROM ZASSET WHERE ZUUID=?", (cuuid,))
        r = cur.fetchone()
        log(f"  [{tag}] {cuuid[:8]} → {tuple(r) if r else '无记录'}")
    con.close()

    log("=" * 72)
    log("PART 3: 同名判定（543/202 问题的全量答案）")
    landed = landed_dims_map(args.exportdb)
    log(f"  已落地件（按文件名建索引）: {sum(len(v) for v in landed.values())} 个")
    verdicts, vdetail = same_name_verdict(uuid2name, pdb, landed)
    for k, v in vdetail.most_common():
        log(f"    {k}: {v}")

    log("=" * 72)
    log("PART 4: AppleScript 全量寻址扫描")
    addressable = set()
    # 对照组先行：对照组不过，后面结果不可信
    ctrl_ok = as_sweep([u for _, u in CONTROLS])
    log(f"  对照组可寻址: {len(ctrl_ok)}/{len(CONTROLS)}" + ("" if len(ctrl_ok) == len(CONTROLS) else "  ⚠️ 对照组失败，扫描结果不可信！"))
    if len(ctrl_ok) == len(CONTROLS) and not args.skip_as:
        addressable = as_sweep(list(uuid2name))
        log(f"  729 项中 Photos 应用可寻址: {len(addressable)}")
    elif args.skip_as:
        log("  （按要求跳过）")

    # TSV 全量明细
    with open(args.tsv, "w", encoding="utf-8") as f:
        f.write("uuid\tname\tzdir\tzfname\tdisk_exists\twidth\theight\tcloud_state\tadded\tverdict\tmatched\taddressable\n")
        for uuid, name in uuid2name.items():
            d = pdb.get(uuid, {})
            verd, w, h, matched = verdicts.get(uuid, ("", "", "", ""))
            f.write("\t".join(str(x) for x in (
                uuid, name, d.get("ZDIRECTORY", ""), d.get("ZFILENAME", ""),
                d.get("_disk_exists", ""), w, h, d.get("ZCLOUDLOCALSTATE", ""),
                core_date(d.get("ZADDEDDATE")), verd, matched,
                "Y" if uuid in addressable else "N")) + "\n")
    log(f"  全量明细已写 {args.tsv}")

    log("=" * 72)
    log("PART 5: 结论汇总")
    n_disk = sum(1 for u in uuid2name if pdb.get(u, {}).get("_disk_exists"))
    log(f"  缺口总数: {len(uuid2name)}")
    log(f"  originals/ 磁盘实有文件: {n_disk}（若 >0，说明 osxphotos 的判断有漏，值得补跑）")
    log(f"  Photos 可寻址: {len(addressable)}（若 >0，可立即用 photoscript 补导出）")
    for k, v in vdetail.most_common():
        log(f"  {k}: {v}")
    log("PROBE DONE")

if __name__ == "__main__":
    try:
        main()
    except Exception:
        traceback.print_exc()
        sys.exit(2)
