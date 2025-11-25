#!/bin/bash
# shellcheck disable=SC2155
# cloud-sync.sh - SkorionOS 多云盘同步脚本
#
# 支持云盘类型:
# - mobile: 移动云盘(139Yun)
# - quark: 夸克网盘
#
# 支持两种下载模式:
# 1. 多线程批量下载（默认）: USE_BATCH_DOWNLOAD=true
#    - 同时提交所有文件，并行下载传输
#    - 实时表格显示进度，支持中英文和emoji
#    - 动态配置和恢复Alist线程数
# 2. 单文件下载: USE_BATCH_DOWNLOAD=false  
#    - 逐个文件下载，兼容原有逻辑
#
# 可配置项:
# - CLOUD_PROVIDER: "mobile"(移动云盘) 或 "quark"(夸克网盘)
# - CLOUD_AUTH: 云盘认证信息
# - TARGET_FOLDER: 目标文件夹路径
# - TABLE_LANGUAGE: "zh"(中文) 或 "en"(英文)
# - USE_EMOJI: true(显示emoji) 或 false(纯文本)
# - BATCH_DOWNLOAD_THREADS: 下载线程数
# - BATCH_TRANSFER_THREADS: 传输线程数

set -e

# 配置变量
ALIST_URL="http://localhost:5244"

# 云盘配置 - 通过环境变量指定
CLOUD_PROVIDER="${CLOUD_PROVIDER:-mobile}"  # mobile 或 quark
CLOUD_AUTH="${CLOUD_AUTH}"  # 统一的认证信息环境变量

# 根据云盘类型设置配置
case "$CLOUD_PROVIDER" in
    "quark")
        STORAGE_MOUNT_PATH="/Quark"
        CLOUD_DRIVER="Quark"
        TARGET_FOLDER="${TARGET_FOLDER:-SkorionOS_Github/img}"
        AUTH_FIELD="cookie"
		_FILE_FILTER_RULES="prefix:skorionos-,contains:-nv"
        ;;
    "mobile")
        STORAGE_MOUNT_PATH="/139Yun"
        CLOUD_DRIVER="139Yun"
        TARGET_FOLDER="${TARGET_FOLDER:-Public/img}"
        AUTH_FIELD="authorization"
		_FILE_FILTER_RULES="prefix:skorionos-,exclude:contains:hyprland,exclude:contains:cosmic,exclude:contains:cinnamon"
        ;;
    *)
        echo "❌ 不支持的云盘类型: $CLOUD_PROVIDER" >&2
        echo "支持的类型: mobile, quark" >&2
        exit 1
        ;;
esac

# 配置变量 - 优先使用环境变量，否则使用默认值
USE_BATCH_DOWNLOAD="${USE_BATCH_DOWNLOAD:-true}"  # true: 多线程批量下载, false: 单文件下载
BATCH_DOWNLOAD_THREADS="${BATCH_DOWNLOAD_THREADS:-5}"   # 批量下载线程数
BATCH_TRANSFER_THREADS="${BATCH_TRANSFER_THREADS:-5}"   # 批量传输线程数
TABLE_LANGUAGE="${TABLE_LANGUAGE:-zh}"      # 表格语言: zh(中文) 或 en(英文)
USE_EMOJI="${USE_EMOJI:-true}"           # 是否在状态中显示emoji
FORCE_SYNC="${FORCE_SYNC:-false}"       # 强制同步模式

# 文件过滤规则 - 支持多种规则类型
# 格式: "type:pattern" 多个规则用逗号分隔
# 类型:
#   prefix:xxx    - 前缀匹配
#   suffix:xxx    - 后缀匹配
#   contains:xxx  - 包含匹配
#   regex:xxx     - 正则表达式匹配
#   size_min:xxx  - 最小文件大小 (MB)
#   size_max:xxx  - 最大文件大小 (MB)
#   exclude:xxx   - 排除规则 (支持 prefix/suffix/contains/regex)
#
# 示例配置:
#   "prefix:skorionos-"                          # 只下载skorionos-开头的文件
#   "prefix:skorionos-,exclude:suffix:.txt"     # 下载skorionos-开头但排除.txt文件
#   "suffix:.img.xz,size_min:100"               # 下载.img.xz结尾且大于100MB的文件
#   "contains:kde,exclude:contains:nv"          # 包含kde但不包含nv的文件
#   "regex:.*-(kde|gnome)\..*"                  # 正则匹配包含kde或gnome的文件
FILE_FILTER_RULES=${_FILE_FILTER_RULES}
TIMEOUT_SECONDS=1800
CHECK_INTERVAL=5

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GRAY='\033[0;37m'
NC='\033[0m' # No Color

# 获取当前时间戳
get_timestamp() {
    date '+%H:%M:%S'
}

log_info() {
    echo -e "${GRAY}[$(get_timestamp)]${NC} ${BLUE}ℹ️  $1${NC}" >&2
}

log_success() {
    echo -e "${GRAY}[$(get_timestamp)]${NC} ${GREEN}✅ $1${NC}" >&2
}

log_warning() {
    echo -e "${GRAY}[$(get_timestamp)]${NC} ${YELLOW}⚠️  $1${NC}" >&2
}

log_error() {
    echo -e "${GRAY}[$(get_timestamp)]${NC} ${RED}❌ $1${NC}" >&2
}

# 进度日志 (带时间戳)
log_progress() {
    echo -e "${GRAY}[$(get_timestamp)]${NC} ${BLUE}⏳ $1${NC}" >&2
}

# 计算字符串的显示宽度（使用wcswidth思路）
get_display_width() {
    local text="$1"
    
    # 使用python计算显示宽度（如果可用）
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import sys
import unicodedata

def display_width(s):
    width = 0
    for char in s:
        if unicodedata.east_asian_width(char) in ('F', 'W'):
            width += 2  # 全角字符
        elif unicodedata.category(char).startswith('M'):
            width += 0  # 合成字符（不占显示宽度）
        else:
            width += 1  # 半角字符
    return width

print(display_width('$text'))
" 2>/dev/null
    else
        # 降级方案：简单的字节数分析
        local char_count=$(echo -n "$text" | wc -m)
        local byte_count=$(echo -n "$text" | wc -c)
        
        # 如果字节数是字符数的2倍以上，很可能包含较多中文
        if [ $byte_count -gt $((char_count * 2)) ]; then
            # 估算：大多数是中文，按1.8倍计算
            echo $((char_count * 18 / 10))
        elif [ $byte_count -gt $((char_count + char_count / 3)) ]; then
            # 估算：部分中文，按1.4倍计算
            echo $((char_count * 14 / 10))
        else
            # 主要是ASCII
            echo $char_count
        fi
    fi
}

# 生成指定长度的空格，用于对齐
pad_to_width() {
    local text="$1"
    local target_width="$2"
    local display_width
    display_width=$(get_display_width "$text")
    local padding=$((target_width - display_width))
    
    if [ $padding -gt 0 ]; then
        printf "%s%*s" "$text" $padding ""
    else
        printf "%s" "$text"
    fi
}

