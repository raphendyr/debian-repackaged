#!/bin/bash
set -e

root=$1

[[ $root && -d $root ]] || { echo "Missing '$root'" >&2; exit 1; }

rm -rf "$root/opt"
rm -f "$root/usr/bin/skypeforlinux"
patch "$root/DEBIAN/postinst" < skype/postinst.patch
