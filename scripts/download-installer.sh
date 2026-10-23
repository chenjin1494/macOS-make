#!/usr/bin/env bash
# =============================================================================
# 在 CI 中获取 macOS 安装器（Install macOS *.app）
#
# 为什么需要这个脚本：GitHub Actions 的 macOS 运行器无法登录 App Store，
# 只能用 Apple 官方的命令行渠道拿到完整安装器。按优先级依次尝试：
#
#   1) softwareupdate --fetch-full-installer --full-installer-version X
#      Apple 官方渠道，安装到 /Applications，Intel 运行器上还能取到 10.13–10.15。
#   2) 直接从 Apple 软件更新服务器（swcdn.apple.com）下载 10.13–10.15 的
#      BaseSystem.dmg / InstallESDDmg.pkg 等文件，拼装出安装器 .app。
#      （做法参考 LongQT-sea/mkmaciso，仅用 macOS 自带命令）
#   3) MIST（仅当主机 macOS < 15.6 时可用）
#
# 注意：macOS 15.6 起 Apple 修了 CVE-2025-43187，`installer -pkg` 安装旧
# 安装器会报 “Opened package is not the same at install time”，因此 MIST
# 在 15.6+ 上无法生成任何版本的安装器（见 Mist #189/#193/#198/#208/#215）。
# 这也是本脚本优先走 softwareupdate 的原因。
#
# 用法:
#   scripts/download-installer.sh <version> <work_dir>
# 成功时:
#   - 最后一行输出安装器 .app 的绝对路径
#   - 若存在 ${GITHUB_ENV}，则写入 INSTALLER_APP=<path>
# =============================================================================
set -euo pipefail

VERSION="${1:?用法: scripts/download-installer.sh <version> <work_dir>}"
WORK_DIR="${2:?用法: scripts/download-installer.sh <version> <work_dir>}"
APP_DIR="${APP_DIR:-$WORK_DIR/app}"

mkdir -p "$WORK_DIR" "$APP_DIR"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
APP_DIR="$(cd "$APP_DIR" && pwd)"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

app_version() {
    local app="$1" v=""
    v="$(defaults read "$app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true)"
    printf '%s' "$v"
}

# 版本号 -> 安装器的营销名称（"Install macOS Catalina.app" 里的 Catalina）
marketing_name() {
    case "$1" in
        10.13*) printf 'High Sierra' ;;
        10.14*) printf 'Mojave' ;;
        10.15*) printf 'Catalina' ;;
        11.*)   printf 'Big Sur' ;;
        12.*)   printf 'Monterey' ;;
        13.*)   printf 'Ventura' ;;
        14.*)   printf 'Sonoma' ;;
        15.*)   printf 'Sequoia' ;;
        26.*)   printf 'Tahoe' ;;
        *)      printf '' ;;
    esac
}

# 在给定目录里找 Install macOS *.app
#   $3 是营销名称提示：softwareupdate 下载的安装器 Info.plist 里的
#   CFBundleShortVersionString 可能被写成宿主系统版本（例如 Catalina 安装器
#   显示 15.7.03），所以名称匹配比版本号匹配更可靠。
find_app() {
    local dir="$1" want="$2" hint="${3:-}" app v base
    for app in "$dir"/Install\ macOS*.app; do
        [ -d "$app" ] || continue
        base="$(basename "$app")"
        if [ -n "$hint" ] && [[ "$base" == *"$hint"* ]]; then
            printf '%s\n' "$app"
            return 0
        fi
        v="$(app_version "$app")"
        if [ -n "$v" ]; then
            if [ "$v" = "$want" ] || [[ "$v" == "$want".* ]] \
                || [ "${v%.*}" = "${want%.*}" ] || [[ "$want" == "$v".* ]]; then
                printf '%s\n' "$app"
                return 0
            fi
        fi
    done
    return 1
}

finish() {
    local app="$1"
    [ -d "$app" ] || die "安装器目录不存在: $app"
    [ -x "$app/Contents/Resources/createinstallmedia" ] \
        || die "安装器缺少 createinstallmedia: $app"
    log "安装器就绪: ${app}（版本 $(app_version "$app")）"
    if [ -n "${GITHUB_ENV:-}" ]; then
        printf 'INSTALLER_APP=%s\n' "$app" >> "$GITHUB_ENV"
    fi
    printf '%s\n' "$app"
}

