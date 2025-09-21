# Alist 下载器模块化重构

## 概述

原始的 `mobile-cloud-sync.sh` 脚本已经重构为模块化架构，提高了代码的可维护性和复用性。

## 文件结构

```
.github/scripts/
├── mobile-cloud-sync.sh           # 原始脚本（保留作为参考）
├── mobile-cloud-sync-v2.sh        # 新的模块化主脚本
├── alist-downloader.sh             # 通用 Alist 下载器模块
├── alist-utils.sh                  # 工具函数库
└── README-modules.md               # 本文档
```

## 模块说明

### 1. `alist-downloader.sh` - 核心下载模块

**功能：** 通用的 Alist 云盘下载器，可用于任何云盘类型的离线下载

**特性：**
- 支持多种云盘类型（不限于移动云盘）
- 批量/单文件两种下载模式
- 实时进度监控和表格显示
- 自动线程配置和恢复
- 文件冲突检测和处理

**使用方式：**
```bash
./alist-downloader.sh <storage_config_json> <target_path> <download_list_file> [options_json]
```

**参数示例：**
```bash
# 存储配置
storage_config='{"mount_path":"/移动云盘","driver":"139Yun","addition":"{\"authorization\":\"xxx\"}"}'

# 选项配置
options='{"batch_mode":true,"download_threads":3,"language":"zh","use_emoji":true}'

# 执行下载
./alist-downloader.sh "$storage_config" "/移动云盘/files" "download_list.txt" "$options"
```

### 2. `alist-utils.sh` - 工具函数库

**功能：** 提供日志、界面显示、API 响应检查等通用工具函数

**包含函数：**
- 日志函数：`log_info`, `log_success`, `log_warning`, `log_error`, `log_progress`
- 界面函数：`get_display_width`, `pad_to_width`, `get_text`
- API函数：`check_api_response`

### 3. `mobile-cloud-sync-v2.sh` - 模块化主脚本

**功能：** SkorionOS 特定的同步逻辑，负责 GitHub Release 获取和调用下载模块

**特性：**
- 保持与原脚本相同的接口和配置方式
- GitHub Release 获取和文件过滤
- 调用 `alist-downloader.sh` 执行下载
- SkorionOS 特定的配置和路径

## 使用方式

### 替换原脚本（兼容方式）

可以直接用 `mobile-cloud-sync-v2.sh` 替换原脚本：

```bash
# 原来的调用方式
./mobile-cloud-sync.sh "$TAG_NAME" "$GITHUB_TOKEN" "$MOBILE_CLOUD_AUTHORIZATION"

# 新的调用方式（参数完全相同）
./mobile-cloud-sync-v2.sh "$TAG_NAME" "$GITHUB_TOKEN" "$MOBILE_CLOUD_AUTHORIZATION"
```

### 环境变量配置

所有配置都通过环境变量传递：

```bash
export USE_BATCH_DOWNLOAD=true
export BATCH_DOWNLOAD_THREADS=3
export BATCH_TRANSFER_THREADS=3
export TABLE_LANGUAGE=zh
export USE_EMOJI=true
export FORCE_SYNC=false

./mobile-cloud-sync-v2.sh "" "$GITHUB_TOKEN" "$MOBILE_CLOUD_AUTHORIZATION"
```

### 独立使用 Alist 下载器

`alist-downloader.sh` 可以独立使用于其他项目：

```bash
# 准备存储配置
storage_config='{
    "mount_path": "/OneDrive",
    "driver": "OneDriveE5",
    "addition": "{\"client_id\":\"xxx\",\"client_secret\":\"xxx\"}"
}'

# 准备下载列表 (格式: URL|filename|size)
echo "https://example.com/file1.zip|file1.zip|1048576" > files.txt
echo "https://example.com/file2.zip|file2.zip|2097152" >> files.txt

# 执行下载
./alist-downloader.sh "$storage_config" "/OneDrive/downloads" "files.txt"
```

## 优势

### 对比原脚本的改进

1. **模块化设计**：功能清晰分离，易于维护和测试
2. **通用性强**：Alist 模块可用于其他项目和云盘
3. **可扩展性**：容易添加新的云盘类型和功能
4. **接口标准化**：使用 JSON 配置，便于集成

### GitHub Actions 集成潜力

`alist-downloader.sh` 可以轻松包装为 Composite Action：

```yaml
# .github/actions/alist-cloud-downloader/action.yml
name: 'Alist Cloud Downloader'
description: 'Download files to cloud storage using Alist'
inputs:
  storage-config:
    description: 'Storage configuration JSON'
    required: true
  target-path:
    description: 'Target path in cloud storage'
    required: true
  download-list:
    description: 'Download list file path'
    required: true
runs:
  using: 'composite'
  steps:
    - name: Run Alist Downloader
      shell: bash
      run: |
        ${{ github.action_path }}/scripts/alist-downloader.sh \
          "${{ inputs.storage-config }}" \
          "${{ inputs.target-path }}" \
          "${{ inputs.download-list }}"
```

## 向后兼容

- 原始脚本 `mobile-cloud-sync.sh` 保持不变
- 新脚本 `mobile-cloud-sync-v2.sh` 提供相同的接口
- 环境变量配置方式完全兼容
- 可以逐步迁移，无风险

## 测试状态

✅ 语法检查通过  
✅ 参数验证正常  
✅ 工具函数导入正常  
✅ 模块间调用正常  

## 下一步

1. **测试完整功能**：使用真实的云盘认证信息测试完整流程
2. **创建 Action**：将 alist-downloader 包装为 GitHub Action
3. **文档完善**：添加更多使用示例和最佳实践
4. **社区发布**：考虑发布到 GitHub Marketplace
