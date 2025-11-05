#! /bin/bash

set -e
set -x

BUILD_BRANCH=${BUILD_BRANCH:-}

if [ -z "${BUILD_BRANCH}" ]; then
  echo "BUILD_BRANCH must be specified"
  exit 1
fi

echo "Merging branch ${BUILD_BRANCH} into rootfs"

cp -f branch/manifest-${BUILD_BRANCH} sub-manifest
cp -f branch/base-* .

source ./manifest
source ./sub-manifest

if [ -n "${POSTCOPY}" ]; then
  echo "Copying postcopy files"
  for dir in ${POSTCOPY}; do
    echo "Copying ${dir}"
    cp -rav postcopy/${dir}/* rootfs/
  done
fi
