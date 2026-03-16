#!/bin/bash
# build-delta.sh - 在两个 SkorionOS 版本之间生成增量更新包
# 供自动和手动增量工作流共用
#
# 输入:  两个 .skosys 文件 (btrfs send 流经 xz 压缩)
# 输出:  .skdelta 文件 (rsync batch 经 xz 压缩)、manifest 片段、sha256sum

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
# 如 skorionos-50-4_5d150d2-gnome-nv -> 50-4_5d150d2
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

# 在删除源文件前记录全量镜像大小（后续阈值检查需要）
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
echo "Restoring target: $TARGET_NAME ..."
xz -dc "$TARGET_IMG" | btrfs receive --quiet "$WORK_DIR"
# 释放源文件以腾出磁盘空间给后续操作
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

# --- 生成 rsync 差异批处理文件 ---
DELTA_BATCH="$OUTPUT_DIR/delta-batch"

echo "Generating rsync batch diff..."
rsync --only-write-batch="$DELTA_BATCH" \
    -aAXH --delete \
    "$WORK_DIR/$TARGET_NAME/" "$WORK_DIR/$BASE_NAME/"

# rsync 会额外生成一个 .sh 辅助脚本，不需要
rm -f "${DELTA_BATCH}.sh"

# --- 使用 xz 压缩增量数据 ---
DELTA_FILE="$OUTPUT_DIR/$DELTA_FILENAME"

echo "Compressing delta with xz..."
xz -7 -T0 < "$DELTA_BATCH" > "$DELTA_FILE"
rm -f "$DELTA_BATCH"

# --- 增量包大小阈值检查（超过全量镜像指定比例则跳过） ---
DELTA_SIZE=$(stat -c %s "$DELTA_FILE")
# FULL_SIZE 已在脚本开头（删除源文件前）通过 stat 获取
RATIO=$((DELTA_SIZE * 100 / FULL_SIZE))

echo "Delta size: $(numfmt --to=iec "$DELTA_SIZE") ($RATIO% of full image)"

if [ "$RATIO" -gt "$MAX_RATIO" ]; then
    echo "Delta too large ($RATIO% > $MAX_RATIO%), skipping"
    echo "SKIP" > "$OUTPUT_DIR/delta-status.txt"
    rm -f "$DELTA_FILE"
    exit 0
fi

# --- 生成校验和 ---
CHECKSUM=$(sha256sum "$DELTA_FILE" | awk '{print $1}')
echo "$CHECKSUM  $(basename "$DELTA_FILE")" > "$OUTPUT_DIR/delta-sha256sum.txt"

# --- 输出 manifest 片段（供 publish-delta.sh 合并） ---
cat > "$OUTPUT_DIR/delta-entry.json" <<EOF
{
  "from_version": "${BASE_VERSION}",
  "from_tag": "${BASE_TAG}",
  "filename": "${DELTA_FILENAME}",
  "checksum": "sha256:${CHECKSUM}",
  "size": ${DELTA_SIZE},
  "full_size": ${FULL_SIZE}
}
EOF

echo "OK" > "$OUTPUT_DIR/delta-status.txt"

echo "=== Delta generation complete ==="
echo "  File:     $DELTA_FILENAME"
echo "  Size:     $(numfmt --to=iec "$DELTA_SIZE")"
echo "  Ratio:    $RATIO%"
echo "  Checksum: $CHECKSUM"