# 获取本地化文本（支持中英文和emoji）
get_text() {
    local key="$1"
    
    if [ "$USE_EMOJI" = "true" ]; then
        # emoji版本
        case "$TABLE_LANGUAGE" in
            "zh")
                case "$key" in
                    "filename") echo "📁 文件名" ;;
                    "download_status") echo "⬇️ 下载状态" ;;
                    "transfer_status") echo "☁️ 传输状态" ;;
                    "progress") echo "📊 进度" ;;
                    "waiting_download") echo "⏳ 等待下载" ;;
                    "downloading") echo "⬇️ 下载中" ;;
                    "download_complete") echo "✅ 下载完成" ;;
                    "download_failed") echo "❌ 下载失败" ;;
                    "waiting_transfer") echo "⏳ 等待传输" ;;
                    "transferring") echo "☁️ 传输中" ;;
                    "transfer_complete") echo "✅ 传输完成" ;;
                    "transfer_failed") echo "❌ 传输失败" ;;
                    "not_started") echo "⭕ 未开始" ;;
                    "unknown") echo "❓ 未知" ;;
                    *) echo "$key" ;;
                esac
                ;;
            "en")
                case "$key" in
                    "filename") echo "📁 Filename" ;;
                    "download_status") echo "⬇️ Download" ;;
                    "transfer_status") echo "☁️ Transfer" ;;
                    "progress") echo "📊 Progress" ;;
                    "waiting_download") echo "⏳ Waiting" ;;
                    "downloading") echo "⬇️ Pulling" ;;
                    "download_complete") echo "✅ Complete" ;;
                    "download_failed") echo "❌ Failed" ;;
                    "waiting_transfer") echo "⏳ Queued" ;;
                    "transferring") echo "☁️ Pushing" ;;
                    "transfer_complete") echo "✅ Stored" ;;
                    "transfer_failed") echo "❌ Error" ;;
                    "not_started") echo "⭕ Pending" ;;
                    "unknown") echo "❓ Unknown" ;;
                    *) echo "$key" ;;
                esac
                ;;
            *) echo "$key" ;;
        esac
    else
        # 纯文本版本
        case "$TABLE_LANGUAGE" in
            "zh")
                case "$key" in
                    "filename") echo "文件名" ;;
                    "download_status") echo "下载状态" ;;
                    "transfer_status") echo "传输状态" ;;
                    "progress") echo "进度" ;;
                    "waiting_download") echo "等待下载" ;;
                    "downloading") echo "下载中" ;;
                    "download_complete") echo "下载完成" ;;
                    "download_failed") echo "下载失败" ;;
                    "waiting_transfer") echo "等待传输" ;;
                    "transferring") echo "传输中" ;;
                    "transfer_complete") echo "传输完成" ;;
                    "transfer_failed") echo "传输失败" ;;
                    "not_started") echo "未开始" ;;
                    "unknown") echo "未知" ;;
                    *) echo "$key" ;;
                esac
                ;;
            "en")
                case "$key" in
                    "filename") echo "Filename" ;;
                    "download_status") echo "Download" ;;
                    "transfer_status") echo "Transfer" ;;
                    "progress") echo "Progress" ;;
                    "waiting_download") echo "Waiting" ;;
                    "downloading") echo "Pulling" ;;
                    "download_complete") echo "Complete" ;;
                    "download_failed") echo "Failed" ;;
                    "waiting_transfer") echo "Queued" ;;
                    "transferring") echo "Pushing" ;;
                    "transfer_complete") echo "Stored" ;;
                    "transfer_failed") echo "Error" ;;
                    "not_started") echo "Pending" ;;
                    "unknown") echo "Unknown" ;;
                    *) echo "$key" ;;
                esac
                ;;
            *) echo "$key" ;;
        esac
    fi
}

# 检查API响应是否为有效JSON
check_api_response() {
    local response="$1"
    local operation="$2"
    
    # log_info "调试: $operation 原始响应: '$response'"
    # log_info "调试: 响应长度: ${#response} 字符"
    
    if [ -z "$response" ]; then
        log_error "$operation API响应为空"
        return 1
    fi
    
    if ! echo "$response" | jq . > /dev/null 2>&1; then
        log_error "$operation API响应不是有效JSON"
        log_error "原始响应内容: '$response'"
        log_error "响应的十六进制: $(echo "$response" | xxd -l 100)"
        return 1
    fi
    return 0
}



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
        log_info "调试: 请求releases列表 URL: https://api.github.com/repos/$GITHUB_REPOSITORY/releases"
        
        local releases_response=$(curl -s -H "Authorization: Bearer $github_token" \
            "https://api.github.com/repos/$GITHUB_REPOSITORY/releases?per_page=10")
        
        log_info "调试: releases API响应长度: ${#releases_response} 字符"
        
        # 检查API响应
        if ! echo "$releases_response" | jq . > /dev/null 2>&1; then
            log_error "releases API响应不是有效JSON: $releases_response"
            exit 1
        fi
        
        # 获取最新的release（按发布时间排序后取第一个）
        local latest_release=$(echo "$releases_response" | jq -r 'sort_by(.published_at) | reverse | .[0]')
        local latest_tag=$(echo "$latest_release" | jq -r '.tag_name')
        
        if [ "$latest_tag" = "null" ] || [ -z "$latest_tag" ]; then
            log_error "未找到有效的release"
            log_error "API响应: $releases_response"
            exit 1
        fi
        
        # 检查是否为prerelease
        local is_prerelease=$(echo "$latest_release" | jq -r '.prerelease')
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
    log_info "调试: 请求URL: https://api.github.com/repos/$GITHUB_REPOSITORY/releases/tags/$tag_name"
    local release_response=$(curl -s -H "Authorization: Bearer $github_token" \
        "https://api.github.com/repos/$GITHUB_REPOSITORY/releases/tags/$tag_name")
    
    log_info "调试: Release API响应长度: ${#release_response} 字符"
    
    # 检查API响应是否有效
    if ! echo "$release_response" | jq . > /dev/null 2>&1; then
        log_error "Release API响应不是有效JSON: $release_response"
        exit 1
    fi
    
    # 显示所有assets用于调试
    local all_assets=$(echo "$release_response" | jq -r '.assets[]?.name // empty')
    log_info "调试: 该release的所有文件:"
    echo "$all_assets" | while read -r asset; do
        if [ -n "$asset" ]; then
            echo "  📄 $asset" >&2
        fi
    done
    
    # 提取下载链接和文件信息，使用新的过滤系统
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

# 部署Alist
deploy_alist() {
    log_info "部署临时Alist服务..."
    
    # 创建临时目录
    mkdir -p /tmp/alist-data
    
    # 启动Alist容器
    docker run -d \
        --name=temp-alist \
        -p 5244:5244 \
        -v /tmp/alist-data:/opt/alist/data \
        xhofe/alist:v3.45.0 >/dev/null
    
    # 等待启动完成
    log_info "等待Alist启动..."
    for i in {1..30}; do
        if curl -s "$ALIST_URL/ping" > /dev/null 2>&1; then
            log_success "Alist服务启动成功"
            break
        fi
        log_info "等待服务启动... ($i/30)"
        sleep 3
        
        if [ $i -eq 30 ]; then
            log_error "Alist启动超时"
            docker logs temp-alist
            exit 1
        fi
    done
    
    # 设置固定管理员密码
    local admin_password="temp123456"
    log_info "设置管理员密码..."
    
    docker exec temp-alist ./alist admin set "$admin_password" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        log_error "设置管理员密码失败"
        exit 1
    fi
    
    log_success "管理员密码设置成功"
    echo "$admin_password"
}

