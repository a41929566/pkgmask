#!/system/bin/sh
# SUSFS Env Guard v3.0 - process_hide.sh（进程隐藏 · 内核层）
#
# 【设计原则】
#   ① 不杀进程！只在内核层拦截，让检测方看不到进程存在
#   ② 通过 pkgmask 的 hide_proc_names 节点，只影响 /proc 读取结果
#   ③ 支持 WebUI 动态添加/移除隐藏项
#
# 【依赖】pkgmask 内核模块（v4.11+），hide_proc_enabled / hide_proc_names 节点
#
# 【用法】
#   process_hide.sh apply      从配置应用隐藏列表
#   process_hide.sh list       列出当前所有进程（供 WebUI 选择）
#   process_hide.sh status     查看当前隐藏状态
#   process_hide.sh add <comm> 添加一个进程到隐藏列表
#   process_hide.sh del <comm> 从隐藏列表移除

. "${0%/*}/lib_common.sh"

PROC_CONF="$DATA_DIR/hidden_procs.txt"
PKG_SYSFS_DIR="/sys/module/pkgmask/parameters"
HIDE_NODE="$PKG_SYSFS_DIR/hide_proc_names"
EN_NODE="$PKG_SYSFS_DIR/hide_proc_enabled"

# ---------- 内核支持检测 ----------
kernel_supported() {
    [ -f "$HIDE_NODE" ] && [ -f "$EN_NODE" ]
}

# ---------- 读取配置的进程列表 ----------
load_procs() {
    [ -f "$PROC_CONF" ] || : > "$PROC_CONF"
    # 去空行、去注释、去重、每行一个 comm
    grep -v '^\s*#' "$PROC_CONF" 2>/dev/null | grep -v '^\s*$' | sort -u
}

# ---------- 写入内核节点（pkgmask 的 hide_proc_names 用逗号分隔） ----------
write_to_kernel() {
    local list="$1"
    # pkgmask 的 hide_proc_names 接受逗号分隔的字符串；空则写空
    if [ -w "$HIDE_NODE" ]; then
        printf '%s' "$list" > "$HIDE_NODE" 2>/dev/null
        return $?
    fi
    return 1
}

# ---------- apply：从配置应用到内核 ----------
do_apply() {
    init_feature_flags
    local on; on=$(get_config spoof_process_hide_enabled 0)

    if ! kernel_supported; then
        log 1 "process_hide: pkgmask hide_proc nodes not found, skipped"
        echo "PROCESS_HIDE=DISABLED (kernel unsupported)"
        return 1
    fi

    local procs
    procs=$(load_procs | tr '\n' ',' | sed 's/,$//')

    if [ "$on" != "1" ]; then
        # 功能关闭：清空节点
        write_to_kernel ""
        echo 0 > "$EN_NODE" 2>/dev/null
        log 2 "process_hide: disabled by config, cleared"
        echo "PROCESS_HIDE=DISABLED_BY_CONFIG"
        return 0
    fi

    if [ -z "$procs" ]; then
        write_to_kernel ""
        echo 0 > "$EN_NODE" 2>/dev/null
        log 2 "process_hide: no process to hide"
        echo "PROCESS_HIDE=OK (empty list)"
        return 0
    fi

    # 写入列表 + 启用
    if write_to_kernel "$procs"; then
        echo 1 > "$EN_NODE" 2>/dev/null
        log 2 "process_hide applied: $procs"
        echo "PROCESS_HIDE=OK"
        echo "  hidden: $procs"
        return 0
    else
        log 0 "process_hide: failed to write $HIDE_NODE"
        echo "PROCESS_HIDE=FAILED (write error)"
        return 1
    fi
}

# ---------- list：列出当前所有进程（供 WebUI 筛选） ----------
do_list() {
    # 输出格式：PID|UID|COMM
    # 优先用 ps -A，兜底 /proc 遍历
    if command -v ps >/dev/null 2>&1; then
        ps -A -o PID,UID,NAME 2>/dev/null | tail -n +2 | \
        while read -r pid uid name; do
            [ -z "$pid" ] && continue
            case "$pid" in *[!0-9]*) continue ;; esac
            echo "${pid}|${uid}|${name}"
        done
    else
        for d in /proc/[0-9]*; do
            [ -d "$d" ] || continue
            local pid=${d#/proc/}
            local name
            name=$(cat "$d/comm" 2>/dev/null)
            [ -z "$name" ] && continue
            echo "${pid}||${name}"
        done
    fi
}

# ---------- status：当前隐藏状态 ----------
do_status() {
    if ! kernel_supported; then
        echo "{"
        echo "  \"supported\": \"0\","
        echo "  \"reason\": \"pkgmask hide_proc nodes not found\""
        echo "}"
        return
    fi
    local en cur
    en=$(cat "$EN_NODE" 2>/dev/null)
    cur=$(cat "$HIDE_NODE" 2>/dev/null)
    echo "{"
    echo "  \"supported\": \"1\","
    echo "  \"enabled\": \"$en\","
    echo "  \"hidden_now\": \"$cur\","
    echo "  \"config_file\": \"$PROC_CONF\""
    echo "}"
}

# ---------- add / del：单个操作（供 WebUI 调用） ----------
do_add() {
    local comm="$1"
    [ -z "$comm" ] && { echo "usage: process_hide.sh add <comm>"; return 1; }
    touch "$PROC_CONF"
    if grep -qx "$comm" "$PROC_CONF" 2>/dev/null; then
        echo "already exists: $comm"
        return 0
    fi
    echo "$comm" >> "$PROC_CONF"
    do_apply >/dev/null 2>&1
    echo "added: $comm"
}

do_del() {
    local comm="$1"
    [ -z "$comm" ] && { echo "usage: process_hide.sh del <comm>"; return 1; }
    [ -f "$PROC_CONF" ] || { echo "no config"; return 1; }
    grep -vx "$comm" "$PROC_CONF" > "${PROC_CONF}.tmp" 2>/dev/null
    mv "${PROC_CONF}.tmp" "$PROC_CONF"
    do_apply >/dev/null 2>&1
    echo "deleted: $comm"
}

case "$1" in
    apply)  do_apply ;;
    list)   do_list ;;
    status) do_status ;;
    add)    do_add "$2" ;;
    del)    do_del "$2" ;;
    *) echo "usage: $0 {apply|list|status|add <comm>|del <comm>}" ;;
esac
