#!/bin/bash
# shellcheck disable=SC2155
# cloud-sync-v2.sh - SkorionOS 139Yun 同步脚本 (模块化版本)
#
# 这是原 cloud-sync.sh 的重构版本，使用模块化设计：
# 1. 本脚本负责 GitHub Release 获取和文件过滤
# 2. Alist 相关功能委托给 alist-downloader.sh 模块
#
# 使用方式与原脚本相同，配置通过环境变量传递

set -e

# 配置变量 - 优先使用环境变量，否则使用默认值
USE_BATCH_DOWNLOAD="${USE_BATCH_DOWNLOAD:-true}"
BATCH_DOWNLOAD_THREADS="${BATCH_DOWNLOAD_THREADS:-3}"
BATCH_TRANSFER_THREADS="${BATCH_TRANSFER_THREADS:-3}"
TABLE_LANGUAGE="${TABLE_LANGUAGE:-zh}"
USE_EMOJI="${USE_EMOJI:-true}"
FORCE_SYNC="${FORCE_SYNC:-false}"

# SkorionOS 特定配置
STORAGE_MOUNT_PATH="/139Yun"
TARGET_FOLDER="Public/img"
FILE_FILTER_RULES="prefix:skorionos-,exclude:contains:hyprland,exclude:contains:cosmic,exclude:contains:cinnamon"

# 导入工具函数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/alist-utils.sh" ]; then
    source "$SCRIPT_DIR/alist-utils.sh"
else
    echo "错误: 无法找到工具函数文件 alist-utils.sh" >&2
    exit 1
fi

# 设置全局环境变量供工具函数使用
export TABLE_LANGUAGE
export USE_EMOJI

# 获取release信息
get_release_info() {
    local tag_name="$1"
    local github_token="$2"
    
    # 检查GitHub仓库环境变量
    if [ -z "$GITHUB_REPOSITORY" ]; then
        log_warning "GITHUB_REPOSITORY环境变量未设置，使用默认值"
        export GITHUB_REPOSITORY="SkorionOS/skorionos"
    fi
    
    log_info "获取release信息..."
    log_info "仓库: $GITHUB_REPOSITORY"
    
    if [ -n "$tag_name" ]; then
        log_info "指定标签: $tag_name"
        echo "$tag_name"
    else
        log_info "获取最新release (包括prerelease)..."
        
        local releases_response=$(curl -s -H "Authorization: Bearer $github_token" \
            "https://api.github.com/repos/$GITHUB_REPOSITORY/releases?per_page=10")
        
        # 检查API响应
        if ! echo "$releases_response" | jq . > /dev/null 2>&1; then
            log_error "releases API响应不是有效JSON: $releases_response"
            exit 1
        fi
        
        # 获取第一个release（最新的，包括prerelease）
        local latest_tag=$(echo "$releases_response" | jq -r '.[0].tag_name')
        
        if [ "$latest_tag" = "null" ] || [ -z "$latest_tag" ]; then
            log_error "未找到有效的release"
            log_error "API响应: $releases_response"
            exit 1
        fi
        
        # 检查是否为prerelease
        local is_prerelease=$(echo "$releases_response" | jq -r '.[0].prerelease')
        if [ "$is_prerelease" = "true" ]; then
            log_info "检测到prerelease: $latest_tag"
        else
            log_info "检测到正式release: $latest_tag"
        fi
        
        log_success "最新release: $latest_tag"
        echo "$latest_tag"
    fi
}

