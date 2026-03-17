#!/bin/bash
# publish-delta.sh - 收集增量产物，合并清单，分包大文件
#
# 处理 generate-delta matrix job 产生的增量产物:
#   1. 按桌面分支收集成功的 delta 条目
#   2. 与 release 中已有的 manifest 合并（保证幂等性）
#   3. 对超过大小限制的 .skdelta 文件进行分包
#   4. 在 manifest 中记录分包校验和
#
# 环境变量:
#   GH_TOKEN       - GitHub API token (必需)
#   REPO           - GitHub 仓库，格式 owner/repo (默认: GITHUB_REPOSITORY)
#   TARGET_TAG     - 要发布增量包的 Release tag (必需)
#   DELTAS_DIR     - 下载的增量产物目录 (必需)
#   OUTPUT_DIR     - 最终输出目录 (必需)
#   SPLIT_SIZE_GIB - 单文件大小上限，单位 GiB (默认: 1.9)
#
# 输出: 在 GITHUB_ENV 中设置 has_deltas=true/false

set -euo pipefail

REPO="${REPO:-${GITHUB_REPOSITORY}}"
TARGET_TAG="${TARGET_TAG:?TARGET_TAG is required}"
DELTAS_DIR="${DELTAS_DIR:?DELTAS_DIR is required}"
OUTPUT_DIR="${OUTPUT_DIR:?OUTPUT_DIR is required}"
SPLIT_SIZE_GIB="${SPLIT_SIZE_GIB:-1.9}"

mkdir -p "$OUTPUT_DIR"

# ── 按桌面分支收集成功的 delta 条目 ──

declare -A branch_entries
has_entries=false

echo "=== Debug: DELTAS_DIR contents ==="
ls -R "${DELTAS_DIR}" 2>&1 || echo "(empty or not found)"
echo "=== Debug: searching for delta-status.txt ==="
find "${DELTAS_DIR}" -name "delta-status.txt" -exec echo "Found: {}" \; -exec cat {} \; 2>&1 || true
echo "=== End debug ==="

for status_file in "${DELTAS_DIR}"/*/delta-status.txt; do
    [ -f "$status_file" ] || continue
    dir=$(dirname "$status_file")
    status=$(cat "$status_file")
    echo "Debug: status_file=$status_file status=[$status]"
    [ "$status" != "OK" ] && continue

    entry_file="${dir}/delta-entry.json"
    [ -f "$entry_file" ] || continue

    cp "${dir}"/*.skdelta "$OUTPUT_DIR/" 2>/dev/null || true

    # 从文件名中解析桌面分支 (如 skorionos-55_abc-gnome.from_54.skdelta -> gnome)
    branch=$(jq -r '.filename' "$entry_file" \
        | sed -n 's/.*_[a-f0-9]\+-\([a-zA-Z][-a-zA-Z0-9]*\)\.from_.*/\1/p')
    if [ -z "$branch" ]; then
        echo "Warning: cannot parse branch from $(cat "$entry_file")" >&2
        continue
    fi

    branch_entries[$branch]="${branch_entries[$branch]:-}$(cat "$entry_file"),"
    has_entries=true
done

if [ "$has_entries" = false ]; then
    echo "No successful deltas to publish"
    echo "has_deltas=false" >> "$GITHUB_ENV"
    exit 0
fi

# ── 与 release 中已有的 manifest 合并（保证幂等，新条目覆盖相同 from_version 的旧条目） ──

for branch in "${!branch_entries[@]}"; do
    manifest_name="delta-manifest-${branch}.json"

    # 尝试下载 release 中已有的 manifest
    existing_deltas="[]"
    if gh release download "$TARGET_TAG" -R "$REPO" -p "$manifest_name" -D /tmp/ 2>/dev/null; then
        existing_deltas=$(jq -c '.deltas // []' "/tmp/$manifest_name" 2>/dev/null || echo "[]")
        rm -f "/tmp/$manifest_name"
    fi

    new_entries="[${branch_entries[$branch]%,}]"

    # 以 from_version 为键合并，新条目优先
    merged_deltas=$(jq -n \
        --argjson existing "$existing_deltas" \
        --argjson new_entries "$new_entries" \
        '($existing | map({(.from_version): .}) | add // {}) *
         ($new_entries | map({(.from_version): .}) | add // {})
         | to_entries | map(.value)')

    jq -n \
        --arg version "$TARGET_TAG" \
        --arg branch "$branch" \
        --argjson deltas "$merged_deltas" \
        '{version: $version, branch: $branch, deltas: $deltas}' \
        > "${OUTPUT_DIR}/${manifest_name}"

    echo "Generated $manifest_name with $(echo "$merged_deltas" | jq length) delta(s)"
done

# ── 对超过 GitHub 单文件限制的 .skdelta 进行分包 ──

SPLIT_SIZE_MIB=$(awk "BEGIN {printf \"%d\", ${SPLIT_SIZE_GIB} * 1024}")
SPLIT_BYTES=$((SPLIT_SIZE_MIB * 1024 * 1024))

for delta_file in "${OUTPUT_DIR}"/*.skdelta; do
    [ -f "$delta_file" ] || continue
    # 跳过已经是分包的文件
    basename "$delta_file" | grep -qE '\.part[0-9]+-[0-9]+\.skdelta$' && continue

    FILE_SIZE=$(stat -c %s "$delta_file")
    [ "$FILE_SIZE" -le "$SPLIT_BYTES" ] && continue

    delta_base="${delta_file%.skdelta}"
    total_parts=$(((FILE_SIZE + SPLIT_BYTES - 1) / SPLIT_BYTES))
    echo "Splitting $(basename "$delta_file") into $total_parts parts"
    split -b "${SPLIT_SIZE_MIB}MiB" -d -a 3 "$delta_file" "${delta_base}.part"
    # 重命名为 .part1-N.skdelta 格式
    for i in $(seq 1 "$total_parts"); do
        part_num=$(printf "%03d" $((i - 1)))
        mv "${delta_base}.part${part_num}" "${delta_base}.part${i}-${total_parts}.skdelta"
    done

    # 计算每个分包的校验和，写入 manifest
    original_name=$(basename "$delta_file")
    part_checksums="["
    for i in $(seq 1 "$total_parts"); do
        pf="${delta_base}.part${i}-${total_parts}.skdelta"
        cs=$(sha256sum "$pf" | awk '{print $1}')
        [ "$i" -gt 1 ] && part_checksums="${part_checksums},"
        part_checksums="${part_checksums}\"sha256:${cs}\""
    done
    part_checksums="${part_checksums}]"

    # 更新对应的 manifest 条目，加入 parts 和 part_checksums 字段
    for mf in "${OUTPUT_DIR}"/delta-manifest-*.json; do
        [ -f "$mf" ] || continue
        jq --arg fn "$original_name" \
           --argjson parts "$total_parts" \
           --argjson pcs "$part_checksums" \
           '(.deltas[] | select(.filename == $fn)) += {parts: $parts, part_checksums: $pcs}' \
           "$mf" > "${mf}.tmp" && mv "${mf}.tmp" "$mf"
    done

    rm "$delta_file"
done

echo "has_deltas=true" >> "$GITHUB_ENV"
echo "=== Output files ==="
ls -lh "${OUTPUT_DIR}/"
