#!/usr/bin/env bash
# 打包 WorkBuddy Remote 的 macOS 安装包（.dmg）
#
# 产物：dist/WorkBuddy-Remote-<版本>.dmg
# 用法：macos/build-dmg.sh [版本号]
#
# 为什么要做成 DMG：
#   逐个机器跑 curl | bash 装客户端太别扭。DMG 双击挂载、拖进「应用程序」
#   就完事，之后点 Dock 图标单实例运行 —— 和普通 Mac 应用没区别。

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
VERSION="${1:-1.2}"
APP_NAME="WorkBuddy Remote"
BUNDLE_ID="com.workbuddy.remote.client"

DIST="$ROOT/dist"
STAGE="$DIST/stage"
APP="$STAGE/$APP_NAME.app"

info() { printf '  %s\n' "$*"; }
die()  { printf '错误：%s\n' "$*" >&2; exit 1; }

# ── 前置检查 ────────────────────────────────────────────────────────
command -v swiftc >/dev/null 2>&1 || die "需要 Swift 编译器（xcode-select --install）"
command -v iconutil >/dev/null 2>&1 || die "需要 iconutil（macOS 自带）"

# 只出当前架构。做通用二进制要有 Intel 机器或交叉编译环境，
# 而且壳只是十几万字节，没必要为此把流程复杂化。
ARCH="$(uname -m)"
info "目标架构：$ARCH"

# ── 编译壳 ──────────────────────────────────────────────────────────
# 尽量做通用二进制（arm64 + x86_64）。Intel Mac 上跑到一半才报
# 「无法打开」是很糟的体验，而双架构总共也就 300KB。
info "编译原生壳…"
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BIN="$APP/Contents/MacOS/WorkBuddyRemote"
TMPD="$(mktemp -d)"
built=""

for tgt in arm64 x86_64; do
  if swiftc -O -target "${tgt}-apple-macos12.0" \
       -Xlinker -U -Xlinker '__swift_FORCE_LOAD_$_swiftCompatibility56' \
       -o "$TMPD/shell-$tgt" "$DIR/shell.swift" 2>"$TMPD/err-$tgt"; then
    built="$built $TMPD/shell-$tgt"
    info "  ${tgt} OK"
  else
    info "  ${tgt} 失败（跳过）：$(tail -1 "$TMPD/err-$tgt")"
  fi
done

if [ -z "$built" ]; then
  die "两个架构都编译失败"
fi

if [ "$(echo $built | wc -w | tr -d ' ')" = "2" ]; then
  lipo -create $built -output "$BIN"
  info "通用二进制：$(lipo -info "$BIN" | sed 's/.*are: //')"
else
  cp $built "$BIN"
  info "单架构（$ARCH）"
fi
rm -rf "$TMPD"

strip -x "$BIN" 2>/dev/null || true

# ── 图标 ────────────────────────────────────────────────────────────
ICON_SRC="$ROOT/assets/icon-512.png"
[ -f "$ICON_SRC" ] || ICON_SRC="$(ls "$ROOT"/assets/icon*.png 2>/dev/null | head -1 || true)"
if [ -n "${ICON_SRC:-}" ] && [ -f "$ICON_SRC" ]; then
  info "生成图标…"
  ICONSET="$(mktemp -d)/icon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1
    d=$((s * 2))
    sips -z $d $d "$ICON_SRC" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
  done
  if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/app.icns" 2>/dev/null; then
    info "图标 OK"
  else
    info "iconutil 失败，跳过图标"
  fi
  rm -rf "$(dirname "$ICONSET")"
else
  info "没找到 assets/icon*.png，用系统默认图标"
fi

# ── 本地化 ──────────────────────────────────────────────────────────
# 不加这个，WKWebView 的右键菜单是英文的（Copy / Look Up / Translate…）。
#
# 原因：WebKit 的菜单文案取自 WebCore.framework 里的 zh_CN.lproj，
# 但选哪个语言取决于**宿主 app** 声明了什么。壳没有 lproj 目录时
# Bundle.main.localizations 是空数组，preferredLocalizations 回退成
# ["en"]，WebKit 就只拿英文——系统里明明有完整中文资源。
info "本地化…"
for lang in zh-Hans en; do
  mkdir -p "$APP/Contents/Resources/$lang.lproj"
  cat >"$APP/Contents/Resources/$lang.lproj/InfoPlist.strings" <<'STRINGS'
