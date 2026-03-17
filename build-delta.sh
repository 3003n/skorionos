#!/bin/bash
# build-delta.sh - 在两个 SkorionOS 版本之间生成增量更新包
# 供自动和手动增量工作流共用
#
# 输入:  两个 .skosys 文件 (btrfs send 流经 xz 压缩)
# 输出:  .skdelta 文件 (tar 差异包经 xz 压缩)、manifest 片段、sha256sum

set -euo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Required:
  --target-img PATH    Target (new) version .skosys file path
  --base-img PATH      Base (old) version .skosys file path
  --output-dir DIR     Output directory for delta files

Optional:
  --target-name NAME   Target subvolume name (auto-derived from filename)
  --base-name NAME     Base subvolume name (auto-derived from filename)
  --base-tag TAG       Base version release tag (auto-derived from version)
  --max-ratio PCT      Max delta/full size ratio percentage (default: 70)
  --work-size SIZE     Temp btrfs image size (default: auto-calculated)
EOF
    exit 1
}

# 从子卷名中提取版本号
# 例: skorionos-50-4_5d150d2-gnome-nv -> 50-4_5d150d2
#     chimeraos-46_abc1234-gnome-core  -> 46_abc1234
# 正则: 匹配 "前缀-主版本号(-次版本号)?_commit哈希-后缀"，提取中间版本部分
extract_version() {
    echo "$1" | sed -n 's/\(chimeraos\|skorionos\)-\([0-9]\+\(-[0-9]\+\)\?_[a-f0-9]\+\)-.*/\2/p'
}

TARGET_IMG=""
BASE_IMG=""
TARGET_NAME=""
BASE_NAME=""
BASE_TAG=""
MAX_RATIO=70
OUTPUT_DIR=""
WORK_SIZE=""
WORK_SIZE_SET=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target-img)  TARGET_IMG="$2";  shift 2 ;;
        --base-img)    BASE_IMG="$2";    shift 2 ;;
        --target-name) TARGET_NAME="$2"; shift 2 ;;
        --base-name)   BASE_NAME="$2";   shift 2 ;;
        --base-tag)    BASE_TAG="$2";    shift 2 ;;
        --max-ratio)   MAX_RATIO="$2";   shift 2 ;;
        --output-dir)  OUTPUT_DIR="$2";  shift 2 ;;
        --work-size)   WORK_SIZE="$2"; WORK_SIZE_SET=true; shift 2 ;;
        -h|--help)     usage ;;
        *) echo "Unknown option: $1" >&2; usage ;;
    esac
done

if [ -z "$TARGET_IMG" ] || [ -z "$BASE_IMG" ] || [ -z "$OUTPUT_DIR" ]; then
    echo "Error: --target-img, --base-img, and --output-dir are required" >&2
    usage
fi

if [ ! -f "$TARGET_IMG" ]; then
    echo "Error: target image not found: $TARGET_IMG" >&2
    exit 1
fi
if [ ! -f "$BASE_IMG" ]; then
    echo "Error: base image not found: $BASE_IMG" >&2
    exit 1
fi

[ -z "$TARGET_NAME" ] && TARGET_NAME=$(basename "$TARGET_IMG" .skosys)
[ -z "$BASE_NAME" ]   && BASE_NAME=$(basename "$BASE_IMG" .skosys)

TARGET_VERSION=$(extract_version "$TARGET_NAME")
BASE_VERSION=$(extract_version "$BASE_NAME")

if [ -z "$TARGET_VERSION" ] || [ -z "$BASE_VERSION" ]; then
    echo "Error: cannot extract version from names" >&2
    echo "  target: $TARGET_NAME -> $TARGET_VERSION" >&2
    echo "  base:   $BASE_NAME -> $BASE_VERSION" >&2
    exit 1
fi

[ -z "$BASE_TAG" ] && BASE_TAG="$BASE_VERSION"

DELTA_FILENAME="${TARGET_NAME}.from_${BASE_VERSION}.skdelta"

echo "=== Delta Generation ==="
echo "  Target: $TARGET_NAME ($TARGET_VERSION)"
echo "  Base:   $BASE_NAME ($BASE_VERSION)"
echo "  Output: $DELTA_FILENAME"

mkdir -p "$OUTPUT_DIR"

# 在删除源文件前记录全量镜像大小（后续用于计算增量包占比）
FULL_SIZE=$(stat -c %s "$TARGET_IMG")

# --- 动态计算或使用指定的工作文件系统大小 ---
WORK_DIR=$(mktemp -d /tmp/delta-work-XXXX)
WORK_IMG=$(mktemp /tmp/delta-img-XXXX.img)

