#!/bin/bash
set -e

root=$1
resources="$root/usr/share/discord-canary/resources"
sources="$PWD/discord"
asar="$PWD/node_modules/.bin/asar"

[[ $root && -d $root ]] || { echo "Missing '$root'" >&2; exit 1; }

[[ -f $asar ]] || npm install --no-save --engine-strict asar

set -x

# extract asar
app="$root/app"
[[ -e $app ]] && rm -rf "$app"
[[ -e "$resources/app.asar" ]] || { echo "Missing '$resources/app.asar'" >&2; exit 1; }
$asar extract "$resources/app.asar" "$app"

# Copy files
cp "$sources/injectCss.js" "$app/app_bootstrap/"
cp "$sources/fix_styles.css" "$resources"

# Patch indexjs
indexjs="$app/app_bootstrap/bootstrap.js"
awk -f /dev/stdin "$indexjs" > "$indexjs.tmp" <<AWK
	/function startUpdate()/ {
		print "let _inject = require('./injectCss.js');"
		print "_inject.findAndInject();"
		print "";
		print;
		next;
	};
	1
AWK
mv "$indexjs.tmp" "$indexjs"
grep -qs "injectCss.js" "$indexjs" || { echo "injection failed!" >&2; exit 1; }

# Repackage
rm -f "$resources/app.asar"
$asar pack "$app" "$resources/app.asar"

# cleanup
rm -rf "$app"
