#!/bin/bash
# =================================================================
# _lib.sh — Shared helpers for k3s scripts
# =================================================================

K3S_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${BLUE}>>> $*${NC}"; }
ok()    { echo -e "${GREEN}    ✔ $*${NC}"; }
warn()  { echo -e "${YELLOW}    ⚠ $*${NC}"; }
err()   { echo -e "${RED}    ✘ $*${NC}"; }
