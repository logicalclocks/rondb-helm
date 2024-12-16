#!/bin/bash

# Copyright (c) 2024-2024 Hopsworks. All rights reserved.

set -e

{{ include "rondb.sedMyCnfFile" . }}

{{ include "rondb.initializeMySQLd" . }}
