#!/bin/bash

set -e

{{ include "rondb.sedMyCnfFile" . }}

{{ include "rondb.initializeMySQLd" . }}
