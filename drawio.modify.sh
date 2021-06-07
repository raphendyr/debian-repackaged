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

# Copy files
cp "$sources/disableUpdate.js" "$app/"

# Patch indexjs
sed -i \
	-e 's,^\(\s*const menuBar = menu\.buildFromTemplate(template)\)$,/* XXX: remove menu */\n//\1,' \
	-e 's,^\(\s*menu\.setApplicationMenu(menuBar)\)$,//\1,' \
	-e '/^    let win = createWindow()/a\    /* XXX: remove menu */\n    win.removeMenu()' \
	"$app/electron.js"
grep -qsE '^\s*//.*setApplicationMenu' "$app/electron.js" || { echo "Fixing menu failed! (1)" >&2; exit 1; }
grep -qsE '^\s*win\.removeMenu' "$app/electron.js" || { echo "Fixing menu failed! (2)" >&2; exit 1; }

# Repackage
rm -f "$resources/app.asar"
"$asar" pack "$app" "$resources/app.asar"

# cleanup
rm -rf "$app"
