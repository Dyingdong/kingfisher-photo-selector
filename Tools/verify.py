#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
FocusScreener 结果验证工具。

「结果正确」不是看通过率，而是分四层各自拿到证据：

  truth    <报告.csv>              拿你自己肉眼标注的真值算混淆矩阵、误杀/漏检、建议灵敏度
  drift    <照片文件夹>            检验「同一张照片换个批次会不会翻判」（P75 自标定的固有风险）
  degrade  <一张清晰照片>          生成模糊梯度，检验锐度分数与判定是否随模糊单调变化
  bytes    <照片文件夹>            检验写入的 XMP 是否合法、字段齐全、原片结构未被破坏

用法: python3 verify.py <子命令> --help
"""

import argparse
import csv
import os
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / "focuscli"

SUSPECT = {"疑似全片模糊", "疑似主体失焦", "疑似景深不足"}
UNCERTAIN = {"运动模糊/拖影", "无法解码"}
DC = "http://purl.org/dc/elements/1.1/"
RDF = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
XMP = "http://ns.adobe.com/xap/1.0/"
PS = "http://ns.adobe.com/photoshop/1.0/"
XMP_HDR = b"http://ns.adobe.com/xap/1.0/\x00"


def read_report(path):
    with open(path, "r", encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f))


def run_cli(paths, sensitivity=1.0, out=None, extra=None):
    if not CLI.exists():
        sys.exit(f"找不到 {CLI}，请先执行 ./build.sh")
    cmd = [str(CLI)] + [str(p) for p in paths] + ["-s", str(sensitivity)]
    if extra:
        cmd += extra
    if out:
        cmd += ["-o", str(out)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("focuscli 运行失败：" + r.stderr.strip())
    return r.stdout if not out else read_report(out)


def num(row, key):
    try:
        return float(row.get(key, ""))
    except (TypeError, ValueError):
        return 0.0


def classify(row, hi_min):
    """与 Sources/Analyze.swift 的 classify() 逐条对应，用于离线复算判定。

    阈值由 50 张真实 RAW + 人工真值标定：召回 13/13，误杀 1/37。
    """
    hi, an = num(row, "最锐区P99"), num(row, "方向性")
    f, g, h = num(row, "判定用锐度比"), num(row, "中心锐度比"), num(row, "主体锐度比")
    reblur, soft = num(row, "主体重模糊比"), num(row, "偏软占比")
    margin = num(row, "基准余量")
    src = row.get("主体定位", "")
    if hi <= 0:
        return "无法解码"
    if an > 2.2 and (soft > 0.85 or hi < hi_min):
        return "运动模糊/拖影"
    if margin < 1 or hi < hi_min:
        return "疑似全片模糊"
    if src == "前景主体":
        if g - f > 0.03 and f < 0.25:
            return "疑似主体失焦"
        if f < 0.10 and reblur < 0.12 and soft < 0.85:
            return "疑似主体失焦"
    elif src == "显著性区域":
        if h > 0.105 and f < 0.25:
            return "疑似主体失焦"
    elif f < 0.35:
        return "疑似主体失焦"
    return "通过"


def parse_truth(s):
    s = (s or "").strip().lower()
    reject = ("废", "差", "糊", "失焦", "弃", "reject", "bad", "blur")
    keep = ("好", "清晰", "保留", "合焦", "keep", "ok", "good", "sharp", "pass")
    # 真值常带人工备注，如「废，但是画面整体有点模糊」「好、手动对焦」
    for k in reject:
        if s.startswith(k) or s.endswith(k):
            return "废"
    for k in keep:
        if s.startswith(k) or s.endswith(k):
            return "好"
    if s in ("0", "no"):
        return "废"
    return None


# ---------------------------------------------------------------- truth

def cmd_truth(args):
    rows = read_report(args.report)
    if not rows:
        sys.exit("报告为空")

    sens_cols = [num(r, "灵敏度") for r in rows if num(r, "灵敏度") > 0]
    sens = sens_cols[0] if sens_cols else 1.0
    hi_min_1 = num(rows[0], "批次基准") / sens if sens else 1.0

    # 自检：用报告里的数值离线复算，必须与报告判定完全对得上
    mismatch = [r["文件名"] for r in rows
                if classify(r, hi_min_1 * sens) != r["判定"]]
    print(f"离线复算：{len(rows) - len(mismatch)}/{len(rows)} 条与报告判定一致"
          + ("" if not mismatch else f"，不一致：{', '.join(mismatch[:5])}"))
    if mismatch:
        print("  ⚠ 判定不可复现，先检查报告是否由旧版本导出，或该图做过人工圈选。")

    labeled = [(r, parse_truth(r.get("人工真值"))) for r in rows]
    labeled = [(r, t) for r, t in labeled if t]
    # 运动模糊 / 无法解码是独立类别，不属于「失焦」这一任务，不进混淆矩阵
    uncertain = [r for r in rows if r["判定"] in UNCERTAIN]
    labeled_bad_but_separate = [(r, t) for r, t in labeled
                                if t == "废" and r["判定"] in UNCERTAIN]
    labeled = [(r, t) for r, t in labeled if r["判定"] not in UNCERTAIN]
    skipped = len(rows) - len(labeled)
    if not labeled:
        print(f"\n还没有人工真值：{skipped} 张全部未标注。")
        print("请在 CSV 的「人工真值」列填 好 / 废（至少各 10 张，且要包含临界片），再运行本命令。")
        print("标注时请 100% 放大看主体，先标再看「判定」列，避免被机器结果带偏。")
        return

    tp = fp = fn = tn = 0
    fp_rows, fn_rows = [], []
    for r, t in labeled:
        hit = r["判定"] in SUSPECT
        if t == "废" and hit:
            tp += 1
        elif t == "废":
            fn += 1
            fn_rows.append(r)
        elif t == "好" and hit:
            fp += 1
            fp_rows.append(r)
        else:
            tn += 1
    bad = sum(1 for _, t in labeled if t == "废")
    good = len(labeled) - bad
    total = len(labeled)

    print(f"\n人工标注 {total} 张（好 {good} / 废 {bad}），未标注 {skipped} 张跳过")
    print(f"{'':16}{'机器判疑似':>12}{'机器放行':>12}")
    print(f"{'人工判废(应筛出)':<14}{tp:>12}{fn:>12}   ← 漏检")
    print(f"{'人工判好(应保留)':<14}{fp:>12}{tn:>12}   ← 误杀")
    if total:
        print(f"\n准确率 {(tp + tn) / total * 100:.1f}%   "
              f"误杀率 {(fp / good * 100) if good else 0:.1f}%（好片里）   "
              f"漏检率 {(fn / bad * 100) if bad else 0:.1f}%（废片里）")
    if uncertain:
        print(f"另有 {len(uncertain)} 张被单独归为运动模糊/无法解码，不计入上表，需你人工确认。")
    if labeled_bad_but_separate:
        print(f"其中 {len(labeled_bad_but_separate)} 张你标为「废」：属拖影/解码问题而非失焦，"
              "界面里是橙色独立类别，请另行质检。")

    def show(title, items):
        if not items:
            return
        print(f"\n{title}（{len(items)} 张，优先 100% 放大复核）")
        for r in items[:args.detail]:
            print(f"  {r['文件名'][:38]:<38} 判定={r['判定']:<8} "
                  f"基准余量={num(r, '基准余量'):.2f} "
                  f"锐度比={num(r, '判定用锐度比'):.2f}  {r['判定原因'][:40]}")

    show("[漏检] 废片被放行", fn_rows)
    show("[误杀] 好片被判疑似", fp_rows)

    # 临界样本：靠近任一判定边界，最值得人工看
    def closeness(r):
        return min(abs(num(r, "基准余量") - 1.0),
                   abs(num(r, "判定用锐度比") - 0.35) / 0.35)
    border = sorted(rows, key=closeness)[:args.detail]
    print(f"\n[临界样本] 最靠近判定边界的 {len(border)} 张（不论机器判了什么，都建议先看）")
    for r in border:
        print(f"  {r['文件名'][:38]:<38} 基准余量={num(r, '基准余量'):.2f} "
              f"锐度比={num(r, '判定用锐度比'):.2f} 判定={r['判定']}")
    if rows and closeness(border[0]) > 0.25:
        print("  ⚠ 这批里没有真正贴近判定边界的照片（数值都离阈值很远）。"
              "补几张轻微脱焦 / 浅景深 / 临界合焦的片，否则验证不出阈值是否合适。")

    # 扫描灵敏度：hiMin 与灵敏度成正比，可纯离线重算，无需重新解图
    print("\n[灵敏度扫描] 按「误杀 + 2×漏检」最小打分（漏检废片代价按两倍计）")
    best = None
    zero_fp = zero_fn = None
    outcomes = set()
    for k in range(10, 41):
        s = k / 20.0
        f = n = 0
        for r, t in labeled:
            hit = classify(r, hi_min_1 * s) in SUSPECT
            if t == "废" and not hit:
                n += 1
            elif t == "好" and hit:
                f += 1
        score = f + 2 * n
        outcomes.add((f, n))
        if best is None or score < best[0]:
            best = (score, s, f, n)
        if f == 0 and (zero_fp is None or s < zero_fp):
            zero_fp = s
        if n == 0 and (zero_fn is None or s > zero_fn):
            zero_fn = s
    _, s_best, f_best, n_best = best
    print(f"  当前 {sens:.2f}  →  建议 {s_best:.2f}（误杀 {f_best}，漏检 {n_best}）")
    if zero_fp is not None:
        print(f"  若绝不误杀好片：灵敏度 ≤ {zero_fp:.2f}")
    if zero_fn is not None:
        print(f"  若绝不漏掉废片：灵敏度 ≥ {zero_fn:.2f}")
    if len(outcomes) == 1:
        print("  ⚠ 所有灵敏度下误杀/漏检都相同 → 这批样本缺少临界片，"
              "扫描无法区分阈值，请补充轻微失焦的样片再标定。")
    print("  注意：这个建议只对你标注的这批样本成立；换机型 / 换题材要重新标。")


# ---------------------------------------------------------------- drift

def cmd_drift(args):
    from PIL import Image, ImageFilter

    folder = Path(args.folder).resolve()
    anchor_args = ["-a", str(Path(args.anchor).resolve())] if args.anchor else []
    with tempfile.TemporaryDirectory(prefix="fs_drift_") as td:
        base_csv = Path(td) / "base.csv"
        mix_csv = Path(td) / "mix.csv"
        base = run_cli([folder], 1.0, out=base_csv, extra=anchor_args)
        if not base:
            sys.exit("该文件夹没有可分析的照片")
        src = max(base, key=lambda r: num(r, "最锐区P99"))
        photo = src.get("完整路径") or str(folder / src["文件名"])

        blur_dir = Path(td) / "extra"
        blur_dir.mkdir()
        im = Image.open(photo).convert("RGB")
        for k in range(args.extra):
            radius = 2.0 + k * 0.7
            im.filter(ImageFilter.GaussianBlur(radius)).save(
                blur_dir / f"_drift_{k:02d}.jpg", quality=92)

        mixed = run_cli([folder, blur_dir], 1.0, out=mix_csv, extra=anchor_args)
        by_path = {r.get("完整路径", r["文件名"]): r for r in mixed}

        base_min = num(base[0], "批次基准")
        mix_min = num(mixed[0], "批次基准") if mixed else 0
        changed = []
        for r in base:
            other = by_path.get(r.get("完整路径", r["文件名"]))
            if other and other["判定"] != r["判定"]:
                changed.append((r["文件名"], r["判定"], other["判定"]))

        delta = abs(mix_min / max(base_min, 1e-6) - 1)
        print(f"原批 {len(base)} 张，追加 {args.extra} 张模糊片后共 {len(mixed)} 张"
              f"（基准模式：{'固定锚点' if args.anchor else '独立固定阈值'}）")
        label = "固定基准（参考片×0.15）" if args.anchor else "独立判定基准（固定阈值）"
        print(f"{label}：{base_min:.1f} → {mix_min:.1f}"
              f"（变化 {(mix_min / max(base_min, 1e-6) - 1) * 100:+.1f}%）")
        print(f"原批中判定发生翻转：{len(changed)} 张")
        for n, a, b in changed[:15]:
            print(f"  {n[:44]:<44} {a} → {b}")
        if delta > 0.30 and not changed:
            print(f"\n⚠ 基准数值变化达 {delta * 100:.0f}%，请检查是否启用了锚点或旧版报告。")
        if changed:
            print("\n⚠ 独立阈值模式下同一张照片判定不应因增删其他照片而改变；"
                  "若出现翻转，检查灵敏度、锚点或比较的报告是否来自旧版本。")
        elif args.anchor:
            print("\n固定锚点模式下基准由参考片决定，不随本批构成变化，判定可跨批复现。")
        else:
            print("判定基准不随同批照片构成变化：增删照片、换批次后同一张图的结论保持一致。")


# ---------------------------------------------------------------- degrade

def cmd_degrade(args):
    from PIL import Image, ImageFilter

    photo = Path(args.photo).resolve()
    if not photo.exists():
        sys.exit(f"文件不存在：{photo}")
    im = Image.open(photo).convert("RGB")
    with tempfile.TemporaryDirectory(prefix="fs_deg_") as td:
        d = Path(td)
        radii = [0.0] + [round(0.5 * k, 1) for k in range(1, args.steps + 1)]
        for k, r in enumerate(radii):
            out = im if r == 0 else im.filter(ImageFilter.GaussianBlur(r))
            out.save(d / f"r{k:02d}.jpg", quality=95)
        rep = Path(td) / "out.csv"
        rows = run_cli([d], 1.0, out=rep)

    print(f"源图：{photo.name}（{im.width}×{im.height}）")
    print(f"{'模糊半径':>8} {'最锐区P99':>12} {'基准余量':>10} {'锐度比':>9}  判定")
    print("-" * 68)
    hi_prev, first_suspect = None, None
    nonmono = 0
    for r, rad in zip(rows, radii):
        hi = num(r, "最锐区P99")
        if hi_prev is not None and hi > hi_prev * 1.02:
            nonmono += 1
        hi_prev = hi
        hit = r["判定"] in SUSPECT
        if hit and first_suspect is None:
            first_suspect = rad
        print(f"{rad:>8.1f} {hi:>12.1f} {num(r, '基准余量'):>10.2f} "
              f"{num(r, '判定用锐度比'):>9.2f}  {r['判定']}")
    flags = [r["判定"] in SUSPECT for r in rows]
    flip = sum(1 for a, b in zip(flags, flags[1:]) if a != b)
    print("-" * 68)
    print(f"锐度分数非单调次数：{nonmono}（应为 0；>0 说明分数受 JPG 压缩噪声干扰）")
    print(f"判定翻转次数：{flip}（应为 1；>1 说明判定在边界附近来回跳）")
    print(f"机器拐点：模糊半径 {first_suspect if first_suspect is not None else '未触发'}")
    print("\n怎么用：把这排图在 Bridge / 预览里 100% 排着看，记下你肉眼开始觉得「糊了」的半径。")
    print("  肉眼看不清的半径 明显小于 机器拐点 → 工具偏迟钝，调高灵敏度；")
    print("  肉眼看不清的半径 明显大于 机器拐点 → 工具过度敏感，调低灵敏度。")
    print("  注：整批都是同一张图的退化版本，基准会被拉低；此表主要看单调性与相对拐点。")


# ---------------------------------------------------------------- bytes

def jpeg_segments(data):
    """返回 (marker, payload) 列表与 SOS 后的压缩数据偏移。"""
    segs, i, sos = [], 2, None
    if len(data) < 4 or data[0] != 0xFF or data[1] != 0xD8:
        return segs, None
    while i + 3 < len(data):
        if data[i] != 0xFF:
            break
        m = data[i + 1]
        if m == 0xD8 or 0xD0 <= m <= 0xD7:
            i += 2
            continue
        if m == 0xDA:
            sos = i
            break
        if m == 0xD9:
            break
        length = (data[i + 2] << 8) | data[i + 3]
        if length < 2 or i + 2 + length > len(data):
            break
        segs.append((m, data[i + 4:i + 2 + length]))
        i += 2 + length
    return segs, sos


def xmp_fields(text):
    root = ET.fromstring(text)
    kws = [e.text or "" for e in root.findall(f".//{{{DC}}}subject//{{{RDF}}}li")]
    desc = " ".join(e.text or "" for e in root.findall(f".//{{{DC}}}description//{{{RDF}}}li"))
    ins = " ".join(e.text or "" for e in root.findall(f".//{{{PS}}}Instructions"))
    label = " ".join(e.text or "" for e in root.findall(f".//{{{XMP}}}Label"))
    return kws, desc, ins, label


def cmd_bytes(args):
    folder = Path(args.folder).resolve()
    jpg_ext = {".jpg", ".jpeg", ".jpe", ".jfif"}
    raw_ext = {".arw", ".cr2", ".cr3", ".nef", ".dng", ".raf", ".rw2", ".orf",
               ".3fr", ".fff", ".iiq", ".pef", ".srw", ".x3f", ".raw", ".rwl"}
    checked = {"jpg": 0, "raw": 0}
    problems = []

    for p in sorted(folder.rglob("*")):
        if not p.is_file() or p.name.startswith("."):
            continue
        ext = p.suffix.lower()
        data = p.read_bytes()
        if ext in jpg_ext:
            checked["jpg"] += 1
            segs, sos = jpeg_segments(data)
            xmps = [pl[len(XMP_HDR):].decode("utf-8", "replace")
                    for m, pl in segs if m == 0xE1 and pl.startswith(XMP_HDR)]
            if not xmps:
                continue  # 未打标签的照片，正常
            if len(xmps) != 1:
                problems.append(f"{p.name}: 有 {len(xmps)} 个 XMP 段（重复写入）")
            if sos is None or not data.rstrip().endswith(b"\xff\xd9"):
                problems.append(f"{p.name}: JPEG 结构不完整（缺 SOS 或 EOI）")
            has_exif = any(m == 0xE1 and pl.startswith(b"Exif\x00\x00")
                           for m, pl in segs)
            try:
                kws, desc, ins, label = xmp_fields(xmps[0])
            except ET.ParseError as e:
                problems.append(f"{p.name}: XMP 不是合法 XML（{e}）")
                continue
            if "失焦" not in kws:
                problems.append(f"{p.name}: 缺关键词「失焦」")
            if "[失焦质检]" not in desc or "[失焦质检]" not in ins:
                problems.append(f"{p.name}: 缺判定原因说明")
            print(f"  JPG {p.name[:40]:<40} XMP段={len(xmps)} "
                  f"关键词={'失焦' if '失焦' in kws else '缺失':<4} "
                  f"说明={'有' if '[失焦质检]' in desc else '缺失'} "
                  f"标签={label or '无':<6} Exif保留={'是' if has_exif else '原本无'}")
        elif ext in raw_ext:
            checked["raw"] += 1
            side = p.with_suffix(".xmp")
            if not side.exists():
                continue
            try:
                kws, desc, ins, label = xmp_fields(side.read_text(encoding="utf-8"))
            except (ET.ParseError, UnicodeDecodeError) as e:
                problems.append(f"{p.name}: 侧车不是合法 XMP（{e}）")
                continue
            if "失焦" not in kws:
                problems.append(f"{p.name}: 侧车缺关键词「失焦」")
            print(f"  RAW {p.name[:40]:<40} 侧车=有 "
                  f"关键词={'失焦' if '失焦' in kws else '缺失':<4} "
                  f"原片={len(data):,} 字节（不写入）")

    print(f"\n检查 {checked['jpg']} 张 JPG / {checked['raw']} 张 RAW")
    if problems:
        print(f"发现 {len(problems)} 个问题：")
        for x in problems[:30]:
            print("  ⚠ " + x)
    else:
        print("未发现元数据问题：XMP 合法、字段齐全、无重复段、JPEG/RAW 结构完整。")
    print("提示：这能证明「写进去的东西正确、原片结构没坏」，但不能自证图像字节零改动；"
          "字节级零改动由 Tests/meta_test.swift 的写入前后对照测试覆盖。")
    if args.backup:
        b = Path(args.backup).resolve()
        before = list(b.glob("*.before.xmp")) if b.exists() else []
        print(f"另有备份目录 {b}：{len(before)} 份写入前 XMP，可用于比对已有关键词是否被覆盖。")


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description="FocusScreener 结果验证工具")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("truth", help="用人工真值算混淆矩阵、临界样本、建议灵敏度")
    p.add_argument("report")
    p.add_argument("--detail", type=int, default=8)
    p.set_defaults(func=cmd_truth)

    p = sub.add_parser("drift", help="检验判定是否依赖批次构成")
    p.add_argument("folder")
    p.add_argument("--extra", type=int, default=10)
    p.add_argument("--anchor", default="", help="指定固定基准参考片，验证漂移是否被消除")
    p.set_defaults(func=cmd_drift)

    p = sub.add_parser("degrade", help="模糊梯度：检验分数与判定的单调性和拐点")
    p.add_argument("photo")
    p.add_argument("--steps", type=int, default=12)
    p.set_defaults(func=cmd_degrade)

    p = sub.add_parser("bytes", help="检查写入的 XMP 是否合法、字段齐全、结构完好")
    p.add_argument("folder")
    p.add_argument("--backup", default="")
    p.set_defaults(func=cmd_bytes)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
