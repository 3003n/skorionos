#!/bin/bash
# find-delta-bases.sh - 查找增量生成的基础版本
#
# 通过 GitHub Releases API 获取历史版本列表（按 created_at 排序），
# 为每个桌面分支找到最近 N 个包含该分支镜像的历史 release，
# 输出 {base_tag, branch} 的 matrix 组合供并行增量生成使用。
#
# 通道隔离规则:
#   - UNSTABLE 通道: release name 包含 [UNSTABLE]，只在 UNSTABLE 之间做增量
#   - 稳定/测试通道: release name 不含 [UNSTABLE]，两者之间可互相做增量
#
# 环境变量:
#   GITHUB_TOKEN   - GitHub API token (必需)
#   TARGET_TAG     - 当前要生成增量的 release tag (必需)
#   REPO           - GitHub 仓库，格式 owner/repo (默认: GITHUB_REPOSITORY)
#   DELTA_DEPTH    - 向前查找的版本深度 (默认: 1)

set -euo pipefail

REPO="${REPO:-${GITHUB_REPOSITORY:-SkorionOS/skorionos}}"
TARGET_TAG="${TARGET_TAG:?TARGET_TAG is required}"
DELTA_DEPTH="${DELTA_DEPTH:-1}"
API_BASE="https://api.github.com"

auth_header=()
if [ -n "${GITHUB_TOKEN:-}" ]; then
    auth_header=(-H "Authorization: token $GITHUB_TOKEN")
fi

echo "Finding delta bases for $TARGET_TAG (depth=$DELTA_DEPTH) in $REPO" >&2

# 获取 releases 并按 created_at 降序排列（API 返回顺序不可靠，必须显式排序）
releases=$(curl -s "${auth_header[@]}" \
    "${API_BASE}/repos/${REPO}/releases?per_page=50" \
    | jq 'sort_by(.created_at) | reverse')

if [ -z "$releases" ] || [ "$releases" = "null" ]; then
    echo "Failed to fetch releases" >&2
    echo "matrix=[]" >> "$GITHUB_OUTPUT"
    echo "has_bases=false" >> "$GITHUB_OUTPUT"
    exit 0
fi

# 获取目标 release 以确定可用的桌面分支和通道
target_release=$(echo "$releases" | jq --arg tag "$TARGET_TAG" \
    '.[] | select(.tag_name == $tag)')

if [ -z "$target_release" ] || [ "$target_release" = "null" ]; then
    echo "Target release $TARGET_TAG not found" >&2
    echo "matrix=[]" >> "$GITHUB_OUTPUT"
    echo "has_bases=false" >> "$GITHUB_OUTPUT"
    exit 0
fi

# 判断目标版本所属通道: UNSTABLE 或 稳定/测试
target_name=$(echo "$target_release" | jq -r '.name // ""')
target_is_unstable=false
if echo "$target_name" | grep -qi '\[UNSTABLE\]'; then
    target_is_unstable=true
fi
echo "Target channel: $([ "$target_is_unstable" = true ] && echo "UNSTABLE" || echo "stable/testing")" >&2

# 从 tag 中提取主版本号 (如 55-1_abc -> 55)，用于防止向更大版本号查找
target_major=$(echo "$TARGET_TAG" | grep -oP '^\d+' || true)
echo "Target major version: ${target_major:-unknown}" >&2

# 从资产文件名中提取桌面分支名 (如 skorionos-55-1_abc-gnome.skosys -> gnome)
target_branches=$(echo "$target_release" | jq -r \
    '[.assets[].name | select(test("^skorionos-.*\\.(skosys|part1-[0-9]+\\.skosys)$")) |
     capture("^skorionos-[0-9]+-?[0-9]*_[a-f0-9]+-(?<branch>[a-zA-Z][-a-zA-Z0-9]*)\\.")
     | .branch] | unique | .[]')

if [ -z "$target_branches" ]; then
    echo "No branches found in target release assets" >&2
    echo "matrix=[]" >> "$GITHUB_OUTPUT"
    echo "has_bases=false" >> "$GITHUB_OUTPUT"
    exit 0
fi

echo "Target branches: $(echo "$target_branches" | tr '\n' ' ')" >&2

# 为每个桌面分支查找包含对应镜像的历史 release 作为增量基础版本
matrix_entries=()

for branch in $target_branches; do
    found=0

    # 遍历 releases（已按时间降序排列，跳过目标版本自身）
    while IFS= read -r rel; do
        tag=$(echo "$rel" | jq -r '.tag_name')
        [ "$tag" = "$TARGET_TAG" ] && continue

        # 通道隔离: 检查候选 release 是否与目标同通道
        rel_name=$(echo "$rel" | jq -r '.name // ""')
        rel_is_unstable=false
        if echo "$rel_name" | grep -qi '\[UNSTABLE\]'; then
            rel_is_unstable=true
        fi

        if [ "$target_is_unstable" != "$rel_is_unstable" ]; then
            continue
        fi

        # 版本号方向检查: 只查找主版本号 <= 目标的 release
        if [ -n "$target_major" ]; then
            rel_major=$(echo "$tag" | grep -oP '^\d+' || true)
            if [ -n "$rel_major" ] && [ "$rel_major" -gt "$target_major" ]; then
                continue
            fi
        fi

        # 检查该 release 是否包含此分支的 .skosys 镜像
        has_branch=$(echo "$rel" | jq -r --arg b "$branch" \
            '[.assets[].name | select(test("^skorionos-.*-" + $b + "\\.(skosys|part1-[0-9]+\\.skosys)$"))] | length')

        if [ "$has_branch" -gt 0 ]; then
            found=$((found + 1))
            echo "  Found base: $tag (branch=$branch)" >&2
            matrix_entries+=("{\"base_tag\":\"$tag\",\"branch\":\"$branch\"}")

            [ "$found" -ge "$DELTA_DEPTH" ] && break
        fi
    done < <(echo "$releases" | jq -c '.[]')
done

if [ ${#matrix_entries[@]} -eq 0 ]; then
    echo "No base versions found for delta generation" >&2
    echo "matrix=[]" >> "$GITHUB_OUTPUT"
    echo "has_bases=false" >> "$GITHUB_OUTPUT"
    exit 0
fi

# 构建 GitHub Actions matrix JSON
matrix_json=$(printf '%s\n' "${matrix_entries[@]}" | jq -s -c '.')
echo "Matrix: $matrix_json" >&2
echo "matrix=$matrix_json" >> "$GITHUB_OUTPUT"
echo "has_bases=true" >> "$GITHUB_OUTPUT"