# 获取Alist token
get_alist_token() {
    local admin_password="$1"
    
    log_info "获取管理员Token..."
    log_info "调试: 使用密码: $admin_password"
    log_info "调试: 尝试连接: $ALIST_URL/api/auth/login"
    
    # 先测试基本连通性
    local ping_result=$(curl -s -w "%{http_code}" -o /dev/null "$ALIST_URL/ping" || echo "000")
    log_info "调试: ping测试状态码: $ping_result"
    
    local response=$(curl -s -w "HTTP_CODE:%{http_code}" -X POST "$ALIST_URL/api/auth/login" \
        -H "Content-Type: application/json" \
        -d "{
            \"username\": \"admin\",
            \"password\": \"$admin_password\"
        }")
    
    # 分离HTTP状态码和响应体
    local http_code=$(echo "$response" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    local response_body=$(echo "$response" | sed 's/HTTP_CODE:[0-9]*$//')
    
    log_info "调试: HTTP状态码: $http_code"
    log_info "调试: 响应体: '$response_body'"
    
    if [ "$http_code" != "200" ]; then
        log_error "HTTP请求失败，状态码: $http_code"
        log_error "Alist可能未正确启动，检查容器状态："
        docker logs temp-alist --tail 20
        exit 1
    fi
    
    # 检查响应是否为有效JSON
    if ! check_api_response "$response_body" "登录"; then
        log_error "Alist可能未正确启动，检查容器状态："
        docker logs temp-alist --tail 20
        exit 1
    fi
    
    local token=$(echo "$response_body" | jq -r '.data.token // empty')
    
    if [ -n "$token" ] && [ "$token" != "null" ]; then
        log_success "Token获取成功"
        echo "$token"
    else
        log_error "Token获取失败: $response_body"
        local error_msg=$(echo "$response_body" | jq -r '.message // "未知错误"')
        log_error "错误信息: $error_msg"
        exit 1
    fi
}

# 挂载云盘存储（支持多种云盘）
mount_cloud_storage() {
    local alist_token="$1"
    
    log_info "挂载${CLOUD_PROVIDER}云盘..."
    log_info "调试: 使用token: ${alist_token:0:20}..."
    
    if [ -z "$CLOUD_AUTH" ]; then
        log_error "未找到云盘认证信息"
        exit 1
    fi
    
    # 根据云盘类型构建 addition JSON 字符串
    local addition_str
    case "$CLOUD_PROVIDER" in
        "quark")
            addition_str=$(jq -n --arg cookie "$CLOUD_AUTH" \
                '{cookie: $cookie, root_folder_id: "0", order_by: "file_name", order_direction: "asc"}' | jq -c .)
            ;;
        "mobile")
            addition_str=$(jq -n --arg auth "$CLOUD_AUTH" \
                '{authorization: $auth, root_folder_id: "/", type: "personal_new", cloud_id: "", custom_upload_part_size: 0, report_real_size: true, use_large_thumbnail: false}' | jq -c .)
            ;;
        *)
            log_error "不支持的云盘类型: $CLOUD_PROVIDER"
            exit 1
            ;;
    esac
    
    # 使用 jq 构建完整的请求 JSON
    local request_json=$(jq -n \
        --arg mount_path "$STORAGE_MOUNT_PATH" \
        --arg driver "$CLOUD_DRIVER" \
        --arg remark "SkorionOS Release同步 - ${CLOUD_PROVIDER}" \
        --arg addition "$addition_str" \
        '{mount_path: $mount_path, driver: $driver, order: 0, remark: $remark, addition: $addition}')
    
    local mount_response=$(curl -s -w "HTTP_CODE:%{http_code}" -X POST "$ALIST_URL/api/admin/storage/create" \
        -H "Authorization: $alist_token" \
        -H "Content-Type: application/json" \
        -d "$request_json")
    
    # 分离HTTP状态码和响应体
    local http_code=$(echo "$mount_response" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    local response_body=$(echo "$mount_response" | sed 's/HTTP_CODE:[0-9]*$//')
    
    log_info "调试: 挂载HTTP状态码: $http_code"
    
    if [ "$http_code" != "200" ]; then
        log_error "挂载HTTP请求失败，状态码: $http_code"
        log_error "响应内容: $response_body"
        exit 1
    fi
    
    # 检查响应是否为有效JSON
    if ! check_api_response "$response_body" "挂载${CLOUD_PROVIDER}"; then
        exit 1
    fi
    
    if echo "$response_body" | jq -e '.code == 200' > /dev/null; then
        local storage_id=$(echo "$response_body" | jq -r '.data.id')
        log_success "${CLOUD_PROVIDER}云盘挂载成功 (ID: $storage_id)"
        echo "$storage_id"
    else
        log_error "${CLOUD_PROVIDER}云盘挂载失败: $(echo "$response_body" | jq -r '.message // "未知错误"')"
        exit 1
    fi
}

