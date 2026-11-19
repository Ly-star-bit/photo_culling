#!/bin/bash
# 一条命令安装 / 升级 选片工具（优化分析 2026-11-18，ops 复核「漏 2」）：
#
#   curl -fsSL https://raw.githubusercontent.com/Ly-star-bit/photo_culling/main/install.sh | bash
#
# 做的事：问 GitHub 最新版是哪个 tag（github.com/<仓库>/releases/latest 回的 302）→ curl 下那一版的 DMG → hdiutil 挂到临时目录
# （-nobrowse -noautoopen：不进访达、不弹窗口）→ 核对里面的 app 和签名 → 换掉 /Applications/选片工具.app → 卸下、删临时文件。
# 不打开 app，不用 sudo，设置（偏好）和数据目录（~/Library/Application Support/选片工具）一概不碰。
#
# 为什么用它装就不用每版去系统设置放行：app 是临时签名（没有付费的开发者账号、没公证，每次构建的签名身份都不一样），浏览器下载的
# DMG 带隔离属性（com.apple.quarantine），Gatekeeper 在每个新版本第一次打开时都要你去「隐私与安全性 → 仍要打开」放行一次。
# curl 下的文件不带这个属性，装出来的 app 不经过这一道。等于你信任这个仓库发的包 —— 和在系统设置里点「仍要打开」是同一个决定，
# 只是不用每版点一次。（--dmg 装本地文件时，浏览器下的 DMG 带着隔离属性，拷进去以后一样删掉。）
#
# 参数（经 curl 管道传参数：curl -fsSL …/install.sh | bash -s -- <参数>）：
#   --version vX.Y.Z   装指定的一版（默认最新；退回旧版也用它）
#   --dest <目录>      装到别处（默认 /Applications）
#   --dmg <文件>       不下载，装本地的 DMG（离线、自己打的包）
#   --force            已经是同一版也重装；目标正在运行也照换（运行着的那个退出重开以后才是新版）
#   --help             打印用法
# 退出码：0 装好了 / 已经是这一版；1 出错（原来的 app 原样留着）。
#
# 整个脚本包在 main 里、最后一行才调：curl 管道半路断了，bash 拿到的是半截文件，也不会执行半截命令。
# 本机核对（不碰 /Applications）：bash install.sh --dest <临时目录>。
set -euo pipefail

REPO="Ly-star-bit/photo_culling"
APP_NAME="选片工具.app"
# 退出时 cleanup 要用：写成全局的（main 正常返回以后 EXIT trap 才跑，那时 main 的 local 已经没了）。
WORK=""
MNT=""
STAGED=""

say() { printf '%s\n' "$*"; }
die() { printf '安装没做完：%s\n' "$*" >&2; exit 1; }

usage() {
    # 经管道跑时没有 $0 可读，用法直接写在这里。
    cat <<'EOF'
一条命令安装 / 升级 选片工具：
  curl -fsSL https://raw.githubusercontent.com/Ly-star-bit/photo_culling/main/install.sh | bash
参数（curl … | bash -s -- <参数>）：
  --version vX.Y.Z   装指定的一版（默认最新；退回旧版也用它）
  --dest <目录>      装到别处（默认 /Applications）
  --dmg <文件>       不下载，装本地的 DMG
  --force            同一版也重装；目标正在运行也照换（退出重开以后才是新版）
用它装的不用去「系统设置 › 隐私与安全性」放行：命令行下的文件不带浏览器加的隔离属性。
EOF
}

