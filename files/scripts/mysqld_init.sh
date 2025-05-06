#!/bin/bash

# Copyright (c) 2024-2025 Hopsworks AB. All rights reserved.

set -e

{{ include "rondb.sedMyCnfFile" . }}

# Ignore potential errors during MySQL initialization.
#
# In the current rondb-helm implementation, if MySQL crashes, the pod restart
# will redundantly trigger MySQL initialization again. Having 'set -e' here
# would cause the restart process to fail.
# Instead, we use 'set +e' to ignore any errors during this phase.
#
# Reasons to use this solution:
# 1. Much simpler fix
# 2. Redundant initialization won't modify files in the data directory, and
#    MySQL can still start successfully.
# 3. If any errors occur during the first initialization, it's safe to skip them,
#    because the subsequent restart will catch and handle the error properly.
set +e
{{ include "rondb.initializeMySQLd" . }}
set -e
