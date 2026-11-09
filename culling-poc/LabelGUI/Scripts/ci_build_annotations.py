#!/usr/bin/env python3
"""构建日志 → GitHub 摘要页（CI「构建日志 → annotation」那一步，构建成功、失败都跑）。

用法: python3 -I Scripts/ci_build_annotations.py <build.log> [--failed]
  --failed  构建那一步红了：另把前几个编译错误（带文件、行号）和 build.log 末尾 60 行写成 ::error

为什么要它：本机 gh 没登录，匿名拿不到 job 日志；构建那一步以前什么 annotation 都不发，编译警告、失败原因、
各阶段用时在摘要页上一样都看不见（11-04 那次构建失败到现在不知道原因）。annotation 和 $GITHUB_STEP_SUMMARY
不登录也看得到。
- 编译警告（swift / clang 的「路径:行:列: warning: …」）去重以后转成 ::warning，链到文件和行；GitHub 每一步每种
  annotation 只收 10 条，多出来的只进摘要（摘要里全列，最多 200 条）。build_app.sh 自己的「!! …」（比如 Finder 排版失败、
  CI 常见）也算一条警告。
- 各阶段用时 build_app.sh 退出时自己打 ::notice（「各阶段用时：…」那一行），这里抄进摘要。
- SwiftPM 的缓存命中、源码没变时不重编，那一次就没有编译警告（不是没有警告）。
退出码总是 0：构建红没红由构建那一步自己定，这一步只负责让人看得见。
"""
import os
import re
import sys

WARN_LIMIT = 10      # GitHub：每一步每种 annotation 最多 10 条，多的丢掉
ERROR_LIMIT = 5      # 前几个编译错误各一条，再加一条末尾 60 行
TAIL_LINES = 60
SUMMARY_LIMIT = 200
LINE_CUT = 240

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
# /abs/path/File.swift:12:5: warning: msg [#Group]；没有列号的也认（ld、部分 clang）。前面不许有空白和「|」：
# 新编译器在诊断下面画的源码框（「 |   `- warning: …」）是同一条的重复，不算。
DIAG = re.compile(r"^(?P<file>[^\s|:][^:]*):(?P<line>\d+):(?:(?P<col>\d+):)?\s*(?P<kind>warning|error):\s*(?P<msg>.+)$")
# 没有文件的：「ld: warning: …」「warning: …」「error: …」（swift build、uv 都这样打）。
BARE = re.compile(r"^(?:(?P<tool>[\w.+-]+):\s+)?(?P<kind>warning|error):\s*(?P<msg>.+)$")


def esc_data(s):
    return s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def esc_prop(s):
    return esc_data(s).replace(":", "%3A").replace(",", "%2C")


def rel(path, workspace):
    if workspace and path.startswith(workspace.rstrip("/") + "/"):
        return path[len(workspace.rstrip("/")) + 1:]
    return path


def parse(lines, workspace):
    """→ (warnings, errors)：每条 (file|None, line|None, col|None, msg, title)，按第一次出现的顺序、去重。"""
    seen = set()
    warnings, errors = [], []
    for raw in lines:
        line = ANSI.sub("", raw.rstrip("\n"))
        hit = None
        m = DIAG.match(line)
        if m:
            hit = (m["kind"], rel(m["file"], workspace), int(m["line"]), int(m["col"]) if m["col"] else None,
                   m["msg"].strip(), "编译" + ("警告" if m["kind"] == "warning" else "错误"))
        else:
            m = BARE.match(line)
            if m:
                tool = m["tool"] + " " if m["tool"] else "构建"
                hit = (m["kind"], None, None, None, m["msg"].strip(), tool + ("警告" if m["kind"] == "warning" else "错误"))
            elif line.startswith("!! "):
                hit = ("warning", None, None, None, line[3:].strip(), "build_app.sh")
        if not hit:
            continue
        kind, f, ln, col, msg, title = hit
        key = (kind, f, ln, col, msg)
        if key in seen:
            continue
        seen.add(key)
        (warnings if kind == "warning" else errors).append((f, ln, col, msg, title))
    return warnings, errors