if [ "$WORK_SIZE_SET" = false ]; then
    AVAIL_KB=$(df --output=avail "$(dirname "$WORK_IMG")" | tail -1 | tr -d ' ')
    AVAIL_GB=$((AVAIL_KB / 1024 / 1024))
    # 预留 5G 给 rsync batch 输出、xz 压缩和系统开销
    WORK_SIZE_GB=$((AVAIL_GB - 5))
    if [ "$WORK_SIZE_GB" -lt 15 ]; then
        echo "Error: insufficient disk space (available: ${AVAIL_GB}G, need at least 20G)" >&2
        exit 1
    fi
    WORK_SIZE="${WORK_SIZE_GB}G"
    echo "Auto-calculated work filesystem size: $WORK_SIZE (available: ${AVAIL_GB}G)"
fi

cleanup() {
    echo "Cleaning up work filesystem..."
    sync 2>/dev/null || true
    umount "$WORK_DIR" 2>/dev/null || true
    rm -rf "$WORK_DIR"
    rm -f "$WORK_IMG"
}
trap cleanup EXIT

echo "Creating temporary btrfs filesystem ($WORK_SIZE)..."
fallocate -l "$WORK_SIZE" "$WORK_IMG"
mkfs.btrfs -f "$WORK_IMG" > /dev/null
mount -t btrfs -o loop,nodatacow "$WORK_IMG" "$WORK_DIR"

# --- 还原两个版本的 btrfs 快照 ---
# .skosys 文件是 btrfs send 流经 xz 压缩的产物
# xz -dc 解压后通过管道传给 btrfs receive 还原为子卷
echo "Restoring target: $TARGET_NAME ..."
xz -dc "$TARGET_IMG" | btrfs receive --quiet "$WORK_DIR"
# 还原后立即删除源文件，腾出磁盘空间（CI 磁盘有限）
echo "Freeing source image: $(basename "$TARGET_IMG")"
rm -f "$TARGET_IMG"

echo "Restoring base: $BASE_NAME ..."
xz -dc "$BASE_IMG" | btrfs receive --quiet "$WORK_DIR"
echo "Freeing source image: $(basename "$BASE_IMG")"
rm -f "$BASE_IMG"

if [ ! -d "$WORK_DIR/$TARGET_NAME" ]; then
    echo "Error: target subvolume not found after btrfs receive" >&2
    echo "Available subvolumes:" >&2
    ls -1 "$WORK_DIR/" >&2
    exit 1
fi
if [ ! -d "$WORK_DIR/$BASE_NAME" ]; then
    echo "Error: base subvolume not found after btrfs receive" >&2
    echo "Available subvolumes:" >&2
    ls -1 "$WORK_DIR/" >&2
    exit 1
fi

# --- 生成目标 subvolume 元数据指纹（用于部署后校验） ---
# 遍历目标子卷的所有文件，收集每个文件的属性（路径/大小/权限/UID/GID/类型），
# 排序后取 sha256 得到整体指纹。部署增量包后对比此值可判断更新是否完整。
# - 排除 /proc /sys /dev /tmp /run：这些是运行时虚拟目录，不属于镜像内容
# - 排除 socket 文件（-not -type s）：rsync 会跳过它们，两边不一致会导致 hash 不匹配
# - LC_ALL=C sort：保证不同 locale 下排序结果一致
echo "Generating target metadata fingerprint..."
TARGET_META_HASH=$(cd "$WORK_DIR/$TARGET_NAME" && find . \
    -not -path './proc/*' -not -path './sys/*' -not -path './dev/*' \
    -not -path './tmp/*' -not -path './run/*' \
    -not -type s \
    -printf '%P\t%s\t%m\t%U\t%G\t%y\n' 2>/dev/null \
    | LC_ALL=C sort | sha256sum | awk '{print $1}')
echo "Target metadata hash: $TARGET_META_HASH"

# --- 生成 target 完整文件列表（用于部署后清理设备 baseline 中的多余文件） ---
# 设备上的 baseline 可能包含 CI baseline 中不存在的文件（如 fontconfig 缓存等运行时产生的文件）。
# delta 的删除清单只包含 CI baseline 中有但 target 中没有的文件，无法覆盖设备独有的多余文件。
# 将 target 完整文件列表打入 delta 包，部署后据此删除所有不在列表中的文件，确保精确匹配。
DELTA_STAGING="$OUTPUT_DIR/delta-staging"
mkdir -p "$DELTA_STAGING"
FILELIST_FILE="$DELTA_STAGING/.delta-filelist"
(cd "$WORK_DIR/$TARGET_NAME" && find . \
    -not -path './proc/*' -not -path './sys/*' -not -path './dev/*' \
    -not -path './tmp/*' -not -path './run/*' \
    -not -type s \
    -printf '%P\n' 2>/dev/null \
    | LC_ALL=C sort) > "$FILELIST_FILE"
