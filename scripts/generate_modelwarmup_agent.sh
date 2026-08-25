#!/bin/sh
# Generates the ModelWarmup warm-while-closed launch-agent plist into the app bundle
# (macOS only; no-op elsewhere). SMAppService looks the file up by name, and the SDK
# derives that name from the bundle id ("<bundle id>.modelwarmup.plist"). This
# project's bundle id embeds DEVELOPMENT_TEAM, so the plist cannot be a static
# resource -- it has to be generated from the build's actual identity, or SMAppService
# never finds it and launchd could not exec the listed binary.
#
# Shipping the plist is normally the SDK's auto-enable opt-in; this app gates enabling
# behind AppSettings.warmWhileClosed instead (see Playground.swift).

set -eu

if [ "${PLATFORM_NAME}" != "macosx" ]; then
    exit 0
fi

AGENTS_DIR="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LaunchAgents"
PLIST_PATH="${AGENTS_DIR}/${PRODUCT_BUNDLE_IDENTIFIER}.modelwarmup.plist"
mkdir -p "${AGENTS_DIR}"

cat > "${PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Generated at build time by scripts/generate_modelwarmup_agent.sh; do not edit in
     the built product.

     StartInterval is an hourly heartbeat, not the cadence: each firing checks the
     schedule persisted by enableBackgroundAgent(schedule:) and exits in milliseconds
     when nothing is due.

     Deliberately no ProcessType / Nice / LowPriorityIO keys: launchd's Background
     class would clamp the warm below the priority the equivalent iOS background task
     gets, and a warm should finish fast rather than trickle. -->
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${PRODUCT_BUNDLE_IDENTIFIER}.modelwarmup</string>
	<key>BundleProgram</key>
	<string>Contents/MacOS/${EXECUTABLE_NAME}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${EXECUTABLE_NAME}</string>
		<string>--argmax-warm-only</string>
	</array>
	<key>StartInterval</key>
	<integer>3600</integer>
</dict>
</plist>
EOF

echo "Generated ${PLIST_PATH}"
