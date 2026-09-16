#!/system/bin/sh
# SUSFS Env Guard v3.0 - susfs_fix.sh
# 独立 SUSFS 修复脚本，由 run.sh 和 daemon_loop.sh 共同调用
#
# 核心思路：
#   读当前真实 /proc/cmdline 和 /proc/bootconfig
#   → sed 替换敏感字段（verifiedbootstate/selinux/vbmeta_state/flash.locked）
#   → 写入伪装文件
#   → 注册到内核 SUSFS
#   这样伪装文件长度与真机一致，不会被"字段太少"检测

. "${0%/*}/lib_common.sh"

# 找到 ksu_susfs 工具
find_ksu_susfs() {
    local p
    for p in /data/adb/ksu/bin/ksu_susfs /data/adb/ksud/bin/ksu_susfs \
             /data/adb/modules/susfs4ksu/bin/ksu_susfs; do
        [ -x "$p" ] && { echo "$p"; return 0; }
    done
    command -v ksu_susfs 2>/dev/null
}

# 生成伪装 cmdline（保留所有字段，只替换敏感值）
gen_spoof_cmdline() {
    local out="$1"
    cat /proc/cmdline 2>/dev/null | tr '\n' ' ' | sed '
        s/oplusboot\.verifiedbootstate=[a-z]*/oplusboot.verifiedbootstate=green/g
        s/androidboot\.verifiedbootstate=[a-z]*/androidboot.verifiedbootstate=green/g
        s/androidboot\.vbmeta\.device_state=[a-z]*/androidboot.vbmeta.device_state=locked/g
        s/androidboot\.flash\.locked=[01]/androidboot.flash.locked=1/g
        s/androidboot\.selinux=[a-z]*/androidboot.selinux=enforcing/g
    ' > "$out"
    echo >> "$out"
}

# 生成伪装 bootconfig（保留所有字段，只替换敏感值）
gen_spoof_bootconfig() {
    local out="$1"
    cat /proc/bootconfig 2>/dev/null | sed '
        s/\(androidboot\.verifiedbootstate[[:space:]]*=[[:space:]]*\)"[a-z]*"/\1"green"/g
        s/\(androidboot\.vbmeta\.device_state[[:space:]]*=[[:space:]]*\)"[a-z]*"/\1"locked"/g
        s/\(androidboot\.flash\.locked[[:space:]]*=[[:space:]]*\)"[01]"/\1"1"/g
        s/\(androidboot\.selinux[[:space:]]*=[[:space:]]*\)"[a-z]*"/\1"enforcing"/g
    ' > "$out"
}

do_apply() {
    local KS
    KS=$(find_ksu_susfs)
    if [ -z "$KS" ]; then
        log 0 "susfs_fix: ksu_susfs 未找到"
        echo "SUSFS_FIX=NO_TOOL"
        return 1
    fi

    local spoof_txt="$MODDIR/config/cmdline_spoof.txt"
    local fake_txt="$MODDIR/config/cmdline_fake.txt"
    local bc_spoof="$MODDIR/config/bootconfig_spoof.txt"
    mkdir -p "$MODDIR/config"

    # 1) 生成伪装 cmdline（open_redirect 用）
    gen_spoof_cmdline "$fake_txt"
    cp "$fake_txt" "$spoof_txt"
    chmod 644 "$spoof_txt" "$fake_txt" 2>/dev/null

    # 2) 生成伪装 bootconfig（cmdline_or_bootconfig 用）
    gen_spoof_bootconfig "$bc_spoof"
    chmod 644 "$bc_spoof" 2>/dev/null

    log 2 "susfs_fix: spoof_cmdline=$spoof_txt bc_spoof=$bc_spoof"

    # 3) 注册 bootconfig 重定向
    "$KS" config cmdline_or_bootconfig remove 2>/dev/null
    "$KS" config cmdline_or_bootconfig add "$bc_spoof" 2>/dev/null
    "$KS" set_cmdline_or_bootconfig "$bc_spoof" 2>/dev/null

    # 4) 注册 cmdline open_redirect
    "$KS" config open_redirect remove /proc/cmdline 2>/dev/null
    "$KS" config open_redirect add /proc/cmdline "$fake_txt" 3 2>/dev/null
    "$KS" add_open_redirect /proc/cmdline "$fake_txt" 3 2>/dev/null

    # 5) 可选：AVC 日志伪装 + 挂载隐藏
    [ "$(get_config SPOOF_AVC_LOG 0)" = "1" ] && {
        "$KS" config avc_log_spoofing add 2>/dev/null
        "$KS" enable_avc_log_spoofing 1 2>/dev/null
    }
    [ "$(get_config SPOOF_HIDE_SUS_MNTS 0)" = "1" ] && {
        "$KS" config hide_sus_mnts_for_non_su_procs add 2>/dev/null
        "$KS" hide_sus_mnts_for_non_su_procs 1 2>/dev/null
    }

    log 2 "susfs_fix: applied"
    echo "SUSFS_FIX=OK"
    return 0
}

do_check() {
    echo "--- ksu_susfs ---"
    command -v ksu_susfs || echo "(未找到)"
    echo "--- /proc/bootconfig (root 视角，应被重定向) ---"
    cat /proc/bootconfig 2>/dev/null | grep -iE "verified|device_state|selinux"
    echo "--- 伪装 cmdline 文件（前 200 字符）---"
    head -c 200 "$MODDIR/config/cmdline_fake.txt" 2>/dev/null
    echo ""
    echo "--- 伪装 bootconfig 文件（前 200 字符）---"
    head -c 200 "$MODDIR/config/bootconfig_spoof.txt" 2>/dev/null
    echo ""
}

case "$1" in
    apply) do_apply ;;
    check) do_check ;;
    *) do_apply ;;
esac
