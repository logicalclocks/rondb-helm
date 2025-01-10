#!/bin/bash

# Copyright (c) 2024-2025 Hopsworks AB. All rights reserved.

set -e

{{ include "rondb.sedMyCnfFile" . }}

{{ include "rondb.initializeMySQLd" . }}
