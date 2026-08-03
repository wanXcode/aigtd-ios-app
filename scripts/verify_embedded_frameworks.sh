#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /path/to/AIGTD.app" >&2
  exit 64
fi

app_path="$1"
executable_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Info.plist")
executable_path="$app_path/$executable_name"

if [ ! -x "$executable_path" ]; then
  echo "error: app executable not found: $executable_path" >&2
  exit 1
fi

dependencies=$(otool -L "$executable_path" | awk '/@rpath\// { print $1 }')
for dependency in $dependencies; do
  relative_path=${dependency#@rpath/}
  embedded_path="$app_path/Frameworks/$relative_path"
  if [ ! -e "$embedded_path" ]; then
    echo "error: missing embedded dependency: $dependency" >&2
    exit 1
  fi
done

echo "Embedded framework verification passed: $app_path"