# 配置Alist线程数
configure_alist_threads() {
    local alist_token="$1"
    local download_threads="$2"
    local transfer_threads="$3"
    
    if [ "$USE_BATCH_DOWNLOAD" != "true" ]; then
        log_info "单文件下载模式，跳过线程配置"
        return 0
    fi
    
    log_info "配置Alist线程数 (下载:$download_threads, 传输:$transfer_threads)..."
    
    # 获取当前配置
    local current_config=$(curl -s -X GET "$ALIST_URL/api/admin/setting/list" \
        -H "Authorization: $alist_token")
    
    if ! echo "$current_config" | jq -e '.code == 200' > /dev/null; then
        log_warning "无法获取当前配置，跳过线程设置"
        return 0
    fi
    
    # 保存原始配置
    local offline_threads=$(echo "$current_config" | jq -r '.data[] | select(.key == "offline_download_task_threads_num") | .value')
    local offline_type=$(echo "$current_config" | jq -r '.data[] | select(.key == "offline_download_task_threads_num") | .type')
    local offline_help=$(echo "$current_config" | jq -r '.data[] | select(.key == "offline_download_task_threads_num") | .help')
    local offline_group=$(echo "$current_config" | jq -r '.data[] | select(.key == "offline_download_task_threads_num") | .group')
    local offline_flag=$(echo "$current_config" | jq -r '.data[] | select(.key == "offline_download_task_threads_num") | .flag')
    
    local transfer_threads_orig=$(echo "$current_config" | jq -r '.data[] | select(.key == "offline_download_transfer_task_threads_num") | .value')
    local transfer_type=$(echo "$current_config" | jq -r '.data[] | select(.key == "offline_download_transfer_task_threads_num") | .type')
    local transfer_help=$(echo "$current_config" | jq -r '.data[] | select(.key == "offline_download_transfer_task_threads_num") | .help')
    local transfer_group=$(echo "$current_config" | jq -r '.data[] | select(.key == "offline_download_transfer_task_threads_num") | .group')
    local transfer_flag=$(echo "$current_config" | jq -r '.data[] | select(.key == "offline_download_transfer_task_threads_num") | .flag')
    
    # 保存原始配置供后续恢复使用
    echo "offline_threads=$offline_threads" > /tmp/alist_original_threads.env
    echo "offline_type=$offline_type" >> /tmp/alist_original_threads.env
    echo "offline_help=$offline_help" >> /tmp/alist_original_threads.env
    echo "offline_group=$offline_group" >> /tmp/alist_original_threads.env
    echo "offline_flag=$offline_flag" >> /tmp/alist_original_threads.env
    echo "transfer_threads_orig=$transfer_threads_orig" >> /tmp/alist_original_threads.env
    echo "transfer_type=$transfer_type" >> /tmp/alist_original_threads.env
    echo "transfer_help=$transfer_help" >> /tmp/alist_original_threads.env
    echo "transfer_group=$transfer_group" >> /tmp/alist_original_threads.env
    echo "transfer_flag=$transfer_flag" >> /tmp/alist_original_threads.env
    
    # 设置新的线程数
    local set_offline_response=$(curl -s -X POST "$ALIST_URL/api/admin/setting/save" \
        -H "Authorization: $alist_token" \
        -H "Content-Type: application/json" \
        -d "[{
            \"key\": \"offline_download_task_threads_num\", 
            \"value\": \"$download_threads\",
            \"type\": \"$offline_type\",
            \"help\": \"$offline_help\",
            \"group\": $offline_group,
            \"flag\": $offline_flag
        }]")
    
    local set_transfer_response=$(curl -s -X POST "$ALIST_URL/api/admin/setting/save" \
        -H "Authorization: $alist_token" \
        -H "Content-Type: application/json" \
        -d "[{
            \"key\": \"offline_download_transfer_task_threads_num\", 
            \"value\": \"$transfer_threads\",
            \"type\": \"$transfer_type\",
            \"help\": \"$transfer_help\",
            \"group\": $transfer_group,
            \"flag\": $transfer_flag
        }]")
    
    if echo "$set_offline_response" | jq -e '.code == 200' > /dev/null && \
       echo "$set_transfer_response" | jq -e '.code == 200' > /dev/null; then
        log_success "线程数配置成功 (下载:$download_threads, 传输:$transfer_threads)"
    else
        log_warning "线程数配置可能失败，但继续执行"
    fi
}

# 恢复原始线程数
restore_alist_threads() {
    local alist_token="$1"
    
    if [ "$USE_BATCH_DOWNLOAD" != "true" ] || [ ! -f "/tmp/alist_original_threads.env" ]; then
        return 0
    fi
    
    log_info "恢复原始线程配置..."
    
    # 加载原始配置
    source /tmp/alist_original_threads.env
    
    # 恢复原始线程数
    if [ -n "$offline_threads" ]; then
        curl -s -X POST "$ALIST_URL/api/admin/setting/save" \
            -H "Authorization: $alist_token" \
            -H "Content-Type: application/json" \
            -d "[{
                \"key\": \"offline_download_task_threads_num\", 
                \"value\": \"$offline_threads\",
                \"type\": \"$offline_type\",
                \"help\": \"$offline_help\",
                \"group\": $offline_group,
                \"flag\": $offline_flag
            }]" > /dev/null
    fi
    
    if [ -n "$transfer_threads_orig" ]; then
        curl -s -X POST "$ALIST_URL/api/admin/setting/save" \
            -H "Authorization: $alist_token" \
            -H "Content-Type: application/json" \
            -d "[{
                \"key\": \"offline_download_transfer_task_threads_num\", 
                \"value\": \"$transfer_threads_orig\",
                \"type\": \"$transfer_type\",
                \"help\": \"$transfer_help\",
                \"group\": $transfer_group,
                \"flag\": $transfer_flag
            }]" > /dev/null
    fi
    
    # 清理临时文件
    rm -f /tmp/alist_original_threads.env
    log_success "原始线程配置已恢复"
}

