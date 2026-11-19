#!/usr/bin/env python3
"""编译分阶段用时和内存峰值（优化分析 2026-11-18 CH-03）：build_app.sh 编完 swift build -c release 调它，打一行「编译分阶段：…」。

用法: python3 -I Scripts/swift_build_stats.py <time 的输出> [<stats 目录>]
  <time 的输出>  /usr/bin/time -l -o <文件> swift build … 写的那个文件：real / user / sys、maximum resident set size（字节）
  <stats 目录>   swift build … -Xswiftc -stats-output-dir -Xswiftc <目录> 写的 JSON（每个编译前端进程一份）；不给 / 是空的
                 就只打 time 那半
为什么：CI 上编译 727 秒（本机 212 秒），到底花在类型检查、SIL 优化还是 LLVM，内存是不是顶到了 runner 的 7 GB，以前日志里没有
（匿名也看不到 job 日志），复核只能拿本机时间戳推（「95% 单线程」是推断）。这里只读、只打日志，不改构建。
- 用时取前端 JSON 里的 time.swift.<阶段>.wall / .user / .instr（swift.org 6.1.2 和 6.3.2 都有这几个键，本机核对过）：
  导入（Import resolution）、类型检查（Type checking and Semantic analysis）、SILGen、SIL 优化、IRGen；前端整段是
  time.swift-frontend.<…>.wall / .user，减掉这几段剩下的记成「LLVM 和其它」（发版是整模块优化，LLVM 那段多线程、没有单独的键）。
  多个前端进程（debug 构建按文件分批）各段相加。
- 内存峰值是 time -l 的 maximum resident set size：wait4 给的是子进程树里最大的那一个（就是编译前端），不是相加。
- 打到 stdout 一行「编译分阶段：…」；GitHub Actions 上另打一条 ::notice（ci_build_annotations.py 再抄进摘要页）。
退出码总是 0：只管让人看见，读不到什么就说读不到。
"""
import glob
import json
import os
import re
import sys

PHASES = [
    ("导入", "Import resolution"),
    ("类型检查", "Type checking and Semantic analysis"),
    ("SILGen", "SILGen"),
    ("SIL 优化", "SIL optimization"),
    ("IRGen", "IRGen"),
]


def read_time(path):
    """/usr/bin/time -l 的输出 → {real, user, sys, maxrss, faults}（读不到的没有那个键）。"""
    out = {}
    try:
        text = open(path, encoding="utf-8", errors="replace").read()
    except OSError:
        return out
    m = re.search(r"([\d.]+)\s+real\s+([\d.]+)\s+user\s+([\d.]+)\s+sys", text)
    if m:
        out["real"], out["user"], out["sys"] = (float(x) for x in m.groups())
    m = re.search(r"^\s*(\d+)\s+maximum resident set size", text, re.M)
    if m:
        out["maxrss"] = int(m.group(1))
    m = re.search(r"^\s*(\d+)\s+page faults", text, re.M)
    if m:
        out["faults"] = int(m.group(1))
    return out


def read_stats(directory):
    """→ (前端进程数, {阶段: [wall, user, instr]}, 前端整段 [wall, user, instr])。"""
    phases = {name: [0.0, 0.0, 0.0] for name, _ in PHASES}
    total = [0.0, 0.0, 0.0]
    procs = 0
    for path in sorted(glob.glob(os.path.join(directory, "*.json"))):
        try:
            data = json.load(open(path, encoding="utf-8"))
        except (OSError, ValueError):
            continue
        whole = [k for k in data if k.startswith("time.swift-frontend.") and k.endswith(".wall")]
        if not whole:
            continue          # 驱动自己的那份、或者别的工具的
        procs += 1
        base = whole[0][:-len(".wall")]
        for i, suffix in enumerate(("wall", "user", "instr")):
            total[i] += float(data.get(f"{base}.{suffix}", 0) or 0)
        for name, key in PHASES:
            for i, suffix in enumerate(("wall", "user", "instr")):
                phases[name][i] += float(data.get(f"time.swift.{key}.{suffix}", 0) or 0)
    return procs, phases, total


def fmt_s(x):
    return f"{x:.0f}s" if x >= 10 else f"{x:.1f}s"


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith("-"):
        print(__doc__)
        return 0
    t = read_time(args[0])
    parts = []
    if "real" in t:
        parts.append(f"real {fmt_s(t['real'])}、user {fmt_s(t['user'])}、sys {fmt_s(t['sys'])}")
    if "maxrss" in t:
        parts.append(f"内存峰值 {t['maxrss'] / 2**30:.2f} GB")
    if "faults" in t:
        parts.append(f"缺页 {t['faults']} 次")
    if not t:
        parts.append(f"没读到 time 的输出（{args[0]}）")
    if len(args) > 1:
        procs, phases, total = read_stats(args[1])
        if procs:
            named = sum(v[0] for v in phases.values())
            seg = "、".join(f"{name} {fmt_s(phases[name][0])}" for name, _ in PHASES)
            seg += f"、LLVM 和其它 {fmt_s(max(total[0] - named, 0))}"
            instr = f"，{total[2] / 1e8:.0f} 亿条指令" if total[2] else ""
            parts.append(f"前端 {procs} 个进程（wall）：{seg}；前端合计 wall {fmt_s(total[0])}、user {fmt_s(total[1])}{instr}")
        else:
            parts.append(f"{args[1]} 里没有编译前端的 stats JSON（构建没走到编译那一步，或者 -stats-output-dir 没生效）")
    line = "编译分阶段：" + "；".join(parts)
    print(line)
    if os.environ.get("GITHUB_ACTIONS") == "true":
        msg = line.split("：", 1)[1].replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
        print(f"::notice title=编译分阶段（swift build -c release）::{msg}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