def command(kind, item):
    f, ln, col, msg, title = item
    props = []
    if f:
        props.append("file=" + esc_prop(f))
        if ln:
            props.append(f"line={ln}")
        if col:
            props.append(f"col={col}")
    props.append("title=" + esc_prop(title))
    return f"::{kind} {','.join(props)}::{esc_data(msg[:LINE_CUT * 2])}"


def where(item):
    f, ln, col, _, _ = item
    if not f:
        return ""
    return f"{f}:{ln}" + (f":{col}" if col else "")


def main():
    args = sys.argv[1:]
    if not args or args[0].startswith("-"):
        print(__doc__)
        return 0
    path, failed = args[0], "--failed" in args[1:]
    workspace = os.environ.get("GITHUB_WORKSPACE", os.getcwd())
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    out = []         # 打到 stdout 的（annotation 命令 + 给登录的人看的全文）
    summary = ["### 构建（build_app.sh）", ""]
    if not os.path.isfile(path):
        # 构建那一步根本没起来（前面的步骤就红了）：没有日志可看，照实说。
        msg = f"没有 {path}：构建那一步没跑起来（看前面哪一步红了）"
        print(f"::warning title=构建日志::{esc_data(msg)}")
        summary.append(msg)
        write_summary(summary_path, summary)
        return 0
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.readlines()
    warnings, errors = parse(lines, workspace)
    stages = next((ANSI.sub("", l).strip() for l in reversed(lines) if l.startswith("各阶段用时：")), None)

    summary.append(f"- 结果：{'**失败**' if failed else '成功'}")
    summary.append(f"- {stages}" if stages else "- 各阶段用时：日志里没有（build_app.sh 没走到退出那一下？）")
    summary.append(f"- 警告 {len(warnings)} 条（去重后；源码没变、SwiftPM 缓存命中时不重编，就没有编译警告）")

    shown = warnings if len(warnings) <= WARN_LIMIT else warnings[:WARN_LIMIT - 1]
    for item in shown:
        out.append(command("warning", item))
    if len(shown) < len(warnings):
        rest = len(warnings) - len(shown)
        out.append(f"::warning title=警告还有 {rest} 条::{esc_data(f'GitHub 每一步只收 10 条 annotation：全部 {len(warnings)} 条列在摘要页「构建」那一段')}")
    if warnings:
        summary += ["", "| 位置 | 警告 |", "|---|---|"]
        for item in warnings[:SUMMARY_LIMIT]:
            summary.append(f"| {('`' + where(item) + '`') if where(item) else item[4]} | {md_cell(item[3])} |")
        if len(warnings) > SUMMARY_LIMIT:
            summary.append(f"| … | 还有 {len(warnings) - SUMMARY_LIMIT} 条 |")

    if failed:
        for item in errors[:ERROR_LIMIT]:
            out.append(command("error", item))
        tail = [ANSI.sub("", l.rstrip("\n"))[:LINE_CUT] for l in lines[-TAIL_LINES:]]
        out.append("::error title=构建失败（build.log 末尾 %d 行）::%s" % (len(tail), esc_data("\n".join(tail))))
        if errors:
            summary += ["", f"编译错误 {len(errors)} 条（前 {min(len(errors), ERROR_LIMIT)} 条另有 annotation）：", ""]
            for item in errors[:SUMMARY_LIMIT]:
                summary.append(f"- `{where(item)}` {md_cell(item[3])}" if where(item) else f"- {md_cell(item[3])}")
        summary += ["", f"build.log 末尾 {len(tail)} 行：", "", "```text", *tail, "```"]

    for line in out:
        print(line)
    write_summary(summary_path, summary)
    print(f"构建日志：警告 {len(warnings)} 条，错误 {len(errors)} 条" + (f"；{stages}" if stages else ""))
    return 0


def md_cell(s):
    return s.replace("|", "\\|").replace("\n", " ")[:LINE_CUT * 2]


def write_summary(path, lines):
    if not path:
        return
    with open(path, "a", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    sys.exit(main())