# 创建目标目录
create_target_directory() {
    local alist_token="$1"
    local tag_name="$2"
    
    local target_path="$STORAGE_MOUNT_PATH/$TARGET_FOLDER"
    
    log_info "创建目标目录: $target_path"
    
    local mkdir_response=$(curl -s -w "HTTP_CODE:%{http_code}" -X POST "$ALIST_URL/api/fs/mkdir" \
        -H "Authorization: $alist_token" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"$target_path\"}")
    
    # 分离HTTP状态码和响应体
    local http_code=$(echo "$mkdir_response" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    local response_body=$(echo "$mkdir_response" | sed 's/HTTP_CODE:[0-9]*$//')
    
    log_info "调试: 创建目录HTTP状态码: $http_code"
    log_info "调试: 创建目录响应: '$response_body'"
    
    if [ "$http_code" != "200" ]; then
        log_error "创建目录HTTP请求失败，状态码: $http_code"
        log_error "响应内容: $response_body"
        exit 1
    fi
    
    if ! check_api_response "$response_body" "创建目录"; then
        exit 1
    fi
    
    if echo "$response_body" | jq -e '.code == 200' > /dev/null || echo "$response_body" | jq -r '.message' | grep -q "already exists"; then
        log_success "目标目录准备完成"
        echo "$target_path"
    else
        log_error "目标目录创建失败: $(echo "$response_body" | jq -r '.message // "未知错误"')"
        exit 1
    fi
}

# 检查已存在文件
check_existing_files() {
    local alist_token="$1"
    local target_path="$2"
    local force_sync="$3"
    local download_list_file="$4"
    
    log_info "检查已存在的文件..."
    
    local list_response=$(curl -s -w "HTTP_CODE:%{http_code}" -X POST "$ALIST_URL/api/fs/list" \
        -H "Authorization: $alist_token" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"$target_path\"}")
    
    # 分离HTTP状态码和响应体
    local http_code=$(echo "$list_response" | grep -o "HTTP_CODE:[0-9]*" | cut -d: -f2)
    local response_body=$(echo "$list_response" | sed 's/HTTP_CODE:[0-9]*$//')
    
    # log_info "调试: 列出文件HTTP状态码: $http_code"
    # log_info "调试: 列出文件响应: '$response_body'"
    
    if [ "$http_code" != "200" ]; then
        log_error "列出文件HTTP请求失败，状态码: $http_code"
        log_error "响应内容: $response_body"
        exit 1
    fi
    
    if ! check_api_response "$response_body" "列出文件"; then
        exit 1
    fi
    
    if echo "$response_body" | jq -e '.code == 200' > /dev/null; then
        local existing_files=$(echo "$response_body" | jq -r '.data.content[]?.name // empty')
        local existing_count=$(echo "$existing_files" | wc -w)
        
        log_info "云盘中已存在 $existing_count 个文件"
        
        # 获取要同步的文件列表
        local sync_files=""
        if [ -f "$download_list_file" ]; then
            sync_files=$(awk -F'|' '{print $2}' "$download_list_file" | tr '\n' ' ')
        fi
        
        # 检查要同步的文件是否已存在
        local conflicted_files=""
        if [ -n "$sync_files" ] && [ "$existing_count" -gt 0 ]; then
            for sync_file in $sync_files; do
                if echo "$existing_files" | grep -q "^$sync_file$"; then
                    if [ -z "$conflicted_files" ]; then
                        conflicted_files="$sync_file"
                    else
                        conflicted_files="$conflicted_files $sync_file"
                    fi
                fi
            done
        fi
        
        local conflict_count=$(echo "$conflicted_files" | wc -w)
        local total_sync_files=$(echo "$sync_files" | wc -w)
        
        if [ "$conflict_count" -gt 0 ] && [ "$FORCE_SYNC" != "true" ]; then
            log_warning "检测到 $conflict_count 个文件已存在，将跳过这些文件"
            for file in $conflicted_files; do
                echo "  📄 $file"
            done
            
            # 如果所有文件都冲突，则完全跳过
            if [ "$conflict_count" -eq "$total_sync_files" ]; then
                echo "所有文件都已存在，如需重新同步，请启用 force_sync 参数"
                return 1
            fi
            
            # 从下载列表中移除冲突文件
            local temp_file="/tmp/download_list_filtered.txt"
            true > "$temp_file"
            while IFS='|' read -r url filename filesize; do
                local is_conflicted=false
                for conflicted_file in $conflicted_files; do
                    if [ "$filename" = "$conflicted_file" ]; then
                        is_conflicted=true
                        break
                    fi
                done
                if [ "$is_conflicted" = false ]; then
                    echo "$url|$filename|$filesize" >> "$temp_file"
                fi
            done < "$download_list_file"
            
            # 替换原文件
            mv "$temp_file" "$download_list_file"
            
            local remaining_count=$((total_sync_files - conflict_count))
            log_info "将继续同步剩余的 $remaining_count 个新文件"
        fi
        
        if [ "$FORCE_SYNC" = "true" ] && [ "$conflict_count" -gt 0 ]; then
            log_info "强制同步模式，清理冲突的文件..."
            for file in $conflicted_files; do
                if [ -n "$file" ]; then
                    echo "删除: $file"
                    curl -s -X POST "$ALIST_URL/api/fs/remove" \
                        -H "Authorization: $alist_token" \
                        -H "Content-Type: application/json" \
                        -d "{\"names\":[\"$target_path/$file\"]}" > /dev/null
                fi
            done
            log_success "已清理冲突文件"
        fi
        
        if [ "$conflict_count" -eq 0 ] && [ "$existing_count" -gt 0 ]; then
            log_info "云盘中的文件与当前同步任务无冲突，继续执行"
        fi
    fi
    
    return 0
}

# 监控下载任务
monitor_download_task() {
    local alist_token="$1"
    local filename="$2"
    
    local max_wait=$TIMEOUT_SECONDS
    local wait_time=0
    local download_completed=false
    
    while [ $wait_time -lt $max_wait ]; do
        # 检查未完成的任务
        local undone_tasks=$(curl -s -X GET "$ALIST_URL/api/admin/task/offline_download/undone" \
            -H "Authorization: $alist_token")
        
        # 检查已完成的任务  
        local done_tasks=$(curl -s -X GET "$ALIST_URL/api/admin/task/offline_download/done" \
            -H "Authorization: $alist_token")
        
        # 查找我们的任务
        local current_undone=$(echo "$undone_tasks" | jq -r --arg filename "$filename" \
            '.data[]? | select(.name | contains($filename)) | .state')
        
        if [ -n "$current_undone" ]; then
            local progress=$(echo "$undone_tasks" | jq -r --arg filename "$filename" \
                '.data[]? | select(.name | contains($filename)) | .progress // 0')
            # 格式化百分比为1位小数
            local formatted_progress=$(printf "%.1f" "$progress")
            
            if [ "$current_undone" = "0" ]; then
                log_progress "等待任务开始... (${formatted_progress}%)"
            elif [ "$current_undone" = "1" ]; then
                log_progress "正在下载到Alist... (${formatted_progress}%)"
            fi
        else
            # 检查是否在已完成列表中
            local current_done=$(echo "$done_tasks" | jq -r --arg filename "$filename" \
                '.data[]? | select(.name | contains($filename)) | .state')
            
            if [ -n "$current_done" ]; then
                if [ "$current_done" = "2" ]; then
                    # 只在第一次检测到下载完成时输出消息
                    if [ "$download_completed" = false ]; then
                        log_progress "下载到Alist完成，检查传输到云盘..."
                        download_completed=true
                    fi
                    
                    # 检查传输任务
                    local transfer_undone=$(curl -s -X GET "$ALIST_URL/api/admin/task/offline_download_transfer/undone" \
                        -H "Authorization: $alist_token")
                    local transfer_done=$(curl -s -X GET "$ALIST_URL/api/admin/task/offline_download_transfer/done" \
                        -H "Authorization: $alist_token")
                    
                    # 检查是否有进行中的传输任务
                    local transfer_active=$(echo "$transfer_undone" | jq -r --arg filename "$filename" \
                        '.data[]? | select(.name | contains($filename)) | .state')
                    
                    if [ -n "$transfer_active" ]; then
                        local transfer_progress=$(echo "$transfer_undone" | jq -r --arg filename "$filename" \
                            '.data[]? | select(.name | contains($filename)) | .progress // 0')
                        # 格式化百分比为1位小数
                        local formatted_progress=$(printf "%.1f" "$transfer_progress")
                        log_progress "正在传输到云盘... (${formatted_progress}%)"
                        # 继续等待传输完成
                    else
                        # 检查传输是否已完成
                        local transfer_completed=$(echo "$transfer_done" | jq -r --arg filename "$filename" \
                            '.data[]? | select(.name | contains($filename)) | .state')
                        
                        if [ -n "$transfer_completed" ]; then
                            if [ "$transfer_completed" = "2" ]; then
                                echo "success"
                                return 0
                            else
                                local transfer_error=$(echo "$transfer_done" | jq -r --arg filename "$filename" \
                                    '.data[]? | select(.name | contains($filename)) | .error // "传输失败"')
                                echo "failed:$transfer_error"
                                return 1
                            fi
                        else
                            # 可能传输任务还没有开始，继续等待
                            log_progress "等待传输任务开始..."
                        fi
                    fi
                elif [ "$current_done" = "7" ]; then
                    local error_msg=$(echo "$done_tasks" | jq -r --arg filename "$filename" \
                        '.data[]? | select(.name | contains($filename)) | .error // "未知错误"')
                    echo "failed:$error_msg"
                    return 1
                else
                    echo "unknown:$current_done"
                    return 1
                fi
            fi
        fi
        
        sleep $CHECK_INTERVAL
        wait_time=$((wait_time + CHECK_INTERVAL))
    done
    
    echo "timeout"
    return 1
}

# 上传文件到云盘
upload_files() {
    local alist_token="$1"
    local target_path="$2"
    local download_list_file="$3"
    
    log_info "开始上传文件到${CLOUD_PROVIDER}云盘..."
    
    local file_index=0
    local success_count=0
    local fail_count=0
    local total_files=$(cat "$download_list_file" | wc -l)
    
    while IFS='|' read -r download_url filename filesize; do
        if [ -z "$download_url" ]; then
            continue
        fi
        
        file_index=$((file_index + 1))
        local size_mb=$((filesize / 1024 / 1024))
        
        echo ""
        log_info "[$file_index/$total_files] 处理文件: $filename (${size_mb}MB)"
        
        # 检查runner剩余空间
        local available_space=$(df /tmp --output=avail | tail -1)
        local available_gb=$((available_space / 1024 / 1024))
        local file_gb=$((filesize / 1024 / 1024 / 1024 + 1))
        
        echo "💾 可用空间: ${available_gb}GB, 文件大小: ${file_gb}GB"
        
        if [ $available_gb -lt $((file_gb + 2)) ]; then
            log_warning "空间不足，跳过大文件: $filename"
            fail_count=$((fail_count + 1))
            continue
        fi
        
        # 添加离线下载任务
        log_info "提交离线下载任务到Alist..."
        local download_response=$(curl -s -X POST "$ALIST_URL/api/fs/add_offline_download" \
            -H "Authorization: $alist_token" \
            -H "Content-Type: application/json" \
            -d "{
                \"path\": \"$target_path\",
                \"urls\": [\"$download_url\"],
                \"tool\": \"SimpleHttp\",
                \"delete_policy\": \"delete_on_upload_succeed\"
            }")
        
        if echo "$download_response" | jq -e '.code == 200' > /dev/null; then
            log_success "离线下载任务已提交，开始传输到云盘"
        else
            log_error "下载任务提交失败: $(echo "$download_response" | jq -r '.message // "未知错误"')"
            fail_count=$((fail_count + 1))
            continue
        fi
        
        # 监控下载进度
        log_info "监控下载进度..."
        local result=$(monitor_download_task "$alist_token" "$filename")
        
        case "$result" in
            "success")
                log_success "[$file_index] $filename 下载成功！"
                success_count=$((success_count + 1))
                ;;
            "failed:"*)
                local error_msg="${result#failed:}"
                log_error "[$file_index] $filename 下载失败: $error_msg"
                fail_count=$((fail_count + 1))
                ;;
            "timeout")
                log_warning "[$file_index] $filename 下载超时"
                fail_count=$((fail_count + 1))
                ;;
            *)
                log_warning "[$file_index] $filename 下载未完成，最终状态: $result"
                fail_count=$((fail_count + 1))
                ;;
        esac
        
        # 短暂休息避免过载
        sleep 2
        
    done < "$download_list_file"
    
    echo ""
    log_info "上传完成统计:"
    echo "  ✅ 成功: $success_count"
    echo "  ❌ 失败: $fail_count"
    echo "  📁 总计: $total_files"
    echo "  🎯 过滤规则: $FILE_FILTER_RULES"
    
    # 返回成功文件数
    echo "$success_count"
}