# -----------------------------------------------------------------------------
# 1) softwareupdate：Apple 官方下载渠道
# -----------------------------------------------------------------------------
try_softwareupdate() {
    log "尝试 softwareupdate 下载 macOS ${VERSION}（Apple 官方渠道）"
    local app attempt rc hint before
    hint="$(marketing_name "$VERSION")"
    before="$WORK_DIR/apps-before.txt"
    ls -1d /Applications/Install\ macOS*.app 2>/dev/null > "$before" || true

    for attempt in 1 2 3; do
        log "softwareupdate 第 $attempt/3 次尝试"
        if sudo softwareupdate --fetch-full-installer --full-installer-version "$VERSION"; then
            # softwareupdate 下载的安装器不一定带正确的版本号，先认「新出现」的 app
            for app in /Applications/Install\ macOS*.app; do
                [ -d "$app" ] || continue
                if ! grep -qxF "$app" "$before"; then
                    finish "$app"
                    return 0
                fi
            done
            # 再按营销名称 / 版本号匹配
            if app="$(find_app /Applications "$VERSION" "$hint")"; then
                finish "$app"
                return 0
            fi
            warn "softwareupdate 返回成功，但 /Applications 下没找到 $VERSION 安装器"
        else
            rc=$?
            warn "softwareupdate 失败（退出码 ${rc}）"
        fi
        sleep 10
    done
    return 1
}

# -----------------------------------------------------------------------------
# 2) 直接从 Apple swcdn 下载并拼装 10.13–10.15 安装器
#    （BaseSystem.dmg 里是安装器主体，InstallESDDmg.pkg 改名为 InstallESD.dmg）
# -----------------------------------------------------------------------------
legacy_base_url() {
    case "$1" in
        10.13*)
            printf '%s' "${MACOS_HIGH_SIERRA_BASE_URL:-https://swcdn.apple.com/content/downloads/06/50/041-91758-A_M8T44LH2AW/b5r4og05fhbgatve4agwy4kgkzv07mdid9/}"
            ;;
        10.14*)
            printf '%s' "${MACOS_MOJAVE_BASE_URL:-https://swcdn.apple.com/content/downloads/17/32/061-26589-A_8GJTCGY9PC/25fhcu905eta7wau7aoafu8rvdm7k1j4el/}"
            ;;
        10.15*)
            printf '%s' "${MACOS_CATALINA_BASE_URL:-https://swcdn.apple.com/content/downloads/26/37/001-68446/r1dbqtmf3mtpikjnd04cq31p4jk91dceh8/}"
            ;;
        *)
            return 1
            ;;
    esac
}

try_legacy_assembly() {
    local base_url
    base_url="$(legacy_base_url "$VERSION")" || return 1

    log "尝试从 Apple swcdn 直接下载 macOS $VERSION 组件"
    log "组件地址: $base_url"

    local dl="$WORK_DIR/downloads"
    local mnt="$WORK_DIR/basesystem-mnt"
    rm -rf "$dl" "$mnt"
    mkdir -p "$dl" "$mnt"

    local f
    for f in BaseSystem.dmg BaseSystem.chunklist InstallInfo.plist \
             InstallESDDmg.pkg AppleDiagnostics.dmg AppleDiagnostics.chunklist; do
        log "下载 $f"
        curl -fL --retry 5 --retry-delay 10 --connect-timeout 20 -C - \
            -o "$dl/$f" "$base_url$f" \
            || { warn "下载 $f 失败"; return 1; }
    done

    log "挂载 BaseSystem.dmg 取出安装器主体"
    hdiutil attach -noverify -nobrowse -mountpoint "$mnt" "$dl/BaseSystem.dmg" >/dev/null \
        || { warn "挂载 BaseSystem.dmg 失败"; return 1; }

    local src app
    src="$(find "$mnt" -maxdepth 1 -name 'Install macOS*.app' -print -quit)"
    if [ -z "$src" ]; then
        hdiutil detach "$mnt" -force >/dev/null 2>&1 || true
        warn "BaseSystem.dmg 里没有 Install macOS*.app"
        return 1
    fi
    app="$APP_DIR/$(basename "$src")"
    rm -rf "$app"
    log "复制安装器到 $app"
    ditto "$src" "$app" || { warn "复制安装器失败"; hdiutil detach "$mnt" -force >/dev/null 2>&1 || true; return 1; }
    hdiutil detach "$mnt" -force >/dev/null 2>&1 || true

    log "拼装 SharedSupport（InstallESDDmg.pkg -> InstallESD.dmg）"
    local ss="$app/Contents/SharedSupport"
    rm -rf "$ss"
    mkdir -p "$ss"

    mv "$dl/InstallESDDmg.pkg" "$dl/InstallESD.dmg"
    # Apple 的 InstallInfo.plist 指向 InstallESDDmg.pkg，改回 InstallESD.dmg
    sed -e 's/InstallESDDmg\.pkg/InstallESD.dmg/' \
        -e 's/pkg\.InstallESDDmg/dmg.InstallESD/' \
        -e '/InstallESD\.dmg/{n;N;N;N;d;}' \
        "$dl/InstallInfo.plist" > "$dl/InstallInfo_fixed.plist"

    ditto "$dl/BaseSystem.dmg" "$ss/BaseSystem.dmg"
    ditto "$dl/BaseSystem.chunklist" "$ss/BaseSystem.chunklist"
    ditto "$dl/InstallInfo_fixed.plist" "$ss/InstallInfo.plist"
    ditto "$dl/InstallESD.dmg" "$ss/InstallESD.dmg"
    ditto "$dl/AppleDiagnostics.dmg" "$ss/AppleDiagnostics.dmg"
    ditto "$dl/AppleDiagnostics.chunklist" "$ss/AppleDiagnostics.chunklist"
    chmod -R u+w "$app"

    rm -rf "$dl"
    finish "$app"
}

