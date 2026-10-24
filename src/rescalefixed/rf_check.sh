#!/usr/bin/sh
# rf_check.sh — Re:Scale 440（com.xu.rescalefixed）自检 / 自愈
#
# 用法：
#   sudo rf_check               # 完整体检（14 项，只读）
#   sudo rf_check --fix         # 体检 + 修复丢失的文件（不重启任何进程）
#   rf_check --heal             # 自愈模式：静默，供 LaunchDaemon 调用
#                               #   只做必要项；修复后按需重启一次 backboardd（有防抖）
#   rf_check --quiet            # 静默输出（与上面任意组合）
#
# 设计原则：
#   · 修复只重写文件（偏好/guard 标记/注入软链），绝不 kill -9 任何进程
#   · 画布尺寸由 backboardd 启动时读取 → 只有"偏好或标记"被修复时才需要它重读，
#     用 launchctl kickstart（launchd 正规方式），并做 10 分钟防抖，避免频繁重启
#   · 设备上 /bin/sh 是悬空软链，shebang 必须用 /usr/bin/sh

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

PKG=com.xu.rescalefixed
D=/usr/lib/TweakInject
M=/Library/dpkg/info/tf.festival.rescale2.list
P=/var/mobile/Library/Preferences/tf.festival.rescale.plist
PATCH=/usr/lib/DynamicPatches/AutoPatches.dylib
PREF_B64='YnBsaXN0MDDTAQIDBAUGXWNhbnZhc19oZWlnaHRcY2FudmFzX3dpZHRoXxATY29uZmlybWVkUmVzb2x1dGlvbhELNBEFKAkIDx0qQENGAAAAAAAAAQEAAAAAAAAABwAAAAAAAAAAAAAAAAAAAEc='
LOCK=/var/run/rf_heal.last
LOG=/var/log/rfheal.log

MODE=check; QUIET=0
for a in "$@"; do
    case "$a" in
        --fix)   MODE=fix ;;
        --heal)  MODE=heal ;;
        --quiet) QUIET=1 ;;
    esac
done

say() { [ "$QUIET" = "1" ] || printf '%s\n' "$*"; }
log() {
    # 自愈模式写日志文件；手动模式直接打印
    if [ "$MODE" = "heal" ]; then
        printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
    elif [ "$QUIET" = "0" ]; then
        printf '%s\n' "$*"
    fi
}

# ---------- 单项检查/修复（返回 0 正常，1 曾缺失/异常） ----------
need_canvas_restart=0
repaired=0

ensure_symlinks() {
    rc=0
    for f in ReScale.dylib ReScaleKB.dylib; do
        if [ ! -L "$D/$f.roothidepatch" ]; then
            rc=1
            if [ "$MODE" != "check" ]; then
                ln -sf "$PATCH" "$D/$f.roothidepatch" && { repaired=$((repaired+1)); log "修复注入软链：$f.roothidepatch"; }
            fi
        fi
    done
    return $rc
}

ensure_marker() {
    [ -f "$M" ] && return 0
    if [ "$MODE" != "check" ]; then
        mkdir -p /Library/dpkg/info
        : > "$M" && chmod 644 "$M" && chflags uchg "$M" 2>/dev/null
        repaired=$((repaired+1)); need_canvas_restart=1
        log "修复 guard 标记（已加 uchg 锁）"
    fi
    return 1
}

prefs_ok() {
    [ -f "$P" ] || return 1
    [ "$(wc -c < "$P" | tr -d ' ')" = "110" ] || return 1
    HEX=$(od -A n -t x1 "$P" 2>/dev/null | tr -d ' \n')
    case "$HEX" in *0528*) ;; *) return 1 ;; esac
    case "$HEX" in *0b34*) ;; *) return 1 ;; esac
    return 0
}

ensure_prefs() {
    prefs_ok && return 0
    if [ "$MODE" != "check" ]; then
        mkdir -p /var/mobile/Library/Preferences
        echo "$PREF_B64" | base64 -d > "$P" && chmod 600 "$P" && chown mobile:mobile "$P" 2>/dev/null
        repaired=$((repaired+1)); need_canvas_restart=1
        log "修复偏好文件（1320×2868 / confirmed=true）"
    fi
    return 1
}

backboardd_running() {
    launchctl print system/com.apple.backboardd 2>/dev/null | grep -q "state = running"
}

# 画布重读：仅当"标记/偏好"被修复且 backboardd 已在跑时才做；10 分钟防抖
heal_restart_canvas() {
    [ "$need_canvas_restart" = "1" ] || return 0
    backboardd_running || { log "backboardd 尚未运行，无需重启（它启动时会读新值）"; return 0; }
    NOW=$(date +%s)
    LAST=0
    [ -f "$LOCK" ] && LAST=$(cat "$LOCK" 2>/dev/null)
    if [ -n "$LAST" ] && [ $((NOW - LAST)) -lt 600 ]; then
        log "10 分钟内已重启过 backboardd，跳过（等下次触发）"
        return 0
    fi
    log "重启 backboardd 使画布重读（launchctl kickstart）"
    launchctl kickstart -k user/501/com.apple.backboardd >/dev/null 2>&1
    echo "$NOW" > "$LOCK"
    sleep 3
    backboardd_running && log "backboardd 已恢复运行" || log "警告：backboardd 未在运行，需人工检查"
}

