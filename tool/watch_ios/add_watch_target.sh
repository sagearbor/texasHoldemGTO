#!/usr/bin/env bash
# Runs add_watch_target.rb with the ruby + xcodeproj gem that CocoaPods ships
# (Homebrew cocoapods keeps its gems in its own libexec GEM_HOME).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
pod_bin="$(command -v pod)" || { echo "pod not found" >&2; exit 1; }
gem_home="$(sed -nE 's/.*GEM_HOME="([^"]+)".*/\1/p' "$pod_bin" | head -1)"
if [[ -n "$gem_home" ]]; then
  ruby_bin="$(head -1 "$gem_home/bin/pod" | sed 's/^#!//')"
  GEM_HOME="$gem_home" exec "$ruby_bin" "$here/add_watch_target.rb"
fi
# A gem-installed CocoaPods: its ruby already has xcodeproj.
ruby_bin="$(head -1 "$pod_bin" | sed -E 's/^#!(\/usr\/bin\/env )?//')"
exec $ruby_bin "$here/add_watch_target.rb"
