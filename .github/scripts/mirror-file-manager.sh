#!/bin/bash
# shellcheck disable=SC2155
# mirror-file-manager.sh - 镜像站文件结构管理工具
#
# 模式:
#   migrate      - 将根目录的扁平文件迁移到 {tag}/ 和 {tag}/delta/ 目录结构
#   update-root  - 更新根目录的兼容文件（复制指定稳定版到根目录）
#
# 用法:
#   mirror-file-manager.sh migrate [latest_stable_tag]
#   mirror-file-manager.sh update-root <tag>
#
# 必需环境变量: CLOUD_PROVIDER, CLOUD_AUTH
# 可选环境变量: TARGET_FOLDER, MOBILE_CLOUD_AUTHORIZATION

set -eo pipefail

ALIST_URL="http://localhost:5244"
CLOUD_PROVIDER="${CLOUD_PROVIDER:-quark}"
CLOUD_AUTH="${CLOUD_AUTH}"

case "$CLOUD_PROVIDER" in
    "quark")
        STORAGE_MOUNT_PATH="/Quark"
        CLOUD_DRIVER="Quark"
        TARGET_FOLDER="${TARGET_FOLDER:-img}"
        ROOT_FOLDER_ID="${ROOT_FOLDER_ID:-25aa15847d044a9bae0bb42be76ee253}"
        AUTH_FIELD="cookie"
        ;;
    "mobile")
        STORAGE_MOUNT_PATH="/139Yun"
        CLOUD_DRIVER="139Yun"
        TARGET_FOLDER="${TARGET_FOLDER:-Public/img}"
        ROOT_FOLDER_ID="${ROOT_FOLDER_ID:-/}"
        AUTH_FIELD="authorization"
        ;;
    *)
        echo "不支持的云盘类型: $CLOUD_PROVIDER" >&2
        exit 1
        ;;
esac

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; GRAY='\033[0;37m'; NC='\033[0m'

get_timestamp() { date '+%H:%M:%S'; }
log_info()    { echo -e "${GRAY}[$(get_timestamp)]${NC} ${BLUE}ℹ️  $1${NC}" >&2; }
log_success() { echo -e "${GRAY}[$(get_timestamp)]${NC} ${GREEN}✅ $1${NC}" >&2; }
log_warning() { echo -e "${GRAY}[$(get_timestamp)]${NC} ${YELLOW}⚠️  $1${NC}" >&2; }
log_error()   { echo -e "${GRAY}[$(get_timestamp)]${NC} ${RED}❌ $1${NC}" >&2; }

# ── Alist 基础操作 ────────────────────────────────────────────────────

deploy_alist() {
    log_info "部署临时 Alist 服务..."
    mkdir -p /tmp/alist-data
    docker run -d --name=temp-alist -p 5244:5244 \
        -v /tmp/alist-data:/opt/alist/data xhofe/alist:v3.45.0 >/dev/null
    for i in {1..30}; do
        curl -s "$ALIST_URL/ping" >/dev/null 2>&1 && break
        sleep 3
        [ "$i" -eq 30 ] && { log_error "Alist 启动超时"; exit 1; }
    done
    local pw="temp123456"
    docker exec temp-alist ./alist admin set "$pw" >/dev/null 2>&1
    echo "$pw"
}

get_alist_token() {
    local pw="$1"
    local resp=$(curl -s -X POST "$ALIST_URL/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"admin\",\"password\":\"$pw\"}")
    local token=$(echo "$resp" | jq -r '.data.token // empty')
    [ -n "$token" ] || { log_error "获取 Alist Token 失败"; exit 1; }
    echo "$token"
}

mount_cloud_storage() {
    local token="$1"
    log_info "挂载 ${CLOUD_PROVIDER} 云盘..."
    local addition_str
    case "$CLOUD_PROVIDER" in
        "quark")
            addition_str=$(jq -n --arg cookie "$CLOUD_AUTH" --arg rid "$ROOT_FOLDER_ID" \
                '{cookie:$cookie, root_folder_id:$rid, order_by:"file_name", order_direction:"asc"}' | jq -c .)
            ;;
        "mobile")
            addition_str=$(jq -n --arg auth "$CLOUD_AUTH" --arg rid "$ROOT_FOLDER_ID" \
                '{authorization:$auth, root_folder_id:$rid, type:"personal_new", cloud_id:"", custom_upload_part_size:0, report_real_size:true, use_large_thumbnail:false}' | jq -c .)
            ;;
    esac
    local req=$(jq -n --arg mp "$STORAGE_MOUNT_PATH" --arg drv "$CLOUD_DRIVER" \
        --arg add "$addition_str" \
        '{mount_path:$mp, driver:$drv, order:0, remark:"mirror-file-manager", addition:$add}')
    local resp=$(curl -s -X POST "$ALIST_URL/api/admin/storage/create" \
        -H "Authorization: $token" -H "Content-Type: application/json" -d "$req")
    local sid=$(echo "$resp" | jq -r '.data.id // empty')
    [ -n "$sid" ] || { log_error "挂载云盘失败"; exit 1; }
    log_success "云盘挂载成功 (ID: $sid)"
    echo "$sid"
}