# 批量上传文件到云盘（多线程）
upload_files_batch() {
    local alist_token="$1"
    local target_path="$2"
    local download_list_file="$3"
    
    log_info "开始批量上传文件到${CLOUD_PROVIDER}云盘（多线程模式）..."
    
    local total_files=$(cat "$download_list_file" | wc -l)
    if [ "$total_files" -eq 0 ]; then
        log_warning "没有文件需要上传"
        echo "0"
        return 0
    fi
    
    # 准备所有URL
    local urls=""
    local filenames=""
    local max_filename_len=8  # 最小文件名列宽
    
    while IFS='|' read -r download_url filename filesize; do
        if [ -n "$download_url" ]; then
            if [ -z "$urls" ]; then
                urls="\"$download_url\""
                filenames="$filename"
            else
                urls="$urls,\"$download_url\""
                filenames="$filenames $filename"
            fi
            
            # 计算最大文件名宽度
            local name_width=$(get_display_width "$filename")
            if [ $name_width -gt $max_filename_len ]; then
                max_filename_len=$name_width
            fi
        fi
    done < "$download_list_file"
    
    if [ -z "$urls" ]; then
        log_warning "没有有效的下载URL"
        echo "0"
        return 0
    fi
    
    log_info "提交 $total_files 个文件的批量下载任务..."
    
    # 提交批量离线下载任务
    local batch_response=$(curl -s -X POST "$ALIST_URL/api/fs/add_offline_download" \
        -H "Authorization: $alist_token" \
        -H "Content-Type: application/json" \
        -d "{
            \"path\": \"$target_path\",
            \"urls\": [$urls],
            \"tool\": \"SimpleHttp\",
            \"delete_policy\": \"delete_on_upload_succeed\"
        }")
    
    if ! echo "$batch_response" | jq -e '.code == 200' > /dev/null; then
        log_error "批量下载任务提交失败: $(echo "$batch_response" | jq -r '.message // "未知错误"')"
        echo "0"
        return 1
    fi
    
    log_success "批量下载任务已提交，开始监控进度..."
    
    # 动态表格监控
    local max_wait=1800  # 30分钟超时
    local wait_time=0
    local check_interval=3
    
    # 创建临时文件用于存储任务状态
    local undone_file="/tmp/undone_tasks.txt"
    local done_file="/tmp/done_tasks.txt"
    local transfer_undone_file="/tmp/transfer_undone.txt"
    local transfer_done_file="/tmp/transfer_done.txt"
    
    while [ $wait_time -lt $max_wait ]; do
        # 获取任务状态
        curl -s -X GET "$ALIST_URL/api/admin/task/offline_download/undone" \
            -H "Authorization: $alist_token" | \
            jq -r '.data[]? | select(.name | contains("'$target_path'")) | "\(.name)|\(.state)|\(.progress)"' > "$undone_file"
        
        curl -s -X GET "$ALIST_URL/api/admin/task/offline_download/done" \
            -H "Authorization: $alist_token" | \
            jq -r '.data[]? | select(.name | contains("'$target_path'")) | "\(.name)|\(.state)|\(.progress)"' > "$done_file"
        
        curl -s -X GET "$ALIST_URL/api/admin/task/offline_download_transfer/undone" \
            -H "Authorization: $alist_token" | \
            jq -r '.data[]? | "\(.name)|\(.state)|\(.progress)"' > "$transfer_undone_file"
        
        curl -s -X GET "$ALIST_URL/api/admin/task/offline_download_transfer/done" \
            -H "Authorization: $alist_token" | \
            jq -r '.data[]? | "\(.name)|\(.state)|\(.progress)"' > "$transfer_done_file"
        
        # 调试：显示传输任务信息
        # if [ -s "$transfer_done_file" ]; then
        #     echo "📋 调试：已完成的传输任务:" >&2
        #     cat "$transfer_done_file" >&2
        # fi
        # if [ -s "$transfer_undone_file" ]; then
        #     echo "📋 调试：进行中的传输任务:" >&2
        #     cat "$transfer_undone_file" >&2
        # fi
        
        # 显示表格
        echo "" >&2
        echo "📋 批量下载进度监控 [$(get_timestamp)]" >&2
        echo "" >&2
        
        # 重新计算当前循环中的最大文件名宽度
        local current_max_width=$(get_display_width "$(get_text "filename")")  # 表头宽度
        
        # 检查所有文件名的宽度
        for filename in $filenames; do
            if [ -n "$filename" ]; then
                local name_width=$(get_display_width "$filename")
                if [ $name_width -gt $current_max_width ]; then
                    current_max_width=$name_width
                fi
            fi
        done
        
        local filename_col_width=$((current_max_width + 4))
        
        # 计算状态列的实际宽度
        local download_status_width=$(get_display_width "$(get_text "download_status")")
        local transfer_status_width=$(get_display_width "$(get_text "transfer_status")")
        
        # 确保状态列至少能容纳状态文本
        local min_download_width=16
        local min_transfer_width=16
        if [ $download_status_width -gt $min_download_width ]; then
            min_download_width=$download_status_width
        fi
        if [ $transfer_status_width -gt $min_transfer_width ]; then
            min_transfer_width=$transfer_status_width
        fi
        
        printf "%s | %s | %s\n" \
            "$(pad_to_width "$(get_text "filename")" $filename_col_width)" \
            "$(pad_to_width "$(get_text "download_status")" $min_download_width)" \
            "$(pad_to_width "$(get_text "transfer_status")" $min_transfer_width)" >&2
        
        # 分隔线 - 使用实际列宽
        local sep_line=""
        for i in $(seq 1 $filename_col_width); do sep_line="${sep_line}-"; done
        sep_line="${sep_line}-|-"
        for i in $(seq 1 $min_download_width); do sep_line="${sep_line}-"; done
        sep_line="${sep_line}-|-"
        for i in $(seq 1 $min_transfer_width); do sep_line="${sep_line}-"; done
        echo "$sep_line" >&2
        
        # 调试：显示我们要匹配的文件名
        # echo "📋 调试：要匹配的文件名:" >&2
        # for f in $filenames; do
        #     echo "  - $f" >&2
        # done
        
        # 显示每个文件的状态
        local completed_count=0
        for filename in $filenames; do
            local download_status="$(get_text "waiting_download")"
            local transfer_status="$(get_text "waiting_transfer")"
            
            # 检查下载状态
            if grep -q "$filename" "$undone_file"; then
                local task_state=$(grep "$filename" "$undone_file" | cut -d'|' -f2)
                local task_progress=$(grep "$filename" "$undone_file" | cut -d'|' -f3)
                local formatted_progress=$(printf "%.1f" "${task_progress:-0}")
                
                if [ "$task_state" = "1" ]; then
                    download_status="$(get_text "downloading") ${formatted_progress}%"
                else
                    download_status="$(get_text "waiting_download")"
                fi
            elif grep -q "$filename" "$done_file"; then
                local task_state=$(grep "$filename" "$done_file" | cut -d'|' -f2)
                if [ "$task_state" = "2" ]; then
                    download_status="$(get_text "download_complete")"
                else
                    download_status="$(get_text "download_failed")"
                fi
            fi
            
            # 检查传输状态 - 使用更灵活的匹配
            local transfer_found=false
            if [ -s "$transfer_undone_file" ]; then
                local transfer_line=$(grep "/$filename" "$transfer_undone_file" | head -1)
                if [ -n "$transfer_line" ]; then
                    transfer_found=true
                    local transfer_state=$(echo "$transfer_line" | cut -d'|' -f2)
                    local transfer_progress=$(echo "$transfer_line" | cut -d'|' -f3)
                    local formatted_progress=$(printf "%.1f" "${transfer_progress:-0}")
                    
                    if [ "$transfer_state" = "1" ]; then
                        transfer_status="$(get_text "transferring") ${formatted_progress}%"
                    else
                        transfer_status="$(get_text "waiting_transfer")"
                    fi
                fi
            fi
            
            if [ "$transfer_found" = false ] && [ -s "$transfer_done_file" ]; then
                local transfer_line=$(grep "/$filename" "$transfer_done_file" | head -1)
                if [ -n "$transfer_line" ]; then
                    local transfer_state=$(echo "$transfer_line" | cut -d'|' -f2)
                    if [ "$transfer_state" = "2" ]; then
                        transfer_status="$(get_text "transfer_complete")"
                        completed_count=$((completed_count + 1))
                    else
                        transfer_status="$(get_text "transfer_failed")"
                    fi
                fi
            fi
            
            # 显示文件状态行
            printf "%s | %s | %s\n" \
                "$(pad_to_width "$filename" $filename_col_width)" \
                "$(pad_to_width "$download_status" $min_download_width)" \
                "$(pad_to_width "$transfer_status" $min_transfer_width)" >&2
        done
        
        echo "" >&2
        echo "📊 进度统计: $completed_count/$total_files 已完成" >&2
        
        # 检查是否全部完成
        if [ $completed_count -eq $total_files ]; then
            echo "" >&2
            log_success "所有文件批量下载完成！"
            break
        fi
        
        sleep $check_interval
        wait_time=$((wait_time + check_interval))
        
        # 清屏准备下次显示
        if [ $wait_time -lt $max_wait ]; then
            for i in $(seq 1 $((total_files + 8))); do echo -ne "\033[A\033[K" >&2; done
        fi
    done
    
    # 清理临时文件
    rm -f "$undone_file" "$done_file" "$transfer_undone_file" "$transfer_done_file"
    
    if [ $wait_time -ge $max_wait ]; then
        log_warning "批量下载监控超时"
        echo "$completed_count"
    else
        echo "$completed_count"
    fi
}