FILELIST_COUNT=$(wc -l < "$FILELIST_FILE" | tr -d ' ')
echo "Target file list: $FILELIST_COUNT entries"

# --- 生成 tar 差异包 ---
# rsync 3.4.1 的 read-batch 有 bug，改用 tar 差异包方案：
# 1. rsync dry-run 找出变更/删除文件
# 2. tar 打包变更文件 + 删除清单 + 属性清单 + 完整文件列表
echo "Comparing target and base subvolumes..."
CHANGES_FILE="$DELTA_STAGING/changes.txt"
DELETIONS_FILE="$DELTA_STAGING/.delta-deletions"
MODIFIED_FILE="$DELTA_STAGING/modified.txt"
ATTRS_FILE="$DELTA_STAGING/.delta-attrs"

# 用 rsync dry-run 对比新旧两个子卷，找出所有差异文件
# -aAXH: 归档模式 + ACL + 扩展属性 + 硬链接（完整比较所有文件属性）
# --delete: 同时检测需要删除的文件（base 中有但 target 中没有的）
# --dry-run: 不实际修改，只输出差异
# --itemize-changes: 输出格式为 "YXcstpoguax 路径"，首字符表示变更类型
#   首字符含义: '>' '<' 'c' 'h' = 内容变更, '.' = 仅属性变更, '*' = 消息(如 deleting)
rsync -aAXH --delete --dry-run --itemize-changes \
    "$WORK_DIR/$TARGET_NAME/" "$WORK_DIR/$BASE_NAME/" 2>/dev/null \
    > "$CHANGES_FILE" || true

true > "$DELETIONS_FILE"
true > "$MODIFIED_FILE"
true > "$ATTRS_FILE"

# 解析 rsync itemize-changes 输出，精确分为三类：
#   1. 内容变更（'>' '<' 'c' 'h' 开头）→ 打包完整文件到 tar
#   2. 仅属性变更（'.' 开头且 p/o/g 位有变化）→ 记录到 .delta-attrs 清单
#   3. 仅时间戳变化（'.' 开头只有 t 位变化）→ 忽略，不影响 metadata hash
#
# rsync itemize flags 各位含义 (YXcstpoguax):
#   位0=更新类型 位1=文件类型 位2=checksum 位3=size 位4=timestamp
#   位5=permissions 位6=owner 位7=group 位8=unused 位9=ACL 位10=xattr
#
# 每行格式示例:
#   >f.st...... usr/bin/foo        — 内容变更的普通文件
#   cL+++++++++ usr/lib/bar -> ..  — 变更的符号链接（附带 " -> 目标"后缀）
#   hf......... usr/bin/foo => ..  — 变更的硬链接（附带 " => 目标"后缀）
#   .f...p.g... usr/bin/baz        — 仅权限/组变更 → 属性清单
#   .d..t...... usr/lib/dir/       — 仅时间戳变更 → 忽略
#   *deleting   usr/old/file       — 需要删除的文件
while IFS= read -r line; do
    change_type="${line:0:1}"
    # 提取路径: 去掉开头的 flags，再去掉符号链接 " -> " 和硬链接 " => " 后缀
    file_path=$(echo "$line" | sed -e 's/^[^ ]* //' -e 's/ -> .*//' -e 's/ => .*//')
    [ -z "$file_path" ] && continue
    # 跳过当前目录自身（rsync 总会输出根目录条目）
    [ "$file_path" = "./" ] && continue

    if [ "$change_type" = "*" ]; then
        # *deleting 行格式固定: "*deleting   路径"（3个空格）
        del_path=$(echo "$line" | sed 's/^\*deleting   //')
        [ -n "$del_path" ] && echo "$del_path" >> "$DELETIONS_FILE"
    elif [ "$change_type" = "." ]; then
        # 仅属性变更：检查 p(位5)/o(位6)/g(位7) 是否有变化
        p_flag="${line:5:1}"
        o_flag="${line:6:1}"
        g_flag="${line:7:1}"
        if [ "$p_flag" != "." ] || [ "$o_flag" != "." ] || [ "$g_flag" != "." ]; then
            # 去掉路径末尾的 /（目录条目）
            file_path_clean="${file_path%/}"
            target_path="$WORK_DIR/$TARGET_NAME/$file_path_clean"
            mode=$(stat -c '%a' "$target_path")
            uid=$(stat -c '%u' "$target_path")
            gid=$(stat -c '%g' "$target_path")
            printf '%s\t%s\t%s\t%s\n' "$file_path_clean" "$mode" "$uid" "$gid" >> "$ATTRS_FILE"
        fi
        # 只有时间戳变化的条目直接忽略，不影响 metadata hash
    else
        echo "$file_path" >> "$MODIFIED_FILE"
    fi
