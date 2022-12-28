#!/bin/bash
set -e

root=$1
resources="$root/opt/drawio/resources"
sources="$PWD/drawio"

[[ $root && -d $root ]] || { echo "Missing '$root'" >&2; exit 1; }

asar="$PWD/node_modules/.bin/asar"
[[ -f $asar ]] || npm install --no-save --engine-strict asar

set -x

# extract asar
app="$root/app"
[[ -e $app ]] && rm -rf "$app"
[[ -e "$resources/app.asar" ]] || { echo "Missing '$resources/app.asar'" >&2; exit 1; }
"$asar" extract "$resources/app.asar" "$app"

# path 1) Disable update system of the app
cp "$sources/disableUpdate.js" "$app/drawio/src/main/webapp/disableUpdate.js"

# Repackage
rm -f "$resources/app.asar"
"$asar" pack "$app" "$resources/app.asar"

# cleanup
rm -rf "$app"