cleanup() {
    log_info "清理临时资源..."
    local token="$1" sid="$2"
    [ -n "$sid" ] && curl -s -X POST "$ALIST_URL/api/admin/storage/delete" \
        -H "Authorization: $token" -H "Content-Type: application/json" \
        -d "{\"id\":$sid}" >/dev/null 2>&1 || true
    docker stop temp-alist 2>/dev/null; docker rm temp-alist 2>/dev/null
    sudo rm -rf /tmp/alist-data 2>/dev/null || rm -rf /tmp/alist-data 2>/dev/null || true
}

# ── Alist 文件操作 ────────────────────────────────────────────────────

# 创建目录（幂等）
alist_mkdir() {
    local token="$1" path="$2"
    _alist_fs_op "$token" "mkdir" "{\"path\":\"$path\"}" "创建目录 $path"
}

# 列出目录中的文件（非目录），每行输出一个文件名
alist_list_files() {
    local token="$1" path="$2"
    local page=1 per_page=100
    while true; do
        local resp
        resp=$(curl -sS --connect-timeout 30 -X POST "$ALIST_URL/api/fs/list" \
            -H "Authorization: $token" -H "Content-Type: application/json" \
            -d "{\"path\":\"$path\",\"page\":$page,\"per_page\":$per_page}" 2>&1) || {
            log_error "列目录失败 ($path): $resp"
            return 1
        }
        local code
        code=$(echo "$resp" | jq -r '.code // empty' 2>/dev/null)
        if [ "$code" != "200" ]; then
            local msg
            msg=$(echo "$resp" | jq -r '.message // empty' 2>/dev/null)
            log_error "列目录失败 ($path): 返回码 ${code:-无}, 信息: ${msg:-$resp}"
            return 1
        fi
        local items
        items=$(echo "$resp" | jq -r '.data.content[]? | select(.is_dir == false) | .name')
        [ -z "$items" ] && break
        echo "$items"
        local total
        total=$(echo "$resp" | jq -r '.data.total // 0')
        [ $((page * per_page)) -ge "$total" ] && break
        page=$((page + 1))
    done
}

# 列出目录中的子目录，每行输出一个目录名
alist_list_dirs() {
    local token="$1" path="$2"
    local resp
    resp=$(curl -sS --connect-timeout 30 -X POST "$ALIST_URL/api/fs/list" \
        -H "Authorization: $token" -H "Content-Type: application/json" \
        -d "{\"path\":\"$path\",\"per_page\":200}" 2>&1) || {
        log_error "列目录失败 ($path): $resp"
        return 1
    }
    echo "$resp" | jq -r '.data.content[]? | select(.is_dir == true) | .name'
}

# 通用 Alist 文件操作（带超时和错误日志）
_alist_fs_op() {
    local token="$1" endpoint="$2" payload="$3" op_desc="$4"
    local resp
    resp=$(curl -sS --connect-timeout 30 -X POST "$ALIST_URL/api/fs/$endpoint" \
        -H "Authorization: $token" -H "Content-Type: application/json" \
        -d "$payload" 2>&1) || {
        log_error "${op_desc}: curl 请求失败: $resp"
        return 1
    }
    local code
    code=$(echo "$resp" | jq -r '.code // empty' 2>/dev/null)
    if [ "$code" != "200" ]; then
        local msg
        msg=$(echo "$resp" | jq -r '.message // empty' 2>/dev/null)
        log_error "${op_desc}: 返回码 ${code:-无}, 信息: ${msg:-$resp}"
        return 1
    fi
    return 0
}

# 复制文件
alist_copy() {
    local token="$1" src_dir="$2" dst_dir="$3"
    shift 3
    local names_json=$(printf '%s\n' "$@" | jq -R . | jq -s .)
    _alist_fs_op "$token" "copy" \
        "{\"src_dir\":\"$src_dir\",\"dst_dir\":\"$dst_dir\",\"names\":$names_json}" \
        "复制 $src_dir -> $dst_dir ($# 个文件)"
}