CFBundleName = "WorkBuddy Remote";
CFBundleDisplayName = "WorkBuddy Remote";
STRINGS
done

# ── Info.plist ──────────────────────────────────────────────────────
cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>WorkBuddyRemote</string>
    <key>CFBundleIconFile</key><string>app</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>zh-Hans</string>
        <string>zh-Hant</string>
        <string>en</string>
    </array>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null || die "Info.plist 有问题"

# ── 签名 ────────────────────────────────────────────────────────────
# 本地自签即可。没有签名的话首次打开会被 Gatekeeper 拦，
# 用户得右键「打开」绕过，体验很差。
if command -v codesign >/dev/null 2>&1; then
  info "临时签名…"
  codesign --force --deep --sign - "$APP" 2>/dev/null \
    && info "签名 OK（ad-hoc）" \
    || info "签名失败，跳过"
fi

xattr -cr "$APP" 2>/dev/null || true

# ── 组装 DMG 内容 ───────────────────────────────────────────────────
info "准备 DMG 内容…"
ln -sfn /Applications "$STAGE/Applications"

# 放一个说明文件：DMG 里的东西用户第一眼就能看懂
cat >"$STAGE/使用说明.txt" <<'TXT'
WorkBuddy Remote
===============

安装
  把左边的 WorkBuddy Remote 拖到右边的「应用程序」文件夹。

第一次打开
  双击图标，填入被控端地址和访问密码：
      http://192.168.1.10:8797
  被控端的终端会打印这个地址（装了 workbuddy-remote 的那台机器）。

  之后从 Dock 点击图标即可，不会重复开窗口。

注意
  - 首次打开若提示「无法验证开发者」，右键点图标选「打开」，
    在弹窗里再点一次「打开」即可。只需一次。
  - 换服务器：菜单栏 WorkBuddy Remote → 更改服务器…
TXT

# ── 生成 DMG ────────────────────────────────────────────────────────
DMG="$DIST/WorkBuddy-Remote-${VERSION}.dmg"
rm -f "$DMG"

info "生成 DMG…"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  -fs HFS+ \
  "$DMG" >/dev/null

# 顺手做一个 zip，方便走 GitHub Release 附件
(
  cd "$STAGE"
  zip -qry "$DIST/WorkBuddy-Remote-${VERSION}.zip" "$APP_NAME.app"
) 2>/dev/null || true

# 再复制一份不带版本号的。
# 用途：README 里写 releases/latest/download/WorkBuddy-Remote.dmg 就能永久有效，
# 不用每次发版都改文档 —— 带版本号的名字下次发版就 404 了。
#
# 每次 Release 都要把这两个固定名当附件上传，覆盖上一版的同名文件。
cp -f "$DMG" "$DIST/WorkBuddy-Remote.dmg"
[ -f "$DIST/WorkBuddy-Remote-${VERSION}.zip" ] && \
  cp -f "$DIST/WorkBuddy-Remote-${VERSION}.zip" "$DIST/WorkBuddy-Remote.zip"

rm -rf "$STAGE"

# ── 汇报 ────────────────────────────────────────────────────────────
printf '\n完成\n'
ls -lh "$DMG" | awk '{printf "  DMG  %s  %s\n", $5, $9}'
[ -f "$DIST/WorkBuddy-Remote-${VERSION}.zip" ] && \
  ls -lh "$DIST/WorkBuddy-Remote-${VERSION}.zip" | awk '{printf "  ZIP  %s  %s\n", $5, $9}'
printf '\n  固定名（README 用）：WorkBuddy-Remote.dmg / .zip\n'
printf '  架构：%s\n' "$ARCH"
printf '  安装：双击 DMG，把应用拖进「应用程序」\n'