# 验证上传结果
verify_upload() {
    local alist_token="$1"
    local target_path="$2"
    local download_list_file="$3"
    
    log_info "验证本次上传的文件..."
    
    # 获取本次上传的文件列表
    local expected_files=""
    if [ -f "$download_list_file" ]; then
        expected_files=$(awk -F'|' '{print $2}' "$download_list_file")
    fi
    
    if [ -z "$expected_files" ]; then
        log_warning "没有需要验证的文件"
        echo "0"
        return 0
    fi
    
    local result=$(curl -s -X POST "$ALIST_URL/api/fs/list" \
        -H "Authorization: $alist_token" \
        -H "Content-Type: application/json" \
        -d "{\"path\": \"$target_path\"}")
    
    if echo "$result" | jq -e '.code == 200' > /dev/null; then
        local verified_count=0
        local failed_files=""
        
        log_success "目标目录: $target_path"
        
        # 使用for循环避免子shell问题
        for expected_file in $expected_files; do
            if [ -n "$expected_file" ]; then
                local file_exists=$(echo "$result" | jq -r --arg name "$expected_file" \
                    '.data.content[] | select(.name == $name) | .name // empty')
                
                if [ -n "$file_exists" ]; then
                    local file_info=$(echo "$result" | jq -r --arg name "$expected_file" \
                        '.data.content[] | select(.name == $name) | "大小: \(.size) bytes, 修改时间: \(.modified)"')
                    
                    # 检查是否是最近5分钟内的文件（说明是刚上传的）
                    local modified_time=$(echo "$result" | jq -r --arg name "$expected_file" \
                        '.data.content[] | select(.name == $name) | .modified')
                    local current_time=$(date -u +"%Y-%m-%dT%H:%M:%S")
                    
                    echo "  ✅ $expected_file - $file_info" >&2
                    verified_count=$((verified_count + 1))
                else
                    echo "  ❌ $expected_file - 文件未找到！" >&2
                    if [ -z "$failed_files" ]; then
                        failed_files="$expected_file"
                    else
                        failed_files="$failed_files $expected_file"
                    fi
                fi
            fi
        done
        
        local expected_count=$(echo "$expected_files" | wc -w)
        log_success "验证完成: $verified_count/$expected_count 个文件成功上传"
        
        if [ -n "$failed_files" ]; then
            log_error "以下文件上传失败:"
            for failed_file in $failed_files; do
                echo "  📄 $failed_file" >&2
            done
        fi
        
        echo "$verified_count"
    else
        log_error "无法获取上传结果: $(echo "$result" | jq -r '.message // "未知错误"')"
        echo "0"
    fi
}