# 移动文件
alist_move() {
    local token="$1" src_dir="$2" dst_dir="$3"
    shift 3
    local names_json=$(printf '%s\n' "$@" | jq -R . | jq -s .)
    _alist_fs_op "$token" "move" \
        "{\"src_dir\":\"$src_dir\",\"dst_dir\":\"$dst_dir\",\"names\":$names_json}" \
        "移动 $src_dir -> $dst_dir ($# 个文件)"
}

# 删除文件
alist_remove() {
    local token="$1" dir="$2"
    shift 2
    [ $# -eq 0 ] && return 0
    local names_json=$(printf '%s\n' "$@" | jq -R . | jq -s .)
    _alist_fs_op "$token" "remove" \
        "{\"dir\":\"$dir\",\"names\":$names_json}" \
        "删除 $dir ($# 个文件)"
}

# ── 文件分类辅助函数 ──────────────────────────────────────────────────

# 判断文件是否属于增量更新类型
is_delta_file() {
    local name="$1"
    case "$name" in
        *.skdelta|delta-manifest-*.json) return 0 ;;
        *) return 1 ;;
    esac
}

# 从镜像文件名中提取版本号
# skorionos-55-3_e605458-gnome-core-nv.skosys -> 55-3_e605458
# skorionos-55-3_e605458-gnome-core-nv.skosys.part1-2.skosys -> 55-3_e605458
parse_version_from_image() {
    echo "$1" | sed -n 's/\(chimeraos\|skorionos\)-\([0-9]\+\(-[0-9]\+\)\?_[a-f0-9]\+\)-.*/\2/p'
}

# 从增量包文件名中提取目标版本号（目标版本在文件名开头，格式同全量文件）
# skorionos-55-1_8d604af-gnome-nv.from_56_3bab24e.skdelta -> 55-1_8d604af
parse_version_from_delta() {
    parse_version_from_image "$1"
}

# ── 模式 A: 迁移 ──────────────────────────────────────────────────────

