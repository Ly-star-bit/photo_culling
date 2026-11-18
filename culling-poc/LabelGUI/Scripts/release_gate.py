#!/usr/bin/env python3
"""发版门禁（优化分析 2026-11-18，ops 复核「漏 3」）：推 v* tag 时 release.yml 的 release-gate job 跑它，红了不发 Release。

用法: python3 -I culling-poc/LabelGUI/Scripts/release_gate.py <tag>          # 比如 v1.33.0；打 tag 之前本机先跑一遍
      python3 -I culling-poc/LabelGUI/Scripts/release_gate.py <tag> --root <仓库根>   # 查别处的一份（默认是这个脚本所在的仓库）
      python3 -I culling-poc/LabelGUI/Scripts/release_gate.py --self-test    # 判断规则自测（CI 每次完整跑都跑）

查两件事，哪件不对都是红（退出码 1），不是只告警：
  1. release-notes/<tag>.md 在、而且不是空的。以前不在时 release job 不报错，Release 正文悄悄只剩自动生成的提交对比。
  2. WhatsNew.swift 里那张表的版本号（Notes(version: "X.Y.Z")）和 tag 的主、次版本号一样，而且不比 tag 新：
     - 比 tag 新（表写 1.34.0、发 v1.33.0）：WhatsNew.shouldShow 在 app 版本比表旧时不弹，升级到这一版的人永远看不到；
     - 主次版本对不上（发 v1.33.0、表还是 1.32.0）：忘了换表，从 1.32.x 升上来的人什么都不弹（记过 1.32.0，表不比它新）；
     - 补丁版（v1.31.1、v1.31.2）表留着 1.31.0 是对的：同一个次版本的补丁不用每次换表（换成 1.31.1 也行）。
为什么红、不是告警：发版是按流程打 tag，没人盯 tag 那次 run 的摘要页，一条 ::warning 等于没有；等 Release 发出去才看到就晚了。
红了怎么办：补上 release-notes/<tag>.md / 换 WhatsNew 的表，提交、推 feature 等绿、合 main，再把 tag 打到新的提交上
（新提交没绿过的话 tag 那次会完整跑一遍再发）。README 跟没跟上不在这里查。
"""
import os
import re
import sys
import tempfile

NOTES_DIR = "release-notes"
WHATSNEW = os.path.join("culling-poc", "LabelGUI", "Sources", "LabelGUI", "WhatsNew.swift")
TAG = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
TABLE = re.compile(r'\bNotes\(\s*version:\s*"([^"]*)"')
VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")


def check(tag, root):
    """→ 问题清单（空 = 过）。每条一句话，说哪里不对、怎么改。"""
    problems = []
    m = TAG.match(tag)
    if not m:
        return [f"tag「{tag}」不是 vX.Y.Z 的写法（build_app.sh / restamp 都按它取版本号）"]
    want = tuple(int(x) for x in m.groups())

    notes = os.path.join(root, NOTES_DIR, f"{tag}.md")
    if not os.path.isfile(notes):
        problems.append(f"没有 {NOTES_DIR}/{tag}.md：每个 tag 配一份发布说明（Release 正文就是它），写好提交再打 tag")
    else:
        with open(notes, encoding="utf-8", errors="replace") as fh:
            if not fh.read().strip():
                problems.append(f"{NOTES_DIR}/{tag}.md 是空的")

    path = os.path.join(root, WHATSNEW)
    if not os.path.isfile(path):
        problems.append(f"没有 {WHATSNEW}（「这一版新增」的表）")
        return problems
    with open(path, encoding="utf-8", errors="replace") as fh:
        found = TABLE.findall(fh.read())
    if len(found) != 1:
        problems.append(f"{WHATSNEW} 里找到 {len(found)} 处 Notes(version: \"…\")，应该正好 1 处（表的写法改了就改这个脚本的 TABLE）")
        return problems
    v = VERSION.match(found[0].strip())
    if not v:
        problems.append(f"WhatsNew 的表版本号「{found[0]}」不是 X.Y.Z")
        return problems
    have = tuple(int(x) for x in v.groups())
    table = ".".join(map(str, have))
    if have > want:
        problems.append(f"WhatsNew 的表是 {table}，比 {tag} 还新：装这一版的人永远不弹（app 版本比表旧就不弹）。"
                        f"表的版本号改成 {want[0]}.{want[1]}.x（x ≤ {want[2]}）")
    elif have[:2] != want[:2]:
        problems.append(f"WhatsNew 的表还是 {table}，{tag} 要换成 {want[0]}.{want[1]}.x 的新表（忘了换的话从 "
                        f"{have[0]}.{have[1]} 升上来的人什么都不弹）：整张换掉、version 跟着改")
    return problems


