#!/system/bin/sh
# SUSFS Env Guard v3.0 - susfs_fix.sh
# 独立 SUSFS 修复脚本，由 run.sh 和 daemon_loop.sh 共同调用
#
# 核心思路：
#   cmdline：读当前真值 → sed 替换敏感字段 → 写伪装文件
#   bootconfig：用固定模板 config/bootconfig_spoof.txt
#   sus_path：内置通用路径 + 配置文件追加 + 用户手动追加（user_hidden_paths.txt）

. "${0%/*}/lib_common.sh"

KS=""
for p in /data/adb/ksu/bin/ksu_susfs /data/adb/ksud/bin/ksu_susfs /data/adb/modules/susfs4ksu/bin/ksu_susfs; do
    [ -x "$p" ] && KS="$p" && break
done
[ -z "$KS" ] && { echo "SUSFS_FIX=NO_TOOL"; exit 1; }

D="$MODDIR/config"
F="$D/cmdline_fake.txt"
B="$D/bootconfig_spoof.txt"
USER_PATHS_FILE="$DATA_DIR/user_hidden_paths.txt"

# ---------- 1) cmdline 伪装 ----------
cat /proc/cmdline | tr '\n' ' ' | sed '
    s/oplusboot\.verifiedbootstate=[a-z]*/oplusboot.verifiedbootstate=green/g
    s/androidboot\.verifiedbootstate=[a-z]*/androidboot.verifiedbootstate=green/g
    s/androidboot\.vbmeta\.device_state=[a-z]*/androidboot.vbmeta.device_state=locked/g
    s/androidboot\.selinux=[a-z]*/androidboot.selinux=enforcing/g
    s/oplusboot\.mode=[a-z]*/oplusboot.mode=normal/g
' > "$F"
echo >> "$F"
cp "$F" "$D/cmdline_spoof.txt"

# ---------- 2) bootconfig 伪装 ----------
[ -s "$B" ] || { echo "SUSFS_FIX=NO_BOOTCONFIG_TEMPLATE"; exit 1; }

# ---------- 3) 注册 cmdline/bootconfig 重定向 ----------
"$KS" config cmdline_or_bootconfig remove 2>/dev/null
"$KS" config cmdline_or_bootconfig add "$B" 2>/dev/null
"$KS" set_cmdline_or_bootconfig "$B" 2>/dev/null

"$KS" config open_redirect remove /proc/cmdline 2>/dev/null
"$KS" config open_redirect add /proc/cmdline "$F" 3 2>/dev/null
"$KS" add_open_redirect /proc/cmdline "$F" 3 2>/dev/null

# ---------- 4) SUSFS 路径循环隐藏 ----------
# 收集三类路径：内置通用 + 配置文件额外 + 用户手动追加
collect_paths() {
    # 内置通用路径
    cat << 'BUILTIN'
/data/adb
/data/adb/ksu
/data/adb/ksu/bin
/data/adb/ksud
/data/adb/modules
/data/adb/zygisk
/system/bin/su
/system/xbin/su
/sbin/su
/vendor/bin/su
/dev/socket/ksud
BUILTIN

    # 配置文件里的额外路径（空格分隔）
    local extra
    extra=$(get_config SUSFS_PATH_HIDE_EXTRA "")
    if [ -n "$extra" ]; then
        echo "$extra" | tr ' ' '\n'
    fi

    # 用户手动添加的路径（每行一个，支持 # 注释）
    if [ -f "$USER_PATHS_FILE" ]; then
        grep -v '^[[:space:]]*#' "$USER_PATHS_FILE" 2>/dev/null | grep -v '^[[:space:]]*$'
    fi
}

hide_common_paths() {
    local ks="$1"
    local p
    collect_paths | while IFS= read -r p; do
        [ -z "$p" ] && continue
        [ -e "$p" ] || continue
        # 幂等：add 重复路径 SUSFS 会自动去重；失败不阻断
        "$ks" config sus_path add "$p" --loop 2>/dev/null || \
            "$ks" add_sus_path_loop "$p" 2>/dev/null || true
    done
}

[ "$(get_config SPOOF_PATH_HIDE 1)" = "1" ] && hide_common_paths "$KS"

# ---------- 5) 可选：AVC 日志伪装 + 隐藏 SUS 挂载 ----------
[ "$(get_config SPOOF_AVC_LOG 0)" = "1" ] && {
    "$KS" config avc_log_spoofing add 2>/dev/null
    "$KS" enable_avc_log_spoofing 1 2>/dev/null
}
[ "$(get_config SPOOF_HIDE_SUS_MNTS 0)" = "1" ] && {
    "$KS" config hide_sus_mnts_for_non_su_procs add 2>/dev/null
    "$KS" hide_sus_mnts_for_non_su_procs 1 2>/dev/null
}

log 2 "susfs_fix: applied cmdline+$B"
echo "SUSFS_FIX=OK"
exit 0
