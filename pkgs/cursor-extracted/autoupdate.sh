#!/usr/bin/env bash

set -e

curl -L 'https://www.cursor.com/api/download?platform=linux-x64&releaseTrack=latest' -o latest.json

version="$(grep -Po '"version":"\K[^"]+' latest.json)"
url="$(grep -Po '"downloadUrl":"\K[^"]+' latest.json)"

rm latest.json

echo $version $url

sed -r "s@^(pkgver=).+@\1${version}@g" -i PKGBUILD
sed -r "s@^(_cursor_url=).+@\1${url}@g" -i PKGBUILD
# makepkg --printsrcinfo > .SRCINFO
# git commit -am "${version}"