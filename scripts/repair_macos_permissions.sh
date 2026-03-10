#!/bin/zsh

set -euo pipefail

current_bundle_id="com.orttaai.Orttaai"
legacy_bundle_ids=(
  "com.uttrai.Uttrai"
  "com.uttrai.UttraiUITests.xctrunner"
)
services=(
  "Accessibility"
  "ListenEvent"
)
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

echo "Resetting macOS TCC permissions for Orttaai and legacy Uttrai bundle IDs..."
for bundle_id in "$current_bundle_id" "${legacy_bundle_ids[@]}"; do
  for service in "${services[@]}"; do
    tccutil reset "$service" "$bundle_id" >/dev/null 2>&1 || true
    echo "  reset $service for $bundle_id"
  done
done

legacy_paths=(
  "$HOME/Library/Application Scripts/com.uttrai.Uttrai"
  "$HOME/Library/Application Scripts/com.uttrai.UttraiUITests.xctrunner"
  "$HOME/Library/Caches/com.uttrai.Uttrai"
  "$HOME/Library/Caches/com.apple.nsurlsessiond/Downloads/com.uttrai.Uttrai"
  "$HOME/Library/Containers/com.uttrai.Uttrai"
  "$HOME/Library/Containers/com.uttrai.UttraiUITests.xctrunner"
  "$HOME/Library/HTTPStorages/com.uttrai.Uttrai"
  "$HOME/Library/HTTPStorages/com.uttrai.Uttrai.binarycookies"
  "$HOME/Library/Preferences/com.uttrai.Uttrai.plist"
)

echo "Removing legacy Uttrai support artifacts that are safe to delete..."
for target_path in "${legacy_paths[@]}"; do
  if [[ -e "$target_path" ]]; then
    if rm -rf "$target_path" >/dev/null 2>&1; then
      echo "  removed $target_path"
    else
      echo "  skipped $target_path (macOS denied access)"
    fi
  fi
done

if [[ -d "$HOME/Library/Application Support/CrashReporter" ]]; then
  while IFS= read -r crash_file; do
    [[ -n "$crash_file" ]] || continue
    if rm -f "$crash_file" >/dev/null 2>&1; then
      echo "  removed $crash_file"
    else
      echo "  skipped $crash_file (macOS denied access)"
    fi
  done < <(find "$HOME/Library/Application Support/CrashReporter" -maxdepth 1 -name 'Uttrai_*.plist' 2>/dev/null)
fi

if [[ -d "$HOME/Library/Developer/Xcode/DerivedData" ]]; then
  while IFS= read -r app_path; do
    [[ -n "$app_path" ]] || continue
    "$lsregister" -u "$app_path" >/dev/null 2>&1 || true
    echo "  unregistered $app_path"
  done < <(find "$HOME/Library/Developer/Xcode/DerivedData" -type d -name 'Uttrai.app' 2>/dev/null)

  while IFS= read -r derived_dir; do
    [[ -n "$derived_dir" ]] || continue
    if rm -rf "$derived_dir" >/dev/null 2>&1; then
      echo "  removed $derived_dir"
    else
      echo "  skipped $derived_dir (macOS denied access)"
    fi
  done < <(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 1 -type d -name 'Uttrai-*' 2>/dev/null)
fi

"$lsregister" -kill -r -domain user >/dev/null 2>&1 || true
echo "  refreshed user LaunchServices registrations"

if [[ -d "$HOME/Library/Application Support/Uttrai" ]]; then
  echo "Left $HOME/Library/Application Support/Uttrai in place because it may contain legacy user data."
fi

echo "Done. Relaunch Orttaai, then re-grant Accessibility and Input Monitoring when prompted."
