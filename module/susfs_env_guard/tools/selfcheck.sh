#!/system/bin/sh
# SUSFS Env Guard v3.0 - 自检诊断（POSIX sh / mksh 兼容，禁止 declare -A）
# 用法: selfcheck.sh  （输出文本 + 写 selfcheck_result.json）

. "${0%/*}/lib_common.sh"

PASS=0; WARN=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
wn(){ WARN=$((WARN+1)); echo "[WARN] $*"; }
no(){ FAIL=$((FAIL+1)); echo "[FAIL] $*"; }
ps_(){ PASS=$((PASS+1)); echo "[PASS] $*"; }

echo "===== SUSFS Env Guard v3.0 自检 $(date) ====="

# ============================================================
# 1. 文件完整性（补充新增文件）
# ============================================================
echo "--- 文件完整性 ---"
for f in post-fs-data.sh service.sh customize.sh module.prop sepolicy.rule \
         tools/lib_common.sh tools/props_spoof.sh tools/randomize.sh \
         tools/pkgmask_setup.sh tools/appops_setup.sh tools/daemon_loop.sh \
         tools/process_hide.sh tools/run.sh tools/run_verify.sh \
         config/spoof.conf.example webroot/index.html; do
    if [ -f "$MODDIR/$f" ]; then ok; else no "缺失 $f"; fi
done
[ -f "$CONF" ] && ps_ "配置存在" || wn "配置缺失(用默认)"

# ============================================================
# 2. 属性伪装（安全版：只检查安全区属性）
#    ⚠️ 不再检查 ro.boot.verifiedbootstate 等，因为模块不再修改它们
# ============================================================
echo "--- 属性伪装（安全区） ---"
init_feature_flags
PROPS_ON=$(get_config spoof_props_enabled 0)
HWID_ON=$(get_config spoof_hwid_enabled 0)
AID_ON=$(get_config spoof_android_id 0)

G=0
if [ "$PROPS_ON" = 1 ] || [ "$HWID_ON" = 1 ] || [ "$AID_ON" = 1 ]; then
    G=1
fi

if [ "$PROPS_ON" = 1 ]; then
    # 只检查安全区属性（非 ro.boot.*）
    TMPF="$RUN_DIR/.sc_props"; : > "$TMPF"
    echo "ro.debuggable:0
ro.secure:1
ro.build.tags:release-keys
ro.build.type:user
sys.oem_unlock_allowed:0" | while IFS=: read -r p e; do
        a=$(getprop "$p")
        if [ "$a" = "$e" ]; then
            echo P >> "$TMPF"
        else
            echo F >> "$TMPF"
            echo "[FAIL] $p=$a 期望 $e" >> "$TMPF.log"
        fi
    done
    P=$(grep -c P "$TMPF" 2>/dev/null); F=$(grep -c F "$TMPF" 2>/dev/null)
    PASS=$((PASS+P)); FAIL=$((FAIL+F))
    cat "$TMPF.log" 2>/dev/null
    rm -f "$TMPF" "$TMPF.log"
    [ "$F" = "0" ] && ps_ "安全区属性全部符合期望（5/5）" || true
else
    wn "属性伪装未启用（显示真值属预期）"
fi

# ============================================================
# 3. 引导状态伪装（内核重定向，不通过属性层）
#    检查 /proc/bootconfig 和 /proc/cmdline 是否被 SUSFS 重定向
# ============================================================
echo "--- 引导状态伪装（内核层） ---"
BC=$(cat /proc/bootconfig 2>/dev/null | tr '\n' ' ')
case "$BC" in
    *verifiedbootstate=green*|*device_state=locked*)
        ps_ "bootconfig 内核重定向生效"
        ;;
    *)
        wn "bootconfig 内核重定向未生效（正常：需先执行一次 susfs_fix）"
        ;;
esac

CL=$(cat /proc/cmdline 2>/dev/null | tr '\n' ' ')
case "$CL" in
    *verifiedbootstate=green*)
        ps_ "cmdline 对普通进程已重定向"
        ;;
    *)
        wn "cmdline 未重定向（正常：open_redirect 由 susfs_fix 注入）"
        ;;
esac

# 属性层不再检查 ro.boot.verifiedbootstate，因为它不应该被我们改
VB_PROP=$(getprop ro.boot.verifiedbootstate)
ps_ "ro.boot.verifiedbootstate=$VB_PROP（不改动，交给内核重定向）"

