#!/bin/sh
# Installs the restic.yazi plugin shipped next to this script into Yazi's plugins directory.
#
#   ./install.sh                      -> $YAZI_CONFIG_HOME, or ~/.config/yazi
#
# An existing installation is replaced. A symlink (e.g. a development checkout) is never touched.
# If `ya pkg` manages the plugin (it is listed in package.toml) a warning is printed: see below.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
config=${YAZI_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}/yazi}
target=$config/plugins/restic.yazi

if [ ! -f "$here/restic.yazi/main.lua" ]; then
  echo "error: $here/restic.yazi/main.lua not found: run this script from an unpacked build" >&2
  exit 1
fi
if [ -L "$target" ]; then
  echo "error: $target is a symlink (development checkout?): remove it first if you want to install the build" >&2
  exit 1
fi

# `ya pkg` records a hash of the files it deployed and refuses to touch a folder that no longer matches it, so
# replacing a managed plugin makes the next `ya pkg add/upgrade/install` fail until the plugin is deleted from it.
if grep -Eq '^use *= *"[^"]*[:/]restic"' "$config/package.toml" 2>/dev/null; then
  echo "warning: $config/package.toml lists restic.yazi: it is managed by 'ya pkg'." >&2
  echo "         Installing over it makes later 'ya pkg upgrade/install' abort (modified plugin)." >&2
  echo "         Prefer 'ya pkg upgrade', or first run 'ya pkg delete <owner>/<repo>:restic'." >&2
fi

mkdir -p "$config/plugins"
rm -rf "$target"
cp -R "$here/restic.yazi" "$target"

version=$(sed -n 's/.*version = "\(.*\)".*/\1/p' "$target/version.lua")
echo "Installed restic.yazi $version -> $target"
echo "Next: add the init.lua / yazi.toml / keymap.toml lines described in $target/README.md"
if [ -f "$here/sample_backup.restic" ]; then
  echo "An annotated .restic template is in $here/sample_backup.restic"
fi
