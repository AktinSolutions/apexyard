#!/bin/bash
# Runs the merge-base version of test_command_scrub_must_block.sh against the current hooks.
# See compat/run-dev-compat.sh and AgDR-0222, Backward compatibility.

# Isolate from live Claude Code session pin/cache (me2resh/apexyard#1549).
# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/_test-session-isolation.sh"
exec bash "$(dirname "$0")/compat/run-dev-compat.sh" test_command_scrub_must_block.sh