# 不管在哪一步退出：卸下 DMG（先礼貌、再强制）、删临时目录和没换进去的半成品。卸不下来就不删临时目录（里面挂着只读的卷）。
cleanup() {
    if [ -n "$MNT" ]; then
        /usr/bin/hdiutil detach "$MNT" -quiet 2>/dev/null || /usr/bin/hdiutil detach "$MNT" -force -quiet 2>/dev/null || true
    fi
    if [ -n "$STAGED" ]; then
        /bin/rm -rf "$STAGED"
    fi
    if [ -n "$WORK" ]; then
        if [ -n "$MNT" ] && [ -e "$MNT/$APP_NAME" ]; then
            printf 'DMG 没卸下来，还挂在 %s（hdiutil detach 它就行）\n' "$MNT" >&2
        else
            /bin/rm -rf "$WORK"
        fi
    fi
}

# 「1.32.0」这种（本机自己打的包是 0.1）；读不到给空。
plist_version() {
    /usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$1/Contents/Info.plist" 2>/dev/null || true
}

# 目标 app 里的程序正在跑的进程（app 本身、AI 客户端起的 --mcp 都算）：一行一个「pid 命令行」。
# 路径经环境变量给 awk（写在参数里的话 awk 自己那一行也会匹配上），按字面比，不当正则。
running_from() {
    /bin/ps -A -ww -o pid=,args= | TARGET_EXE_DIR="$1/Contents/MacOS/" /usr/bin/awk 'index($0, ENVIRON["TARGET_EXE_DIR"]) > 0'
}