# 文件过滤函数
filter_file() {
    local filename="$1"
    local filesize="$2"  # 字节为单位
    local rules="$3"
    
    # 如果没有规则，默认通过
    if [ -z "$rules" ]; then
        return 0
    fi
    
    local size_mb=$((filesize / 1024 / 1024))
    local should_include=1  # 默认包含
    local has_include_rule=0  # 是否有包含规则
    
    # 分割规则
    local IFS=','
    for rule in $rules; do
        local rule_type=$(echo "$rule" | cut -d: -f1)
        local rule_pattern=$(echo "$rule" | cut -d: -f2-)
        
        case "$rule_type" in
            "prefix")
                has_include_rule=1
                if [[ "$filename" == "$rule_pattern"* ]]; then
                    should_include=0
                fi
                ;;
            "suffix")
                has_include_rule=1
                if [[ "$filename" == *"$rule_pattern" ]]; then
                    should_include=0
                fi
                ;;
            "contains")
                has_include_rule=1
                if [[ "$filename" == *"$rule_pattern"* ]]; then
                    should_include=0
                fi
                ;;
            "regex")
                has_include_rule=1
                if echo "$filename" | grep -qE "$rule_pattern"; then
                    should_include=0
                fi
                ;;
            "size_min")
                if [ "$size_mb" -lt "$rule_pattern" ]; then
                    return 1  # 文件太小，排除
                fi
                ;;
            "size_max")
                if [ "$size_mb" -gt "$rule_pattern" ]; then
                    return 1  # 文件太大，排除
                fi
                ;;
            "exclude")
                # 排除规则，支持子类型
                local exclude_type=$(echo "$rule_pattern" | cut -d: -f1)
                local exclude_pattern=$(echo "$rule_pattern" | cut -d: -f2-)
                
                case "$exclude_type" in
                    "prefix")
                        if [[ "$filename" == "$exclude_pattern"* ]]; then
                            return 1  # 排除
                        fi
                        ;;
                    "suffix")
                        if [[ "$filename" == *"$exclude_pattern" ]]; then
                            return 1  # 排除
                        fi
                        ;;
                    "contains")
                        if [[ "$filename" == *"$exclude_pattern"* ]]; then
                            return 1  # 排除
                        fi
                        ;;
                    "regex")
                        if echo "$filename" | grep -qE "$exclude_pattern"; then
                            return 1  # 排除
                        fi
                        ;;
                esac
                ;;
        esac
    done
    
    # 如果有包含规则但没匹配到，则排除
    if [ "$has_include_rule" -eq 1 ] && [ "$should_include" -eq 1 ]; then
        return 1
    fi
    
    return 0
}

# 获取下载链接
get_download_urls() {
    local tag_name="$1"
    local github_token="$2"
    local output_file="$3"
    
    log_info "获取下载链接列表..."
    
    # 获取release详细信息
    local release_response=$(curl -s -H "Authorization: Bearer $github_token" \
        "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/tags/$tag_name")
    
    # 检查API响应是否有效
    if ! echo "$release_response" | jq . > /dev/null 2>&1; then
        log_error "Release API响应不是有效JSON: $release_response"
        exit 1
    fi
    
    # 显示所有assets用于调试
    local all_assets=$(echo "$release_response" | jq -r '.assets[]?.name // empty')
    log_info "该release的所有文件:"
    echo "$all_assets" | while read -r asset; do
        if [ -n "$asset" ]; then
            echo "  📄 $asset" >&2
        fi
    done
    
    # 提取下载链接和文件信息，使用过滤系统
    echo "$release_response" | jq -r '.assets[] | "\(.browser_download_url)|\(.name)|\(.size)"' | while IFS='|' read -r url name size; do
        if [ -n "$url" ] && filter_file "$name" "$size" "$FILE_FILTER_RULES"; then
            echo "$url|$name|$size"
        fi
    done > "$output_file"
    
    local file_count=$(cat "$output_file" | wc -l)
    
    # 检查是否找到了匹配的文件
    if [ "$file_count" -eq 0 ]; then
        log_warning "未找到符合过滤规则的文件"
        log_info "过滤规则: $FILE_FILTER_RULES"
        log_info "该release可能不包含符合条件的文件，跳过同步"
        return 1
    fi
    
    # 计算总大小
    local total_size=0
    while IFS='|' read -r url name size; do
        if [ -n "$size" ]; then
            total_size=$((total_size + size))
        fi
    done < "$output_file"
    local total_size_gb=$((total_size / 1024 / 1024 / 1024))
    
    log_success "找到 $file_count 个符合过滤规则的文件，总大小: ${total_size_gb}GB"
    log_info "过滤规则: $FILE_FILTER_RULES"
    
    # 显示文件列表
    log_info "文件列表:"
    while IFS='|' read -r url name size; do
        if [ -n "$url" ]; then
            local size_mb=$((size / 1024 / 1024))
            echo "  📄 $name (${size_mb}MB)" >&2
        fi
    done < "$output_file"
}