done < "$CHANGES_FILE"

# tr -d ' ': macOS 的 wc 会在数字前补空格，去掉它
MOD_COUNT=$(wc -l < "$MODIFIED_FILE" | tr -d ' ')
DEL_COUNT=$(wc -l < "$DELETIONS_FILE" | tr -d ' ')
ATTR_COUNT=$(wc -l < "$ATTRS_FILE" | tr -d ' ')
echo "  Modified/new files: $MOD_COUNT"
echo "  Deleted files: $DEL_COUNT"
echo "  Attribute-only changes: $ATTR_COUNT"

if [ "$MOD_COUNT" -eq 0 ] && [ "$DEL_COUNT" -eq 0 ] && [ "$ATTR_COUNT" -eq 0 ]; then
    echo "No differences found between versions, skipping"
    echo "SKIP" > "$OUTPUT_DIR/delta-status.txt"
    rm -rf "$DELTA_STAGING"
    exit 0
fi

echo "Creating delta tar package..."
DELTA_TAR="$OUTPUT_DIR/delta.tar"

# 打包控制文件（删除清单 + 属性清单 + 完整文件列表）
tar cf "$DELTA_TAR" -C "$DELTA_STAGING" .delta-deletions .delta-attrs .delta-filelist

# 从目标子卷中打包所有内容变更的文件（不含仅属性变更的文件，避免体积膨胀）
# --xattrs --acls: 保留扩展属性和 ACL（文件权限的完整信息）
# --numeric-owner: 用数字 UID/GID 而非用户名（避免跨系统用户名不一致）
# -T: 从文件列表读取要打包的路径
if [ "$MOD_COUNT" -gt 0 ]; then
    tar rf "$DELTA_TAR" -C "$WORK_DIR/$TARGET_NAME" \
        --xattrs --acls --numeric-owner \
        -T "$MODIFIED_FILE"
fi

rm -rf "$DELTA_STAGING"

# --- xz 压缩 ---
# -7: 压缩级别 7（平衡压缩率和速度）
# -T0: 使用所有 CPU 核心并行压缩
DELTA_FILE="$OUTPUT_DIR/$DELTA_FILENAME"

echo "Compressing delta with xz..."
xz -7 -T0 < "$DELTA_TAR" > "$DELTA_FILE"
rm -f "$DELTA_TAR"

# --- 增量包大小阈值检查 ---
# 如果增量包体积超过全量镜像的 MAX_RATIO%，说明差异太大，增量更新意义不大，跳过
DELTA_SIZE=$(stat -c %s "$DELTA_FILE")
RATIO=$((DELTA_SIZE * 100 / FULL_SIZE))

echo "Delta size: $(numfmt --to=iec "$DELTA_SIZE") ($RATIO% of full image)"

if [ "$RATIO" -gt "$MAX_RATIO" ]; then
    echo "Delta too large ($RATIO% > $MAX_RATIO%), skipping"
    echo "SKIP" > "$OUTPUT_DIR/delta-status.txt"
    rm -f "$DELTA_FILE"
    exit 0
fi

# --- 生成校验和 ---
# awk '{print $1}': sha256sum 输出格式为 "hash  filename"，只取 hash 部分
CHECKSUM=$(sha256sum "$DELTA_FILE" | awk '{print $1}')
echo "$CHECKSUM  $(basename "$DELTA_FILE")" > "$OUTPUT_DIR/delta-sha256sum.txt"

# --- 输出 manifest 片段（供 publish-delta.sh 合并到发布 manifest 中） ---
cat > "$OUTPUT_DIR/delta-entry.json" <<EOF
{
  "from_version": "${BASE_VERSION}",
  "from_tag": "${BASE_TAG}",
  "filename": "${DELTA_FILENAME}",
  "checksum": "sha256:${CHECKSUM}",
  "size": ${DELTA_SIZE},
  "full_size": ${FULL_SIZE},
  "target_meta_hash": "${TARGET_META_HASH}"
}
EOF

echo "OK" > "$OUTPUT_DIR/delta-status.txt"

echo "=== Delta generation complete ==="
echo "  File:     $DELTA_FILENAME"
echo "  Size:     $(numfmt --to=iec "$DELTA_SIZE")"
echo "  Ratio:    $RATIO%"
echo "  Checksum: $CHECKSUM"