# -----------------------------------------------------------------------------
# 3) MIST（仅 Host < 15.6，作为最后的兜底）
# -----------------------------------------------------------------------------
try_mist() {
    if ! command -v mist >/dev/null 2>&1; then
        command -v brew >/dev/null 2>&1 || return 1
        log "通过 Homebrew 安装 mist-cli"
        HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 brew install mist-cli || return 1
    fi
    command -v mist >/dev/null 2>&1 || return 1

    local out="$WORK_DIR/mist-out"
    rm -rf "$out"
    mkdir -p "$out"
    log "尝试 MIST 下载 macOS $VERSION"
    sudo "$(command -v mist)" download installer "$VERSION" application \
        --output-directory "$out" \
        --temporary-directory "$WORK_DIR/mist-tmp" \
        --no-ansi --force || return 1

    local app
    app="$(find "$out" -maxdepth 2 -name 'Install macOS*.app' -print -quit)"
    [ -n "$app" ] || return 1
    finish "$app"
}

# -----------------------------------------------------------------------------
main() {
    log "目标版本: $VERSION"
    log "主机: $(sw_vers -productName) $(sw_vers -productVersion) $(uname -m)"

    if [[ "$VERSION" == 10.* ]] && [ "$(uname -m)" = "arm64" ] && [ "${FORCE_LEGACY_ON_ARM:-0}" != "1" ]; then
        die "10.13–10.15 请使用 Intel 运行器（macos-15-intel / macos-26-intel）：
Apple Silicon 上这些旧版本自带的 createinstallmedia 无法运行。
如确需在 arm64 上尝试，请设置 FORCE_LEGACY_ON_ARM=1。"
    fi

    try_softwareupdate && exit 0

    log "softwareupdate 未能提供该安装器，清理残留后尝试其他渠道"
    sudo rm -rf /Applications/Install\ macOS*.app 2>/dev/null || true

    if try_legacy_assembly; then
        exit 0
    fi

    local host_version host_major host_minor
    host_version="$(sw_vers -productVersion)"
    host_major="$(printf '%s' "$host_version" | cut -d. -f1)"
    host_minor="$(printf '%s' "$host_version" | cut -d. -f2)"
    [ -n "$host_minor" ] || host_minor=0
    if [ "${host_major:-0}" -gt 15 ] \
        || { [ "${host_major:-0}" -eq 15 ] && [ "$host_minor" -ge 6 ]; }; then
        warn "主机 macOS $host_version >= 15.6，MIST/installer 在此版本上已损坏，跳过 MIST"
    elif try_mist; then
        exit 0
    fi

    die "无法获取 macOS $VERSION 安装器。可用渠道:
  1. softwareupdate --list-full-installers 查看当前运行器能下载的版本
  2. 10.13–10.15 可通过 swcdn 直链拼装（请检查直链是否仍有效，
     可用环境变量 MACOS_CATALINA_BASE_URL 等覆盖）"
}

main "$@"
