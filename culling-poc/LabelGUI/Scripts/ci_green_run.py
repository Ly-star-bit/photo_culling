#!/usr/bin/env python3
"""同一个提交只跑一遍（优化分析 NE3，用户 2026-11-08 定的）：release.yml 的 check job 用它决定这次 run 干什么。

用法: python3 -I Scripts/ci_green_run.py [--sha <提交>] [--fake <目录>]
  --sha   要查的提交（默认 GITHUB_SHA；CI 上传 git rev-parse HEAD，带注解的 tag 也是提交本身）
  --fake  不连 GitHub，读 <目录>/runs.json（List workflow runs 的响应）和 <目录>/artifacts-<run id>.json
          （List workflow run artifacts 的响应）；没有那个文件 = 那次请求失败。本机核对用。

决定（写进 $GITHUB_OUTPUT 的 mode / run_id / reason，摘要页上另有一条 ::notice）：
  feature/** 推送、手动跑（workflow_dispatch）  → full：照旧编译 + 全部测试 + 打包，DMG 传成 artifact（留 14 天）
  推 main   这个提交在这个 workflow 里有绿过的 push run（任何分支）→ skip：整个跳过；没绿过 → full
  推 v* tag 有绿过的 push run、而且它的 PhotoCulling-dmg 还没过期 → reuse（run_id = 那一次）：不重编、不重测，
            restamp job 下载那份 DMG、版本号换成 tag 的，release job 照旧发；没绿过 / 产物过期了 → full
「绿过」= 同一个 workflow、event == push、head_sha 是这个提交、conclusion == success、不是这一次。main 推送跳过的那种 run
也是 success（build 是 skipped）但没有产物，所以 tag 要的是「有没过期的 PhotoCulling-dmg」的那一次，从新到旧找。
查不了（网络、权限、限流）一律 full，打一条 ::warning —— 多跑一遍不要紧，不能因为查不了就不测。退出码总是 0。
"""
import json
import os
import sys
import urllib.error
import urllib.request

ARTIFACT = "PhotoCulling-dmg"


class QueryError(Exception):
    pass


def esc(s):
    return s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def fetch(path, fake):
    """GET {api}{path} → JSON。fake：按路径读本地文件。"""
    if fake:
        if "/artifacts" in path:
            run_id = path.split("/runs/")[1].split("/")[0]
            name = f"artifacts-{run_id}.json"
        else:
            name = "runs.json"
        file = os.path.join(fake, name)
        log = os.path.join(fake, "requests.log")
        with open(log, "a", encoding="utf-8") as fh:
            fh.write(path + "\n")
        if not os.path.isfile(file):
            raise QueryError(f"假的 API 没有 {name}")
        with open(file, encoding="utf-8") as fh:
            return json.load(fh)
    api = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    req = urllib.request.Request(api + path, headers={
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "photo-culling-ci",
        **({"Authorization": f"Bearer {token}"} if token else {}),
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)
    except (urllib.error.URLError, TimeoutError, ValueError) as e:
        raise QueryError(f"GET {path}：{e}") from e


def workflow_file():
    """GITHUB_WORKFLOW_REF = owner/repo/.github/workflows/release.yml@refs/... → release.yml。"""
    ref = os.environ.get("GITHUB_WORKFLOW_REF", "")
    path = ref.split("@", 1)[0]
    return path.rsplit("/", 1)[-1] if path.endswith((".yml", ".yaml")) else "release.yml"


def green_runs(repo, sha, fake):
    """这个提交绿过的 push run，从新到旧。API 参数只是缩小范围，条件在这里逐条再核一遍。"""
    me = os.environ.get("GITHUB_RUN_ID", "")
    data = fetch(f"/repos/{repo}/actions/workflows/{workflow_file()}/runs"
                 f"?head_sha={sha}&event=push&status=success&per_page=100", fake)
    runs = [r for r in data.get("workflow_runs", [])
            if r.get("head_sha") == sha and r.get("event") == "push"
            and r.get("conclusion") == "success" and str(r.get("id")) != me]
    runs.sort(key=lambda r: (r.get("run_started_at") or r.get("created_at") or "", r.get("id", 0)), reverse=True)
    return runs


def has_artifact(repo, run, fake):
    data = fetch(f"/repos/{repo}/actions/runs/{run['id']}/artifacts?name={ARTIFACT}&per_page=100", fake)
    return any(a.get("name") == ARTIFACT and not a.get("expired") for a in data.get("artifacts", []))


def describe(run):
    branch = run.get("head_branch") or "?"
    return f"run {run['id']}（{branch}，{run.get('html_url') or ''}）".replace("，）", "）")


def decide(env, sha, fake):
    """→ (mode, run_id, reason)。"""
    event = env.get("GITHUB_EVENT_NAME", "")
    ref = env.get("GITHUB_REF", "")
    ref_type = env.get("GITHUB_REF_TYPE", "")
    repo = env.get("GITHUB_REPOSITORY", "")
    short = sha[:7]
    if event != "push":
        return "full", "", f"{event or '不是 push'}：照旧完整跑"
    is_main = ref == "refs/heads/main"
    is_tag = ref_type == "tag" and ref.startswith("refs/tags/")
    if not (is_main or is_tag):
        return "full", "", f"{ref}：feature 推送照旧完整跑（DMG 传成 artifact，main / tag 用得上）"
    try:
        runs = green_runs(repo, sha, fake)
        if is_main:
            if runs:
                return "skip", str(runs[0]["id"]), f"{short} 在 {describe(runs[0])}绿过：推 main 不再跑"
            return "full", "", f"{short} 没有绿过的 push run：推 main 照旧完整跑"
        for run in runs:
            if has_artifact(repo, run, fake):
                return "reuse", str(run["id"]), (f"{short} 在 {describe(run)}绿过：不重编、不重测，"
                                                 f"用那次的 {ARTIFACT}（版本号换成 {env.get('GITHUB_REF_NAME', '?')}）发 Release")
        if runs:
            return "full", "", f"{short} 绿过（{len(runs)} 次），但 {ARTIFACT} 都过期了 / 没有：推 tag 照旧完整跑再发"
        return "full", "", f"{short} 没有绿过的 push run：推 tag 照旧完整跑再发"
    except QueryError as e:
        print(f"::warning title=查不了这个提交绿过没有::{esc(str(e))}（照旧完整跑）")
        return "full", "", f"查不了 {short} 绿过没有（{e}）：照旧完整跑"


def main():
    args = sys.argv[1:]
    fake = None
    sha = os.environ.get("GITHUB_SHA", "")
    i = 0
    while i < len(args):
        if args[i] == "--fake" and i + 1 < len(args):
            fake = args[i + 1]
            i += 2
        elif args[i] == "--sha" and i + 1 < len(args):
            sha = args[i + 1] or sha
            i += 2
        else:
            print(__doc__)
            return 0
    try:
        mode, run_id, reason = decide(os.environ, sha, fake)
    except Exception as e:  # noqa: BLE001 — 这一步红了后面全跳过：宁可完整跑
        print(f"::warning title=绿过没有：脚本出错::{esc(repr(e))}（照旧完整跑）")
        mode, run_id, reason = "full", "", f"脚本出错（{e!r}）：照旧完整跑"
    print(f"::notice title=这次 run 干什么（{mode}）::{esc(reason)}")
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a", encoding="utf-8") as fh:
            fh.write(f"mode={mode}\nrun_id={run_id}\n")
    print(f"mode={mode} run_id={run_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
