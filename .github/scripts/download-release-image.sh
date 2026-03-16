#!/bin/bash
# download-release-image.sh - 从 GitHub Release 下载 .skosys 系统镜像
#
# 支持单文件和分包两种格式。如果是分包镜像，会自动下载所有分包并合并。
#
# 环境变量:
#   GH_TOKEN  - GitHub API token (必需，供 gh CLI 使用)
#   REPO      - GitHub 仓库，格式 owner/repo (默认: GITHUB_REPOSITORY)
#
# 参数:
#   $1 - Release tag
#   $2 - 桌面分支名 (如 gnome, kde)
#   $3 - 下载目标目录
#
# 输出: 将最终 .skosys 文件路径打印到 stdout

set -euo pipefail

TAG="${1:?Usage: $0 TAG BRANCH DEST_DIR}"
BRANCH="${2:?Usage: $0 TAG BRANCH DEST_DIR}"
DEST_DIR="${3:?Usage: $0 TAG BRANCH DEST_DIR}"
REPO="${REPO:-${GITHUB_REPOSITORY}}"

mkdir -p "$DEST_DIR"

# 获取 release 中的所有资产文件名
assets=$(gh api "repos/${REPO}/releases/tags/${TAG}" --jq '.assets[].name')

# 优先尝试单文件镜像
filename=$(echo "$assets" | grep -E "^skorionos-.*-${BRANCH}\\.skosys$" | head -1 || true)
if [ -n "$filename" ]; then
    gh release download "$TAG" -R "$REPO" -p "$filename" -D "$DEST_DIR"
    echo "${DEST_DIR}/${filename}"
    exit 0
fi

# 尝试分包镜像 (part1-N.skosys, part2-N.skosys, ...)
part_files=$(echo "$assets" | grep -E "^skorionos-.*-${BRANCH}\\.part[0-9]+-[0-9]+\\.skosys$" || true)
if [ -z "$part_files" ]; then
    echo "No image found for tag=$TAG branch=$BRANCH" >&2
    exit 1
fi

# 下载所有分包
while IFS= read -r pf; do
    [ -z "$pf" ] && continue
    gh release download "$TAG" -R "$REPO" -p "$pf" -D "$DEST_DIR"
done <<< "$part_files"

# 按序合并分包为完整文件
base_name=$(echo "$part_files" | head -1 | sed 's/\.part[0-9]*-[0-9]*\.skosys$//')
merged="${DEST_DIR}/${base_name}.skosys"
total_parts=$(echo "$part_files" | wc -l)

: > "$merged"
for i in $(seq 1 "$total_parts"); do
    cat "${DEST_DIR}/${base_name}.part${i}-${total_parts}.skosys" >> "$merged"
done
rm -f "${DEST_DIR}/${base_name}".part*.skosys
echo "$merged"