# ============================================================
# 4. 硬件只读 ID（内核 hwid_spoof）
# ============================================================
echo "--- 硬件只读ID ---"
if [ -f "$HWID_SYSFS/hwid_enabled" ]; then
    HE=$(cat "$HWID_SYSFS/hwid_enabled" 2>/dev/null)
    if [ "$HWID_ON" = 1 ] && bool_on "$HE"; then
        HS=$(cat "$HWID_SYSFS/hwid_status" 2>/dev/null)
        echo "$HS" | grep -q 'hook_active=1' && ps_ "内核 hwid hook 已注册" \
            || no "hwid hook 未注册（kretprobe 不可用或未链接）"
        echo "$HS" | grep -q '^wlan_mac=..' && ps_ "内核 hwid 已加载假MAC" \
            || no "hwid 假值未就位"

        . "$DATA_DIR/fake_profile.conf" 2>/dev/null
        HWID_SCOPE=$(get_config hwid_uids "")
        if [ -n "$HWID_SCOPE" ]; then
            wn "hwid_uids 已限定为 [$HWID_SCOPE]；root 自检读取不代表目标应用视角"
        fi

        ACTUAL_WMAC=""
        for f in /sys/class/net/wlan*/address /sys/class/net/wlp*/address; do
            [ -r "$f" ] && { ACTUAL_WMAC=$(cat "$f" 2>/dev/null); break; }
        done
        if [ -n "$HWID_SCOPE" ]; then
            wn "跳过 root WLAN MAC 命中判断（需用目标 UID 验证）"
        elif [ "$ACTUAL_WMAC" = "$fake_wmac" ]; then
            ps_ "WLAN MAC 读取已替换"
        else
            wn "WLAN MAC 读取未匹配（当前=${ACTUAL_WMAC:-N/A}）"
        fi

        ACTUAL_SOC=$(cat /sys/devices/soc0/serial_number 2>/dev/null)
        if [ -n "$HWID_SCOPE" ]; then
            wn "跳过 root SoC Serial 命中判断（需用目标 UID 验证）"
        else
            case "$ACTUAL_SOC" in
                "$fake_soc"*) ps_ "SoC Serial 实际读取已替换" ;;
                *) wn "SoC Serial 实际读取未匹配（当前=$ACTUAL_SOC）" ;;
            esac
        fi
    else
        wn "hwid_spoof 未使能(enabled=$HE；可接受值为 1/Y)"
    fi
else
    wn "内核无 hwid_spoof（未找到 $HWID_SYSFS）"
fi

# ============================================================
# 5. pkgmask（应用隐藏 + 进程隐藏）
# ============================================================
echo "--- pkgmask ---"
if [ -d "$PKG_SYSFS" ]; then
    DU=$(cat "$PKG_SYSFS/deny_uids" 2>/dev/null)
    TP=$(cat "$PKG_SYSFS/target_paths" 2>/dev/null)
    [ -n "$DU" ] && ps_ "pkgmask deny_uids=$DU" || wn "pkgmask 无 deny_uids（检测方未装？）"
    [ -n "$TP" ] && ps_ "pkgmask target_paths 已配置" || wn "pkgmask 无 target_paths"

    HG=$(cat "$PKG_SYSFS/hook_getdents" 2>/dev/null)
    HD=$(cat "$PKG_SYSFS/hide_dirents" 2>/dev/null)
    if [ "$HG" = "1" ] && [ "$HD" = "1" ]; then
        ps_ "内核目录隐藏已启用（防零宽扫盘关键）"
    else
        no "hook_getdents=$HG hide_dirents=$HD 未同时启用"
    fi

    HP=$(cat "$PKG_SYSFS/hide_proc_enabled" 2>/dev/null)
    HN=$(cat "$PKG_SYSFS/hide_proc_names" 2>/dev/null)
    [ "$HP" = "1" ] && ps_ "进程隐藏已启用：$HN" || wn "进程隐藏未启用"
else
    no "内核无 pkgmask"
fi

# ============================================================
# 6. SUSFS
# ============================================================
echo "--- SUSFS ---"
SUSFS_DIR="/sys/module/susfs"
if ls -ld "$SUSFS_DIR" >/dev/null 2>&1; then
    ps_ "SUSFS 模块目录存在"
    SUSFS_FILES=$(find "$SUSFS_DIR" -maxdepth 2 -type f 2>/dev/null | head -n 1)
    [ -n "$SUSFS_FILES" ] && ps_ "SUSFS 节点可读取: $SUSFS_FILES" \
        || wn "SUSFS 目录存在但未找到可读取节点"
    if [ -f "$SUSFS_DIR/version" ]; then
        ps_ "SUSFS $(cat "$SUSFS_DIR/version" 2>/dev/null)"
    else
        wn "SUSFS version 节点不存在（可能已启用隐藏版本信息）"
    fi
else
    wn "SUSFS 节点不可见（可能为内置或隐藏；不能仅凭 /sys/module 判定）"
fi

# ============================================================
# 7. 守护进程
# ============================================================
echo "--- 守护进程 ---"
DP=$(pidof daemon_loop.sh 2>/dev/null)
[ -n "$DP" ] && ps_ "守护进程运行 PID=$DP" || no "守护进程未运行"

# ============================================================
# 汇总
# ============================================================
echo "===== 汇总 PASS=$PASS WARN=$WARN FAIL=$FAIL ====="
cat > "$DATA_DIR/selfcheck_result.json" << EOF
{ "timestamp": "$(date +%s)", "pass": $PASS, "warn": $WARN, "fail": $FAIL,
  "global": "$G", "kernel": "$(uname -r)" }
EOF
chmod 644 "$DATA_DIR/selfcheck_result.json" 2>/dev/null

exit 0
