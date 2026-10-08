#!/bin/bash
# Runs the 27f7565 version of test_require_migration_ticket.sh against the current hooks.
# See compat/run-dev-compat.sh and AgDR-0216, Backward compatibility.
exec bash "$(dirname "$0")/compat/run-dev-compat.sh" test_require_migration_ticket.sh