do_migrate() {
    local token="$1"
    local latest_tag="${2:-}"
    local root_path="$STORAGE_MOUNT_PATH/$TARGET_FOLDER"

    log_info "开始迁移 $root_path 中的扁平文件到版本目录结构..."

    local files
    files=$(alist_list_files "$token" "$root_path")
    if [ -z "$files" ]; then
        log_warning "根目录中没有找到文件: $root_path"
        return 0
    fi

    # 按版本号收集文件
    declare -A full_by_tag
    declare -A delta_by_tag

    local skipped=0
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        local ver=""

        if is_delta_file "$name"; then
            ver=$(parse_version_from_delta "$name")
            if [ -n "$ver" ]; then
                delta_by_tag["$ver"]+="$name"$'\n'
            else
                skipped=$((skipped + 1))
            fi
        else
            ver=$(parse_version_from_image "$name")
            if [ -n "$ver" ]; then
                full_by_tag["$ver"]+="$name"$'\n'
            else
                skipped=$((skipped + 1))
            fi
        fi
    done <<< "$files"
    [ "$skipped" -gt 0 ] && log_info "跳过 $skipped 个无法解析版本号的文件（sha256sum/delta-manifest 等），保留在根目录"

    # 收集所有涉及的版本号（去重）
    local all_tags=()
    for tag in "${!full_by_tag[@]}" "${!delta_by_tag[@]}"; do
        local found=false
        for t in "${all_tags[@]}"; do
            [ "$t" = "$tag" ] && { found=true; break; }
        done
        $found || all_tags+=("$tag")
    done

    # 迁移文件到版本目录：已存在的删除根目录副本，不存在的 move 过去
    local tag_count=0
    local total_moved=0 total_deleted=0
    for tag in "${all_tags[@]}"; do
        tag_count=$((tag_count + 1))
        local tag_dir="$root_path/$tag"
        local delta_dir="$tag_dir/delta"
        alist_mkdir "$token" "$tag_dir" || true

        # 处理全量文件
        if [ -n "${full_by_tag[$tag]:-}" ]; then
            local names=()
            while IFS= read -r n; do
                [ -n "$n" ] && names+=("$n")
            done <<< "${full_by_tag[$tag]}"

            local existing=""
            existing=$(alist_list_files "$token" "$tag_dir" 2>/dev/null) || true
            local to_move=() to_delete=()
            for fname in "${names[@]}"; do
                if echo "$existing" | grep -qxF "$fname"; then
                    to_delete+=("$fname")
                else
                    to_move+=("$fname")
                fi
            done

            local is_latest=false
            [ "$tag" = "$latest_tag" ] && is_latest=true

            if [ ${#to_delete[@]} -gt 0 ]; then
                if $is_latest; then
                    log_info "[$tag_count/${#all_tags[@]}] 跳过删除 ${#to_delete[@]} 个根目录全量文件 ($tag 是最新稳定版，需保留)"
                else
                    log_info "[$tag_count/${#all_tags[@]}] 删除 ${#to_delete[@]} 个根目录中的重复全量文件 ($tag)"
                    alist_remove "$token" "$root_path" "${to_delete[@]}" || \
                        log_warning "部分重复文件删除失败"
                    total_deleted=$((total_deleted + ${#to_delete[@]}))
                fi
            fi
            if [ ${#to_move[@]} -gt 0 ]; then
                if $is_latest; then
                    log_info "[$tag_count/${#all_tags[@]}] 复制 ${#to_move[@]} 个全量文件到 $tag_dir (保留根目录副本)"
                    alist_copy "$token" "$root_path" "$tag_dir" "${to_move[@]}" || \
                        log_warning "全量文件复制失败: $tag_dir"
                else
                    log_info "[$tag_count/${#all_tags[@]}] 移动 ${#to_move[@]} 个全量文件到 $tag_dir"
                    if alist_move "$token" "$root_path" "$tag_dir" "${to_move[@]}"; then
                        total_moved=$((total_moved + ${#to_move[@]}))
                    else
                        log_warning "全量文件移动失败: $tag_dir"
                    fi
                fi
            else
                log_info "[$tag_count/${#all_tags[@]}] 全量文件已全部存在于 $tag_dir，跳过"
            fi
        fi

        # 处理增量文件
        if [ -n "${delta_by_tag[$tag]:-}" ]; then
            alist_mkdir "$token" "$delta_dir" || true
            local names=()
            while IFS= read -r n; do
                [ -n "$n" ] && names+=("$n")
            done <<< "${delta_by_tag[$tag]}"

            local existing=""
            existing=$(alist_list_files "$token" "$delta_dir" 2>/dev/null) || true
            local to_move=() to_delete=()
            for fname in "${names[@]}"; do
                if echo "$existing" | grep -qxF "$fname"; then
                    to_delete+=("$fname")
                else
                    to_move+=("$fname")
                fi
            done

            local is_latest=false
            [ "$tag" = "$latest_tag" ] && is_latest=true

            if [ ${#to_delete[@]} -gt 0 ]; then
                if $is_latest; then
                    log_info "[$tag_count/${#all_tags[@]}] 跳过删除 ${#to_delete[@]} 个根目录增量文件 ($tag 是最新稳定版，需保留)"
                else
                    log_info "[$tag_count/${#all_tags[@]}] 删除 ${#to_delete[@]} 个根目录中的重复增量文件 ($tag)"
                    alist_remove "$token" "$root_path" "${to_delete[@]}" || \
                        log_warning "部分重复文件删除失败"
                    total_deleted=$((total_deleted + ${#to_delete[@]}))
                fi
            fi
            if [ ${#to_move[@]} -gt 0 ]; then
                if $is_latest; then
                    log_info "[$tag_count/${#all_tags[@]}] 复制 ${#to_move[@]} 个增量文件到 $delta_dir (保留根目录副本)"
                    alist_copy "$token" "$root_path" "$delta_dir" "${to_move[@]}" || \
                        log_warning "增量文件复制失败: $delta_dir"
                else
                    log_info "[$tag_count/${#all_tags[@]}] 移动 ${#to_move[@]} 个增量文件到 $delta_dir"
                    if alist_move "$token" "$root_path" "$delta_dir" "${to_move[@]}"; then
                        total_moved=$((total_moved + ${#to_move[@]}))
                    else
                        log_warning "增量文件移动失败: $delta_dir"
                    fi
                fi
            else
                log_info "[$tag_count/${#all_tags[@]}] 增量文件已全部存在于 $delta_dir，跳过"
            fi
        fi
    done

    log_success "迁移完成，共处理 ${#all_tags[@]} 个版本目录，移动 ${total_moved} 个文件，删除 ${total_deleted} 个重复文件"

    if [ -n "$latest_tag" ]; then
        log_info "最新稳定版 ($latest_tag) 的文件已保留在根目录（向下兼容）"
    fi
}

# ── 模式 B: 更新根目录兼容文件 ────────────────────────────────────────

do_update_root() {
    local token="$1"
    local tag="$2"
    local root_path="$STORAGE_MOUNT_PATH/$TARGET_FOLDER"
    local tag_dir="$root_path/$tag"
    local delta_dir="$tag_dir/delta"

    log_info "更新根目录兼容文件，版本: $tag"

    # 收集新版本应有的文件（全量 + 增量）
    local tag_files
    tag_files=$(alist_list_files "$token" "$tag_dir")
    if [ -z "$tag_files" ]; then
        log_warning "版本目录不存在或为空: $tag_dir，跳过该存储的根目录更新"
        return 0
    fi

    local delta_files=""
    delta_files=$(alist_list_files "$token" "$delta_dir" 2>/dev/null) || true

    # 合并新版本所有文件名（用于对比）
    local new_files_all=""
    [ -n "$tag_files" ] && new_files_all="$tag_files"
    [ -n "$delta_files" ] && new_files_all="${new_files_all:+$new_files_all
}$delta_files"

    # 获取根目录现有文件
    local root_files
    root_files=$(alist_list_files "$token" "$root_path")

    # 找出需要删除的文件（在根目录但不属于新版本）
    local to_delete=()
    if [ -n "$root_files" ]; then
        while IFS= read -r name; do
            [ -z "$name" ] && continue
            if ! echo "$new_files_all" | grep -qxF "$name"; then
                to_delete+=("$name")
            fi
        done <<< "$root_files"
    fi

    if [ ${#to_delete[@]} -gt 0 ]; then
        log_info "删除根目录中 ${#to_delete[@]} 个旧版本文件"
        alist_remove "$token" "$root_path" "${to_delete[@]}" || \
            log_warning "部分旧文件删除失败"
    fi

    # 找出需要复制的全量文件（在新版本中但根目录缺少）
    local to_copy_full=()
    while IFS= read -r name; do
        [ -z "$name" ] && continue
        if [ -z "$root_files" ] || ! echo "$root_files" | grep -qxF "$name"; then
            to_copy_full+=("$name")
        fi
    done <<< "$tag_files"

    if [ ${#to_copy_full[@]} -gt 0 ]; then
        log_info "从 $tag_dir 复制 ${#to_copy_full[@]} 个全量文件到根目录"
        alist_copy "$token" "$tag_dir" "$root_path" "${to_copy_full[@]}" || \
            log_warning "部分全量文件复制失败"
    fi

    # 找出需要复制的增量文件
    if [ -n "$delta_files" ]; then
        local to_copy_delta=()
        while IFS= read -r name; do
            [ -z "$name" ] && continue
            if [ -z "$root_files" ] || ! echo "$root_files" | grep -qxF "$name"; then
                to_copy_delta+=("$name")
            fi
        done <<< "$delta_files"

        if [ ${#to_copy_delta[@]} -gt 0 ]; then
            log_info "从 $delta_dir 复制 ${#to_copy_delta[@]} 个增量文件到根目录"
            alist_copy "$token" "$delta_dir" "$root_path" "${to_copy_delta[@]}" || \
                log_warning "部分增量文件复制失败"
        fi
    fi

    local deleted=${#to_delete[@]}
    local copied_delta=0
    [ -n "${to_copy_delta+x}" ] && copied_delta=${#to_copy_delta[@]}
    local copied=$((${#to_copy_full[@]} + copied_delta))
    if [ "$deleted" -eq 0 ] && [ "$copied" -eq 0 ]; then
        log_success "根目录文件已是最新版本 ($tag)，无需更新"
    else
        log_success "根目录兼容文件已更新，版本: $tag (删除 $deleted, 复制 $copied)"
    fi
}

# ── 主函数 ─────────────────────────────────────────────────────────────

main() {
    local mode="${1:?用法: $0 <migrate|update-root> [tag]}"
    local tag="${2:-}"

    log_info "镜像站文件管理 - 模式: $mode, 云盘: $CLOUD_PROVIDER"

    # 先设置基础清理 trap，确保 docker 容器始终被清理
    trap 'docker stop temp-alist 2>/dev/null; docker rm temp-alist 2>/dev/null; rm -rf /tmp/alist-data 2>/dev/null || true' EXIT

    local admin_pw=$(deploy_alist)
    local token=$(get_alist_token "$admin_pw")
    local sid=$(mount_cloud_storage "$token")

    # 更新 trap，加入存储卸载
    trap 'cleanup "$token" "$sid"' EXIT

    # 等待存储就绪
    sleep 5

    case "$mode" in
        migrate)
            do_migrate "$token" "$tag"
            ;;
        update-root)
            [ -z "$tag" ] && { log_error "update-root 模式需要指定 tag 参数"; exit 1; }
            do_update_root "$token" "$tag"
            ;;
        *)
            log_error "未知模式: $mode (支持: migrate, update-root)"
            exit 1
            ;;
    esac

    log_success "操作完成"
}

main "$@"
