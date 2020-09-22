#!/bin/bash
set -e

root=$1
[[ $root && -d $root ]] || { echo "Missing '$root'" >&2; exit 1; }

cp "skype/skypeforlinux.sh" "$root/usr/bin/skypeforlinux"
chmod +x "$root/usr/bin/skypeforlinux"

# update dependencies
sed -i \
	-e 's/, apt-transport-https//' \
	-e 's/, gnome-keyring//' \
	-e '/^Depends: /a Replaces: skype (<< 5.4.0.2)' \
	-e '/^Depends: /a Breaks: skype (<< 5.4.0.2)' \
	"$root/DEBIAN/control"
sed -i \
	-e '/^Depends: /a Suggests: gnome-keyring' \
	"$root/DEBIAN/control"
