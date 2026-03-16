#!/bin/bash
# detect-delta-branches.sh - 检测两个 release 之间共有的桌面分支
#
# 供手动增量工作流使用。自动从目标和基础 release 的资产文件名中
# 提取桌面分支名，取交集作为需要生成增量包的分支列表。
# 也支持通过 MANUAL_BRANCHES 手动指定，跳过自动检测。
#
# 环境变量:
#   GH_TOKEN        - GitHub API token (必需)
#   REPO            - GitHub 仓库 (默认: GITHUB_REPOSITORY)
#   TARGET_TAG      - 目标版本 tag (必需)
#   BASE_TAG        - 基础版本 tag (必需)
#   MANUAL_BRANCHES - 逗号分隔的分支列表 (可选，指定后跳过自动检测)
#
# 输出: 向 GITHUB_OUTPUT 写入 matrix 和 has_branches

set -euo pipefail

REPO="${REPO:-${GITHUB_REPOSITORY}}"
TARGET_TAG="${TARGET_TAG:?TARGET_TAG is required}"
BASE_TAG="${BASE_TAG:?BASE_TAG is required}"
MANUAL_BRANCHES="${MANUAL_BRANCHES:-}"

# 手动指定分支时直接构建 matrix
if [ -n "$MANUAL_BRANCHES" ]; then
    matrix=$(echo "$MANUAL_BRANCHES" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | \
        jq -R -s -c --arg bt "$BASE_TAG" \
        'split("\n") | map(select(length > 0)) | map({branch: ., base_tag: $bt})')
    echo "matrix=$matrix" >> "$GITHUB_OUTPUT"
    echo "has_branches=true" >> "$GITHUB_OUTPUT"
    exit 0
fi

# 从 release 资产文件名中提取桌面分支名
# 如 skorionos-55-1_abc-gnome.skosys -> gnome
extract_branches() {
    local tag="$1"
    gh api "repos/${REPO}/releases/tags/${tag}" --jq \
        '[.assets[].name | select(test("^skorionos-.*\\.(skosys|part1-[0-9]+\\.skosys)$")) |
         capture("^skorionos-[0-9]+-?[0-9]*_[a-f0-9]+-(?<branch>[a-zA-Z][-a-zA-Z0-9]*)\\.")
         | .branch] | unique | .[]'
}

target_branches=$(extract_branches "$TARGET_TAG")
base_branches=$(extract_branches "$BASE_TAG")

if [ -z "$target_branches" ] || [ -z "$base_branches" ]; then
    echo "No branches found in one of the releases" >&2
    echo "matrix=[]" >> "$GITHUB_OUTPUT"
    echo "has_branches=false" >> "$GITHUB_OUTPUT"
    exit 0
fi

# 取两个 release 共有的分支
shared=$(comm -12 \
    <(echo "$target_branches" | sort) \
    <(echo "$base_branches" | sort))

if [ -z "$shared" ]; then
    echo "No shared branches between releases" >&2
    echo "matrix=[]" >> "$GITHUB_OUTPUT"
    echo "has_branches=false" >> "$GITHUB_OUTPUT"
    exit 0
fi

matrix=$(echo "$shared" | jq -R -c --arg bt "$BASE_TAG" '{branch: ., base_tag: $bt}' | jq -s -c '.')
echo "Matrix: $matrix" >&2
echo "matrix=$matrix" >> "$GITHUB_OUTPUT"
echo "has_branches=true" >> "$GITHUB_OUTPUT"
