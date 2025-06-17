#!/bin/bash
# Clean test runner that suppresses warnings and compilation noise

export ERL_COMPILER_OPTIONS="[nowarn_unused_vars,nowarn_export_all,nowarn_shadow_vars,nowarn_unused_function,nowarn_bif_clash,nowarn_unused_record,nowarn_deprecated_function,nowarn_obsolete_guard,nowarn_untyped_record,nowarn_missing_spec]"

# Run tests with clean output - suppress warnings but preserve failures
mix test "$@" 2>&1 | grep -v -E "^    (warning:|     │|    │)" | grep -v "└─"