# 主函数
main() {
    local tag_name="$1"
    local github_token="$2"
    local mobile_authorization="$3"
    
    echo "🚀 SkorionOS139Yun同步开始 (模块化版本)"
    echo "================================================"
    
    # 显示下载模式
    if [ "$USE_BATCH_DOWNLOAD" = "true" ]; then
        log_info "使用多线程批量下载模式 (下载:${BATCH_DOWNLOAD_THREADS}线程, 传输:${BATCH_TRANSFER_THREADS}线程)"
    else
        log_info "使用单文件下载模式"
    fi
    
    # 获取release信息
    local release_tag=$(get_release_info "$tag_name" "$github_token")
    
    # 获取下载链接
    local download_list_file="/tmp/download_list.txt"
    if ! get_download_urls "$release_tag" "$github_token" "$download_list_file"; then
        log_warning "没有需要同步的文件，退出"
        return 0
    fi
    
    # 准备目标路径
    local target_path="$STORAGE_MOUNT_PATH/$TARGET_FOLDER"
    
    # 准备存储配置
    local storage_config=$(cat <<EOF
{
    "mount_path": "$STORAGE_MOUNT_PATH",
    "driver": "139Yun",
    "addition": "{\"authorization\":\"${mobile_authorization}\",\"root_folder_id\":\"/\",\"type\":\"personal_new\",\"cloud_id\":\"\",\"custom_upload_part_size\":0,\"report_real_size\":true,\"use_large_thumbnail\":false}",
    "remark": "SkorionOS Release同步"
}
EOF
    )
    
    # 准备选项配置
    local options_config=$(cat <<EOF
{
    "batch_mode": $USE_BATCH_DOWNLOAD,
    "download_threads": $BATCH_DOWNLOAD_THREADS,
    "transfer_threads": $BATCH_TRANSFER_THREADS,
    "language": "$TABLE_LANGUAGE",
    "use_emoji": $USE_EMOJI,
    "force_sync": $FORCE_SYNC,
    "timeout": 1800,
    "check_interval": 5
}
EOF
    )
    
    # 调用 alist-downloader 模块
    log_info "调用 Alist 下载模块..."
    local success_count
    if [ -x "$SCRIPT_DIR/alist-downloader.sh" ]; then
        success_count=$("$SCRIPT_DIR/alist-downloader.sh" \
            "$storage_config" \
            "$target_path" \
            "$download_list_file" \
            "$options_config")
    else
        log_error "Alist下载模块不存在或不可执行: $SCRIPT_DIR/alist-downloader.sh"
        exit 1
    fi
    
    # 清理临时文件
    rm -f "$download_list_file"
    
    echo ""
    echo "================================================"
    log_success "SkorionOS $release_tag 同步完成！"
    log_success "📱 目标: 139Yun"
    log_success "📁 路径: $target_path"
    log_success "📊 成功文件数: $success_count"
    log_success "🎯 文件过滤: $FILE_FILTER_RULES"
    if [ "$USE_BATCH_DOWNLOAD" = "true" ]; then
        log_success "⚡ 下载模式: 多线程批量 (${BATCH_DOWNLOAD_THREADS}+${BATCH_TRANSFER_THREADS}线程)"
    else
        log_success "📝 下载模式: 单文件下载"
    fi
    echo "用户现在可以通过139Yun快速下载了！"
}

# 检查必需参数
if [ $# -lt 3 ]; then
    echo "Usage: $0 <tag_name> <github_token> <mobile_authorization>"
    echo "  tag_name: Release标签 (留空使用最新)"
    echo "  github_token: GitHub Token"
    echo "  mobile_authorization: 139Yun 认证"
    echo ""
    echo "Note: 配置通过环境变量传递"
    echo "  USE_BATCH_DOWNLOAD, BATCH_DOWNLOAD_THREADS, BATCH_TRANSFER_THREADS"
    echo "  TABLE_LANGUAGE, USE_EMOJI, FORCE_SYNC"
    exit 1
fi

# 执行主函数
main "$1" "$2" "$3"