def report(tag, problems):
    gha = os.environ.get("GITHUB_ACTIONS") == "true"
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    lines = [f"### 发版门禁 {tag}", ""]
    if problems:
        for p in problems:
            print(f"FAIL {p}")
            if gha:
                print("::error title=发版门禁::" + p.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A"))
            lines.append(f"- 不行：{p}")
        lines += ["", "Release 不发。改好、提交、推 feature 等绿、合 main，再把 tag 打到新提交上。"]
    else:
        print(f"PASS 发版门禁 {tag}：{NOTES_DIR}/{tag}.md 在，WhatsNew 的表和 {tag} 的主次版本号对得上")
        lines.append(f"- 过：{NOTES_DIR}/{tag}.md 在，WhatsNew 的表对得上")
    if summary:
        with open(summary, "a", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")


def self_test():
    """造假的仓库根，逐条核对判断。→ 退出码。"""
    cases = [
        # (说明, tag, 发布说明内容（None = 没有文件）, WhatsNew 内容（None = 没有文件）, 期望出问题的关键字（空 = 过）)
        ("正常的次版本", "v1.32.0", "x", 'Notes(version: "1.32.0", entries: [', []),
        ("补丁版留着次版本的表", "v1.31.2", "x", 'Notes(version: "1.31.0", entries: [', []),
        ("补丁版换了补丁号的表", "v1.31.2", "x", 'Notes(version: "1.31.2", entries: [', []),
        ("主版本", "v2.0.0", "x", 'static let notes = Notes(version: "2.0.0", entries: [', []),
        ("忘了换表", "v1.33.0", "x", 'Notes(version: "1.32.0", entries: [', ["还是 1.32.0"]),
        ("表比 tag 新", "v1.33.0", "x", 'Notes(version: "1.34.0", entries: [', ["比 v1.33.0 还新"]),
        ("表的补丁号比 tag 新", "v1.32.1", "x", 'Notes(version: "1.32.2", entries: [', ["比 v1.32.1 还新"]),
        ("没有发布说明", "v1.32.0", None, 'Notes(version: "1.32.0", entries: [', ["没有 release-notes/v1.32.0.md"]),
        ("发布说明是空的", "v1.32.0", " \n\n", 'Notes(version: "1.32.0", entries: [', ["是空的"]),
        ("两样都不对", "v1.33.0", None, 'Notes(version: "1.32.0", entries: [', ["没有 release-notes", "还是 1.32.0"]),
        ("没有 WhatsNew.swift", "v1.32.0", "x", None, ["没有 culling-poc"]),
        ("表的写法认不出", "v1.32.0", "x", 'let version = "1.32.0"', ["找到 0 处"]),
        ("表的版本号不是 X.Y.Z", "v1.32.0", "x", 'Notes(version: "1.32", entries: [', ["不是 X.Y.Z"]),
        ("tag 不是 vX.Y.Z", "v1.33", "x", 'Notes(version: "1.33.0", entries: [', ["不是 vX.Y.Z"]),
        ("tag 不是版本", "nightly", "x", 'Notes(version: "1.33.0", entries: [', ["不是 vX.Y.Z"]),
    ]
    bad = 0
    with tempfile.TemporaryDirectory(prefix="release-gate-") as tmp:
        for i, (label, tag, notes, whatsnew, expect) in enumerate(cases):
            root = os.path.join(tmp, str(i))
            os.makedirs(os.path.join(root, NOTES_DIR))
            if notes is not None:
                with open(os.path.join(root, NOTES_DIR, f"{tag}.md"), "w", encoding="utf-8") as fh:
                    fh.write(notes)
            if whatsnew is not None:
                os.makedirs(os.path.dirname(os.path.join(root, WHATSNEW)))
                with open(os.path.join(root, WHATSNEW), "w", encoding="utf-8") as fh:
                    fh.write(whatsnew)
            got = check(tag, root)
            ok = (not expect and not got) or (
                expect and len(got) == len(expect) and all(any(k in p for p in got) for k in expect))
            print(("PASS " if ok else "FAIL ") + f"{label}（{tag}）→ {got or '过'}")
            bad += 0 if ok else 1
    # 这份仓库里那张表本身认得出（表的写法改了、这个脚本的 TABLE 没跟上，这里先红，不等到打 tag）。
    path = os.path.join(repo_root(), WHATSNEW)
    with open(path, encoding="utf-8", errors="replace") as fh:
        found = TABLE.findall(fh.read())
    ok = len(found) == 1 and VERSION.match(found[0].strip()) is not None
    print(("PASS " if ok else "FAIL ") + f"仓库里的 WhatsNew.swift 认得出表的版本号：{found}")
    bad += 0 if ok else 1
    print(f"发版门禁自测：{'全过' if not bad else f'{bad} 条不对'}")
    return 1 if bad else 0


def repo_root():
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))


def main():
    args = sys.argv[1:]
    if args == ["--self-test"]:
        return self_test()
    if not args or args[0].startswith("-"):
        print(__doc__)
        return 2
    tag = args[0]
    root = repo_root()
    if len(args) == 3 and args[1] == "--root":
        root = args[2]
    elif len(args) != 1:
        print(__doc__)
        return 2
    problems = check(tag, root)
    report(tag, problems)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