main() {
    local want="" dest="/Applications" dmg_file="" force=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --version) [ $# -ge 2 ] || die "--version 后面要跟版本号，比如 v1.32.0"; want="$2"; shift 2 ;;
            --dest) [ $# -ge 2 ] || die "--dest 后面要跟目录"; dest="$2"; shift 2 ;;
            --dmg) [ $# -ge 2 ] || die "--dmg 后面要跟 DMG 文件"; dmg_file="$2"; shift 2 ;;
            --force) force=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; die "不认识的参数：$1" ;;
        esac
    done

    [ "$(/usr/bin/uname -s)" = Darwin ] || die "只能装在 Mac 上"
    [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ] \
        || die "选片工具只有 Apple Silicon（M1 及以上）版，这台 Mac 是 Intel 的"
    local os_major
    os_major="$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)"
    [ "${os_major:-0}" -ge 14 ] || die "要 macOS 14 或更新，这台是 $(/usr/bin/sw_vers -productVersion)"
    [ -d "$dest" ] || die "没有 ${dest} 这个目录"
    [ -w "$dest" ] || die "${dest} 写不进去：用管理员账户登录后再跑，或者装到自己的应用程序目录（--dest ~/Applications）"
    dest="$(cd "$dest" && pwd -P)"
    local target="$dest/$APP_NAME"

    # 正在跑就先停下（下载之前查，省得白下）：运行中的 app 被换掉，它后面读到的是新版的资源。
    local running
    running="$(running_from "$target")"
    if [ -n "$running" ]; then
        if [ "$force" = 0 ]; then
            say "选片工具正在运行（AI 客户端起的 --mcp 也算）："
            printf '%s\n' "$running" | /usr/bin/cut -c1-160 | /usr/bin/sed 's/^ */  /'
            die "先退出选片工具、关掉起了它的 AI 客户端，再跑一次（或者加 --force 照换：运行着的那个退出重开以后才是新版）"
        fi
        say "选片工具正在运行：照换（--force），退出重开以后才是新版。"
    fi

    trap cleanup EXIT
    WORK="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/photoculling-install.XXXXXX")"

    local tag="" loc="" dmg="$WORK/PhotoCulling.dmg"
    if [ -n "$dmg_file" ]; then
        [ -f "$dmg_file" ] || die "没有 ${dmg_file} 这个文件"
        dmg="$dmg_file"
    else
        if [ -n "$want" ]; then
            tag="v${want#v}"
        else
            # releases/latest 回 302，location 指到 releases/tag/<最新的 tag>。不走 API：不怕匿名限流。
            loc="$(/usr/bin/curl -fsSI --max-time 30 -o /dev/null -w '%{redirect_url}' "https://github.com/$REPO/releases/latest")" \
                || die "连不上 GitHub（github.com/$REPO/releases/latest）"
            tag="${loc##*/tag/}"
        fi
        case "$tag" in
            v[0-9]*.[0-9]*.[0-9]*) ;;
            *) die "没问到要装哪一版（GitHub 回的是：${loc:-$tag}）" ;;
        esac
        if [ "$(plist_version "$target")" = "${tag#v}" ] && [ "$force" = 0 ]; then
            say "${target} 已经是 ${tag}，不用升级（要重装加 --force）。"
            exit 0
        fi
        # 每一版都有 PhotoCulling-<tag>.dmg；固定名字的 PhotoCulling.dmg 是 v1.32.0 以后才加的（给 releases/latest/download
        # 一个固定地址），这里只当后备。
        say "==> 下载 选片工具 ${tag}"
        local base="https://github.com/$REPO/releases/download/$tag"
        /usr/bin/curl -fL --retry 3 --connect-timeout 30 --progress-bar -o "$dmg" "$base/PhotoCulling-$tag.dmg" \
            || /usr/bin/curl -fL --retry 3 --connect-timeout 30 --progress-bar -o "$dmg" "$base/PhotoCulling.dmg" \
            || die "下载不了 ${tag} 的安装包（有这一版吗？看 https://github.com/$REPO/releases）"
    fi

    say "==> 挂上 DMG（不进访达、不开窗口）"
    MNT="$WORK/mnt"
    /bin/mkdir -p "$MNT"
    if ! /usr/bin/hdiutil attach "$dmg" -nobrowse -noautoopen -readonly -mountpoint "$MNT" -quiet; then
        MNT=""
        die "挂不上这个 DMG（下载坏了？再跑一次）"
    fi
    local src="$MNT/$APP_NAME"
    [ -x "$src/Contents/MacOS/LabelGUI" ] || die "DMG 里没有 $APP_NAME"
    /usr/bin/codesign --verify --deep --strict "$src" 2>/dev/null || die "DMG 里那份 app 的签名对不上（下载坏了？再跑一次）"
    local new_version
    new_version="$(plist_version "$src")"
    if [ -n "$tag" ] && [ "$new_version" != "${tag#v}" ]; then
        say "注意：${tag} 的安装包里写的版本号是 ${new_version:-?}"
    fi

    # 先完整拷到同一个目录下的临时名字，拷成了才换：半路失败时原来那个原样留着。不叠在旧包上拷（叠上去会带着旧版删掉的文件，
    # 和 build_app.sh 从零装配是一个道理）。
    STAGED="$dest/.$APP_NAME.installing.$$"
    local old="$dest/.$APP_NAME.old.$$"
    say "==> 装进 ${dest}"
    /usr/bin/ditto "$src" "$STAGED" || die "拷不进 ${dest}"
    # 下载来的没有隔离属性；--dmg 给的若是浏览器下的，挂上以后里面的文件带着它，ditto 会原样拷过来（--noqtn 也照拷，实测），
    # 所以拷完明着删掉。
    /usr/bin/xattr -dr com.apple.quarantine "$STAGED" 2>/dev/null || true
    local previous=""
    if [ -e "$target" ]; then
        previous="$(plist_version "$target")"
        /bin/mv "$target" "$old" || die "挪不开原来的 ${target}"
    fi
    if ! /bin/mv "$STAGED" "$target"; then
        if [ -e "$old" ]; then /bin/mv "$old" "$target"; fi
        die "换不进 ${target}（原来那个放回去了）"
    fi
    STAGED=""
    /bin/rm -rf "$old"

    if [ -n "$previous" ]; then
        say "装好了：选片工具 ${new_version:-?}（原来是 ${previous}）→ ${target}"
    else
        say "装好了：选片工具 ${new_version:-?} → ${target}"
    fi
    say "从启动台或「应用程序」打开就行，不用去系统设置放行。"
}

main "$@"
