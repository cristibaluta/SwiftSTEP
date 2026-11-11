#!/bin/sh
# Regenerates the STL demo samples from the STEP samples. Run from the package root.
set -e
swift run -c release step2stl Sources/SwiftSTEPDemo/Samples "$@"
