#!/bin/bash
set -eu

export TMPDIR=/dev/shm

config_file=
keep=
name=
rebuild=
while [[ $# -gt 0 ]]; do
	case "$1" in
		--) shift ; break ;;
		-k|--keep) keep=yes ;;
		-n|--name) name=$2 ; shift ;;
		-R|--rebuild) rebuild=yes ;;
		-*) echo "Unknown option $1" >&2 ; exit 64 ;;
		*) [[ -z $config_file ]] && config_file="$1" || break ;;
	esac
	shift
done

if [[ -z $config_file ]]; then
	echo "usage: $0 [opts] <config>" >&2
	exit 64
fi

if [[ -z $name ]]; then name=${config_file%.conf}; fi
whitelist_file="$name.whitelist"
sums_file="$name.sha256sums"
last_updated_file="$name.last_updated"
prepare_sh="$name.prepare.sh"
modify_sh="$name.modify.sh"

exit_msg() {
	echo "$1" >&2
	exit ${2:-1}
}

debug() {
	echo "DEBUG: $*" >&2
}

read_config() {
	local line
	[[ -f $config_file ]] || exit_msg "Missing config file '$config_file'"
	while read -r line; do
		line=$(echo "$line" | sed -e 's/#.*$//' -e 's/^\s*//')
		[[ $line ]] || continue
		case "$line" in
			LATEST_URL=*|VERSION_*|DOWNLOAD_URL=*|DEB_*)
				declare -gr -- "$line" || exit_msg "Invalid config"
				;;
			*)
				exit_msg "Invalid option ${line%%=*}"
				;;
		esac
	done < "$config_file"
}

resolve_redirects() {
	debug "curl $1"
	curl -LsSf -I -w %{url_effective} -o /dev/null "$1"
}

resolve_modified_header() {
	local headers
	debug "curl $1"
	headers=$(curl -LsSf -I "$1")
	modified=$(echo "$headers" | grep -i '^Last-Modified: ' | cut -d: -f2- | sed 's/^\s*//')
	modified=$(date -d "$modified" -u '+%Y%m%d.%H%M%S')
	etag=$(echo "$headers" | grep -i '^ETag: ' | cut -d: -f2- | cut -d'"' -f2)
	echo "$modified-$etag"
}

