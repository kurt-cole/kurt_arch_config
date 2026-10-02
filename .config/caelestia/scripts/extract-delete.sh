#!/usr/bin/env bash
# Thunar custom action "Extract and delete archive": extract each archive into
# a folder named after it, then move the archive to the trash (or delete it
# where the filesystem has no trash). The archive is
# only trashed if extraction succeeded.
#
# If the archive holds a single top-level folder, that folder becomes the
# target instead of being nested (foo.zip -> foo/, not foo/foo/).

fail() {
    notify-send -a Thunar -i dialog-error "Extract failed" "$1"
}

for archive in "$@"; do
    [[ -f $archive ]] || continue
    dir=$(dirname -- "$archive")
    name=$(basename -- "$archive")

    # Strip the archive suffix, double ones first.
    stem=$name
    for ext in .tar.gz .tar.bz2 .tar.xz .tar.zst .tar.lz .tar.lzma .tar.Z \
               .tgz .tbz .tbz2 .txz .tzst .tar .zip .7z .rar .gz .bz2 .xz .zst \
               .cbz .cbr .cb7 .jar .iso; do
        if [[ ${name,,} == *"$ext" ]]; then
            stem=${name:0:${#name}-${#ext}}
            break
        fi
    done
    [[ $stem == "$name" ]] && stem="${name%.*}"

    # Never overwrite: foo, foo (2), foo (3), ...
    target="$dir/$stem"
    n=2
    while [[ -e $target ]]; do
        target="$dir/$stem ($n)"
        ((n++))
    done

    tmp=$(mktemp -d "$dir/.extract-XXXXXX") || { fail "$name: cannot write to $dir"; continue; }

    case ${name,,} in
        *.tar|*.tar.*|*.tgz|*.tbz|*.tbz2|*.txz|*.tzst)
            out=$(bsdtar -xf "$archive" -C "$tmp" 2>&1) ;;
        *)
            out=$(7z x -y -bd -o"$tmp" -- "$archive" 2>&1) ;;
    esac
    status=$?

    if ((status != 0)); then
        rm -rf -- "$tmp"
        fail "$name: $(tail -n 3 <<<"$out")"
        continue
    fi

    entries=("$tmp"/* "$tmp"/.[!.]* "$tmp"/..?*)
    existing=()
    for e in "${entries[@]}"; do [[ -e $e || -L $e ]] && existing+=("$e"); done

    if ((${#existing[@]} == 1)) && [[ -d ${existing[0]} && ! -L ${existing[0]} ]]; then
        mv -- "${existing[0]}" "$target" && rmdir -- "$tmp"
    else
        mv -- "$tmp" "$target"
    fi || { fail "$name: could not move files into place (left in $tmp)"; continue; }

    # Trash where possible; some mounts (tmpfs) have no trash, so delete there.
    gio trash -- "$archive" 2>/dev/null || rm -f -- "$archive" \
        || fail "$name: extracted, but could not remove the archive"
done