# 清理资源
cleanup() {
    local alist_token="$1"
    local storage_id="$2"
    
    log_info "清理临时资源..."
    
    # 恢复原始线程配置
    restore_alist_threads "$alist_token"
    
    # 删除云盘存储
    if [ -n "$storage_id" ]; then
        log_info "删除临时存储(${CLOUD_PROVIDER})..."
        curl -s -X POST "$ALIST_URL/api/admin/storage/delete" \
            -H "Authorization: $alist_token" \
            -H "Content-Type: application/json" \
            -d "{\"id\": $storage_id}" > /dev/null || log_warning "存储删除失败"
    fi
    
    # 停止并删除容器
    docker stop temp-alist || true
    docker rm temp-alist || true
    
    # 清理临时文件（使用sudo处理权限问题）
    if [ -d "/tmp/alist-data" ]; then
        sudo rm -rf /tmp/alist-data || rm -rf /tmp/alist-data || log_warning "无法删除 /tmp/alist-data，可能需要手动清理"
    fi
    rm -f /tmp/download_list.txt || true
    rm -f /tmp/undone_tasks.txt /tmp/done_tasks.txt /tmp/transfer_undone.txt /tmp/transfer_done.txt || true
    
    log_success "清理完成"
}

# 主函数
main() {
    local tag_name="$1"
    
    # 使用环境变量中的GITHUB_TOKEN和CLOUD_AUTH
    local github_token="${GITHUB_TOKEN}"
    
    echo "🚀 SkorionOS ${CLOUD_PROVIDER}云盘同步开始"
    echo "================================================"
    log_info "云盘类型: ${CLOUD_PROVIDER}"
    log_info "挂载路径: ${STORAGE_MOUNT_PATH}"
    log_info "目标文件夹: ${TARGET_FOLDER}"
    
    # 显示下载模式
    if [ "$USE_BATCH_DOWNLOAD" = "true" ]; then
        log_info "使用多线程批量下载模式 (下载:${BATCH_DOWNLOAD_THREADS}线程, 传输:${BATCH_TRANSFER_THREADS}线程)"
    else
        log_info "使用单文件下载模式"
    fi
    
    # 获取release信息
    log_info "调试: 传入的tag_name参数: '$tag_name'"
    local release_tag=$(get_release_info "$tag_name" "$github_token")
    
    # 获取下载链接
    if ! get_download_urls "$release_tag" "$github_token" "/tmp/download_list.txt"; then
        log_warning "没有需要同步的文件，退出"
        return 0
    fi
    
    # 部署Alist
    local admin_password=$(deploy_alist)
    
    # 获取token
    local alist_token=$(get_alist_token "$admin_password")
    
    # 挂载云盘
    local storage_id=$(mount_cloud_storage "$alist_token")
    
    # 配置线程数（仅在批量模式下）
    configure_alist_threads "$alist_token" "$BATCH_DOWNLOAD_THREADS" "$BATCH_TRANSFER_THREADS"
    
    # 创建目标目录
    local target_path=$(create_target_directory "$alist_token" "$release_tag")
    
    # 检查已存在文件
    if ! check_existing_files "$alist_token" "$target_path" "$FORCE_SYNC" "/tmp/download_list.txt"; then
        cleanup "$alist_token" "$storage_id"
        log_warning "同步已跳过"
        return 0
    fi
    
    # 上传文件（根据配置选择模式）
    local success_count
    if [ "$USE_BATCH_DOWNLOAD" = "true" ]; then
        success_count=$(upload_files_batch "$alist_token" "$target_path" "/tmp/download_list.txt")
    else
        success_count=$(upload_files "$alist_token" "$target_path" "/tmp/download_list.txt")
    fi
    
    # 验证结果
    local final_count=$(verify_upload "$alist_token" "$target_path" "/tmp/download_list.txt")
    
    # 清理资源
    cleanup "$alist_token" "$storage_id"
    
    echo ""
    echo "================================================"
    log_success "SkorionOS $release_tag 同步完成！"
    log_success "📱 目标: ${CLOUD_PROVIDER}云盘 (${CLOUD_DRIVER})"
    log_success "📁 路径: $target_path"
    log_success "📊 成功文件数: $final_count"
    log_success "🎯 文件过滤: $FILE_FILTER_RULES"
    if [ "$USE_BATCH_DOWNLOAD" = "true" ]; then
        log_success "⚡ 下载模式: 多线程批量 (${BATCH_DOWNLOAD_THREADS}+${BATCH_TRANSFER_THREADS}线程)"
    else
        log_success "📝 下载模式: 单文件下载"
    fi
    echo "用户现在可以通过${CLOUD_PROVIDER}云盘快速下载了！"
}

# 检查必需参数
if [ $# -lt 1 ]; then
    echo "Usage: $0 <tag_name>"
    echo "  tag_name: Release标签 (留空使用最新)"
    echo ""
    echo "Required Environment Variables:"
    echo "  GITHUB_TOKEN: GitHub访问令牌"
    echo "  CLOUD_PROVIDER: 云盘类型 (mobile/quark)"
    echo "  CLOUD_AUTH: 云盘认证信息 (mobile用authorization, quark用cookie)"
    echo ""
    echo "Optional Environment Variables:"
    echo "  TARGET_FOLDER: 目标文件夹路径"
    echo "  USE_BATCH_DOWNLOAD: 批量下载模式 (true/false)"
    echo "  BATCH_DOWNLOAD_THREADS: 下载线程数"
    echo "  BATCH_TRANSFER_THREADS: 传输线程数"
    echo "  TABLE_LANGUAGE: 表格语言 (zh/en)"
    echo "  USE_EMOJI: 显示Emoji (true/false)"
    echo "  FORCE_SYNC: 强制同步 (true/false)"
    exit 1
fi

# 执行主函数
main "$1"
