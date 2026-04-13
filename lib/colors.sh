#!/bin/bash
#
# lib/colors.sh - Color constants for terminal output
#
# Provides RED, GREEN, YELLOW, BLUE, and NC (no color) for consistent
# colored terminal output across the deployment scripts.
#

[ "${_COLORS_SH_SOURCED:-0}" -eq 1 ] && return 0
_COLORS_SH_SOURCED=1

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[0;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'