resolve_version() {
	if [[ $2 =~ $1 ]]; then
		if [[ ${#BASH_REMATCH[@]} > 1 ]]; then
			echo "${BASH_REMATCH[1]}"
		else
			echo "${BASH_REMATCH[0]}"
		fi
	else
		return 1
	fi
}

find_dangerous_files() {
	local path="${1%/}"
	local prefix="$path/"
	local matched
	declare -a whitelist

	if [[ -e $whitelist_file ]]; then
		readarray -t whitelist < "$whitelist_file"
	else
		debug "Missing '$whitelist_file'"
	fi
	while IFS= read -r -d $'\0' filename; do
		filename="/${filename#$prefix}"
		matched=
		for pattern in "${whitelist[@]}"; do
			if [[ $filename =~ $pattern ]]; then
				debug "Whitelisted $pattern : $filename"
				matched="x"
				break
			fi
		done
		[[ $matched ]] || printf '%s\0' "$filename"
	done < <(find "$path" \( -type f -o -type l \) -print0)
}

download() {
	debug "curl $2"
	if [[ -e $1 ]]; then
		curl -LsSf -o "$1" -z "$1" "$2"
	else
		curl -LsSf -o "$1" "$2"
	fi
}


# Check required binaries
for b in \
	curl grep sed zcat \
	debsign dpkg dpkg-genchanges dupload fakeroot \
; do
	if ! command -v $b >/dev/null; then
		echo "Missing required binary '$b'"
		exit 1
	fi
done

# Check input parameters
[[ -e $prepare_sh && ! -x $prepare_sh ]] && exit_msg "Prepare script '$prepare_sh' is not executable!"
[[ -e $modify_sh && ! -x $modify_sh ]] && exit_msg "Modify script '$modify_sh' is not executable!"

# Parse config
LATEST_URL=
VERSION_MATCH=
VERSION_MODIFIED=
DOWNLOAD_URL=
DEB_SECTION=
DEB_PRIORITY=
DEB_BUILD_NUMBER=
read_config
[[ -z $LATEST_URL ]] && exit_msg "Missing LATEST_URL in $config_file"
debug "Resolving latest	    : $LATEST_URL"

# Resolve last updated
last_updated=
[[ -s $last_updated_file ]] && last_updated=$(< "$last_updated_file")

# Resolve latest
url=$(resolve_redirects "$LATEST_URL")
debug "Latest resolved to   : $url"

# Resolve version
if [[ $VERSION_MATCH ]]; then
	version=$(resolve_version "$VERSION_MATCH" "$url")
elif [[ $VERSION_MODIFIED ]]; then
	version=$(resolve_modified_header "$url")
else
	version=$url
fi
debug "Latest version       : $version"
debug "Last updated version : ${last_updated:--}"

# Check if update is required
if [[ -z $rebuild ]] && [[ $last_updated ]] && dpkg --compare-versions "$version" le "$last_updated"; then
	echo "Package is uptodate ($version), no changes required.."
	exit 0
fi

# Resolve download url
if [[ $DOWNLOAD_URL ]]; then
	url=${DOWNLOAD_URL//\$VERSION/$version}
	[[ $url == $DOWNLOAD_URL ]] && exit_msg "Invalid DOWNLOAD_URL: \$VERSION was not found or replaced"
fi
debug "Download url         : $url"

# Resolve cache file
cachefile="${config_file%.conf}-latest.deb"
debug "Cached file          : $cachefile"

# Download source to the cache file
download "$cachefile" "$url"

# Preparing cache dir
clean_cache() {
	if [[ "$cachedir" && -d "$cachedir" ]]; then
		if [[ "$keep" ]]; then
			echo "WARNING: cache dir $cachedir was not deleted!" >&2
		else
			rm -rf "$cachedir"
		fi
	fi
	if [[ "$cachesums" && -f "$cachesums" ]]; then
		if [[ "$keep" ]]; then
			echo "WARNING: cached file $cachesums was not deleted!" >&2
		else
			rm -f "$cachesums"
		fi
	fi
}
trap clean_cache EXIT INT TERM
cachedir=$(mktemp --tmpdir --directory repackage-${cachefile%.deb}.XXXXX)
cachesums="${cachedir%/}.sha256sums"

# Extract package
fakeroot sh -ec \
	'dpkg -x "$1" "$2" && dpkg -e "$1" "$2/DEBIAN"' - \
	"$cachefile" "$cachedir"

# Verify sums before modifications
(
	cd "$cachedir"
	if [[ -e "DEBIAN/md5sums" ]]; then
		md5sum -c "DEBIAN/md5sums" || exit_msg "Invalid md5sum in the source package"
	fi
	if [[ -e "DEBIAN/sha256sums" ]]; then
		sha256sum -c "DEBIAN/sha256sums" || exit_msg "Invalid sha256sum in the source package"
	fi
) | { grep -v ': OK$' || true; }

# Execute prepare script
[[ -x $prepare_sh ]] && fakeroot "./$prepare_sh" "$cachedir"

# Simple security check for the content
find_dangerous_files "$cachedir" | sort -z | sed -z 's,^/,,' \
	| (cd "$cachedir"; xargs -0r sha256sum) \
	> "$cachesums"
if [[ -s $cachesums ]] && ! [[ -e $sums_file ]]; then
	cat "$cachesums"
	exit_msg "Missing '$sums_file', but '${cachedir%/}.sha256sums' was not empty."
elif ! diff "$cachesums" "$sums_file"; then
	exit_msg "Dangerous files have changed, validate content and update '$sums_file' with new sums if ok"
fi

# Execute modify script
[[ -x $modify_sh ]] && fakeroot "./$modify_sh" "$cachedir"

# Prepare Debian files
DEBFULLNAME=${DEBFULLNAME:-${NAME:-}}
DEBEMAIL=${DEBEMAIL:-${EMAIL:-}}
if [[ $DEBEMAIL =~ "^(.*)\s+<(.*)>$" ]]; then
	DEBFULLNAME=${DEBFULLNAME:-${BASH_REMATCH[1]}}
	DEBEMAIL=${BASH_REMATCH[2]}
fi
[[ "$DEBFULLNAME" ]] || DEBFULLNAME=$(getent passwd "$USER" | cut -d':' -f5 | sed 's/,.*$//')

deb_name=$(grep '^Package: ' "$cachedir/DEBIAN/control" | cut -d: -f2- | sed 's/^\s*//')
deb_arch=$(grep '^Architecture: ' "$cachedir/DEBIAN/control" | cut -d: -f2- | sed 's/^\s*//')
deb_version=$(grep '^Version: ' "$cachedir/DEBIAN/control" | cut -d: -f2- | sed 's/^\s*//')
deb_maintainer=$(grep '^Maintainer: ' "$cachedir/DEBIAN/control" | cut -d: -f2- | sed 's/^\s*//')
deb_section=${DEB_SECTION:-$(grep '^Section: ' "$cachedir/DEBIAN/control" | cut -d: -f2- | sed 's/^\s*//')}
deb_priority=${DEB_PRIORITY:-$(grep '^Priority: ' "$cachedir/DEBIAN/control" | cut -d: -f2- | sed 's/^\s*//')}
deb_nonfree=${DEB_NONFREE:-}

deb_version="$deb_version-n1fi${DEB_BUILD_NUMBER:-1}"
if [[ $deb_section =~ ^non-free/ ]]; then
	deb_nonfree=yes
elif [[ $deb_nonfree ]]; then
	deb_section="non-free/$deb_section"
fi
[[ $deb_priority == 'extra' ]] && deb_priority='optional'

deb_file="${deb_name}_${deb_version}_${deb_arch}.deb"
deb_changes="${deb_name}_${deb_version}.changes"

# modify control file
sed -i 's,^\(Priority:\) .*$,\1 '"$deb_priority"',' "$cachedir/DEBIAN/control"
sed -i 's,^\(Section:\) .*$,\1 '"$deb_section"',' "$cachedir/DEBIAN/control"
sed -i 's,^\(Version:\) .*$,\1 '"$deb_version"',' "$cachedir/DEBIAN/control"

# modify changelog
cat > "$cachedir/DEBIAN/changelog" <<EOF
$deb_name ($deb_version) testing; urgency=medium

  * Custom build for deb.n-1.fi

 -- $DEBFULLNAME <$DEBEMAIL>  $(LANG=C date -R)

EOF

cached_changelog=$(find "$cachedir/usr/share/doc" -name changelog.gz)
if [[ -e "$cached_changelog" ]]; then
	zcat "$cached_changelog" >> "$cachedir/DEBIAN/changelog"
	rm "$cached_changelog"
fi

mkdir -p "$cachedir/usr/share/doc/$deb_name"
cat "$cachedir/DEBIAN/changelog" | gzip -c | fakeroot tee "$cachedir/usr/share/doc/$deb_name/changelog.gz" >/dev/null
rm "$cachedir/DEBIAN/changelog" # changelog is not supposed to be part of the control package

# Recalculate md5sums before rebuild
(
	cd "$cachedir"
	find . \( -type d -name DEBIAN -prune \) -o -type f -print0 | sed -z 's,\./,,' | sort -z | xargs -0r md5sum > DEBIAN/md5sums
)

# Package deb (or copy)
fakeroot dpkg -b "$cachedir" "$deb_file"

# Generate *.changes file
zcat "$cachedir/usr/share/doc/$deb_name/changelog.gz" > "$cachedir/DEBIAN/changelog"
{
	printf 'Source: %s\nSection: %s\nPriority: %s\n' "$deb_name" "$deb_section" "$deb_priority"
	grep -E '^(Maintainer):' "$cachedir/DEBIAN/control"
	echo
	grep -vE '^(Maintainer|Version|Vendor|Installed-Size):' "$cachedir/DEBIAN/control"
} > "$cachedir/DEBIAN/control.source"

echo "${deb_name}_${deb_version}_${deb_arch}.deb $deb_section $deb_priority" | \
	dpkg-genchanges -b -u. \
		-m"$deb_maintainer" \
		-e"$DEBFULLNAME <$DEBEMAIL>" \
		-c"$cachedir/DEBIAN/control.source" \
		-l"$cachedir/DEBIAN/changelog" \
		-f/dev/stdin \
		-D"Binary-Only=yes" \
		-D"Distribution=testing" \
		> "$deb_changes"

# OK, cleaning
clean_cache && trap - EXIT INT TERM

# New package is complete
echo "$version" > "$last_updated_file"
echo "OK:"
echo " $deb_file"
echo " $deb_changes"

# Upload check
while :; do
	read -p "Should we upload the file? [Y/n]? " -n 1 -r yesno
	[[ -z $yesno ]] && break
	echo
	[[ $yesno =~ ^[Yy]$ ]] && break
	if [[ $yesno =~ ^[Nn]$ ]]; then
		echo "Do upload manually: dupload $deb_changes"
		exit 0
	fi
done

# Upload

echo "Sign..."
debsign --debs-dir . -e"$DEBFULLNAME <$DEBEMAIL>" "$deb_changes"

echo "Uploadi..."
dupload "$deb_changes"