# ===================== 自愈模式（LaunchDaemon 用） =====================
if [ "$MODE" = "heal" ]; then
    dirty=0
    ensure_marker         || dirty=1
    ensure_prefs          || dirty=1
    ensure_symlinks       || dirty=1
    if [ "$dirty" = "0" ]; then
        exit 0            # 一切正常：静默退出，零开销
    fi
    log "自愈：修复了 $repaired 项（canvas_restart=$need_canvas_restart）"
    heal_restart_canvas
    exit 0
fi

# ===================== 完整体检 / 手动修复 =====================
ok=0; bad=0
pass() { [ "$QUIET" = "1" ] || printf '  \033[32m✅\033[0m %s\n' "$1"; ok=$((ok+1)); }
fail() { [ "$QUIET" = "1" ] || printf '  \033[31m❌\033[0m %s\n' "$1"; bad=$((bad+1)); }
warn() { [ "$QUIET" = "1" ] || printf '  \033[33m⚠️\033[0m %s\n' "$1"; }

[ "$QUIET" = "1" ] || echo "==== Re:Scale 440 自检 $(date '+%Y-%m-%d %H:%M:%S') ===="

# 1) 包
V=$(dpkg-query -W -f='${Version}' "$PKG" 2>/dev/null)
[ -n "$V" ] && pass "包已安装：$PKG $V" || fail "包未安装（$PKG）"

# 2) 载荷
for f in ReScale.dylib ReScale.plist ReScaleKB.dylib ReScaleKB.plist; do
    [ -f "$D/$f" ] && pass "载荷在位：$f" || fail "载荷缺失：$f"
done

# 3) 注入软链
for f in ReScale.dylib ReScaleKB.dylib; do
    if [ -L "$D/$f.roothidepatch" ]; then
        pass "注入软链在位：$f.roothidepatch"
    elif ensure_symlinks; then
        pass "注入软链已重建：$f.roothidepatch"
    else
        fail "注入软链缺失：$f.roothidepatch（RootHide 不会注入）"
    fi
done

# 4) guard 标记
if [ -f "$M" ]; then
    pass "guard 标记存在"
elif ensure_marker; then
    pass "guard 标记已重建（已加 uchg 锁）"
else
    fail "guard 标记缺失 → 插件会静默失效（分辨率回落）"
fi

# 5) 标记是否加锁
if [ -f "$M" ]; then
    if touch "$M" 2>/dev/null; then
        warn "guard 标记未加 uchg 锁（可能被其它包的 postrm 删掉）"
        [ "$MODE" = "fix" ] && chflags uchg "$M" 2>/dev/null && pass "已给 guard 标记加锁"
    else
        pass "guard 标记已 uchg 锁定（删不掉）"
    fi
fi

# 6) 偏好文件
if prefs_ok; then
    pass "偏好文件正确（110B，1320×2868，confirmed=true）"
    OWN=$(ls -l "$P" | awk '{print $3":"$4}')
    [ "$OWN" = "mobile:mobile" ] || warn "偏好属主是 $OWN（期望 mobile:mobile）"
elif ensure_prefs; then
    pass "偏好文件已重建（110B，1320×2868）"
else
    fail "偏好文件缺失/内容异常 → 分辨率会回落原生"
fi

# 7) 信任缓存（缺失会导致 backboardd 崩溃循环，不是"不生效"）
TC=$(jbctl trustcache info 2>/dev/null)
echo "$TC" | grep -qi d29ee23402f0a4de3400a7580fb90ea33824bb42 \
    && pass "ReScale.dylib 在信任缓存" \
    || fail "ReScale.dylib 不在信任缓存（危险：backboardd 可能崩溃循环）"
echo "$TC" | grep -qi 72002a5d60b89497b86f5f71215f0bce2df43264 \
    && pass "ReScaleKB.dylib 在信任缓存" \
    || fail "ReScaleKB.dylib 不在信任缓存（键盘修正失效）"

# 8) 冲突
CONFLICT=$(grep -la IOMobileGraphicsFamily "$D"/*.dylib 2>/dev/null | xargs -n1 basename 2>/dev/null | grep -v '^ReScale.dylib$')
[ -z "$CONFLICT" ] && pass "无其它插件竞争画布偏好" || warn "同时改画布的插件：$CONFLICT"

# 9) backboardd 健康
if backboardd_running; then
    pass "backboardd 运行中"
else
    fail "backboardd 未运行"
fi
BB=$(launchctl print system/com.apple.backboardd 2>/dev/null)
RUNS=$(echo "$BB" | grep "runs =" | awk '{print $3}')
EXIT=$(echo "$BB" | grep "last exit code" | cut -d= -f2 | tr -d ' ')
warn "backboardd runs=$RUNS last_exit=$EXIT（runs 持续增大 + exit 非 0 = 崩溃循环）"

# 10) 自愈守护状态
if launchctl list 2>/dev/null | grep -q "com.xu.rescalefixed.heal"; then
    pass "自愈守护已加载（com.xu.rescalefixed.heal）"
else
    warn "自愈守护未加载（self-heal LaunchDaemon 不存在或未 bootstrap）"
fi

[ "$QUIET" = "1" ] || echo
[ "$QUIET" = "1" ] || echo "小计：通过 $ok / 失败 $bad / 本次修复 $repaired"
if [ "$bad" -gt 0 ] && [ "$QUIET" = "0" ]; then
    echo
    echo "注意："
    echo "  · 只缺 guard 标记/偏好 → 插件静默失效；--fix 修复后 respring 一次即恢复"
    echo "  · 缺信任缓存 → 先移除 ReScale.dylib 再 respring（避免看门狗），然后重装本包"
    echo "  · 运行期分辨率请用 get_screen_info / 截图确认（本脚本只查前置条件）"
fi
exit 0
