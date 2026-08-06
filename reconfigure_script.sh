#!/bin/bash
################################################################################
# Script Name : reconfigure_oracle.sh
# Purpose     : Oracle Standalone Database Memory & Process Reconfiguration
# Version     : 2.0
#
# Features:
#   - Standalone Oracle databases only
#   - Supports filesystem and ASM SPFILE
#   - SPFILE backup before change
#   - Safe restart handling
#   - SQL error trapping
#   - HugePages validation
#   - Memory validation
#   - Rollback script integration
#
# Usage:
#   ./reconfigure_oracle.sh
#
# Rollback:
#   ./rollback_oracle.sh <generated_pfile_backup>
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARAM_FILE="${SCRIPT_DIR}/db_reconfig.param"

LOG_FILE="/tmp/oracle_reconfigure_$(date +%Y%m%d_%H%M%S).log"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

RECONFIGURED=0
PFILE_BACKUP=""

###############################################################################
# Logging
###############################################################################

log()
{
    local level="$1"
    shift

    local msg="$*"

    case "$level" in
        INFO)
            echo -e "${BLUE}[$(date '+%F %T')] [INFO] ${msg}${NC}" | tee -a "$LOG_FILE"
            ;;
        WARN)
            echo -e "${YELLOW}[$(date '+%F %T')] [WARN] ${msg}${NC}" | tee -a "$LOG_FILE"
            ;;
        ERROR)
            echo -e "${RED}[$(date '+%F %T')] [ERROR] ${msg}${NC}" | tee -a "$LOG_FILE"
            ;;
        SUCCESS)
            echo -e "${GREEN}[$(date '+%F %T')] [SUCCESS] ${msg}${NC}" | tee -a "$LOG_FILE"
            ;;
    esac
}


###############################################################################
# Error handling
###############################################################################

fatal()
{
    log ERROR "$1"
    log WARN "If SPFILE was modified, rollback using:"
    log WARN "./rollback_oracle.sh ${PFILE_BACKUP}"
    exit 1
}


trap 'fatal "Interrupted by user"' SIGINT SIGTERM


###############################################################################
# Load parameters
###############################################################################

load_params()
{
    log INFO "Loading parameter file ${PARAM_FILE}"

    [[ -f "$PARAM_FILE" ]] ||
        fatal "Parameter file not found"

    while IFS='=' read -r key value
    do
        [[ -z "$key" ]] && continue
        [[ "$key" =~ ^# ]] && continue

        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)

        declare -g "${key}=${value}"

    done < "$PARAM_FILE"


    required=(
        oracle_home
        oracle_instance
        sga_max_size_gb
        sga_target_gb
        pga_aggregate_target_gb
        pga_aggregate_limit_gb
        processes
    )


    for p in "${required[@]}"
    do
        if [[ -z "${!p:-}" ]]
        then
            fatal "Missing parameter ${p}"
        fi
    done
}


###############################################################################
# Oracle environment
###############################################################################

setup_environment()
{
    log INFO "Setting Oracle environment"


    [[ -d "$oracle_home" ]] ||
        fatal "ORACLE_HOME does not exist"


    export ORACLE_HOME="$oracle_home"
    export ORACLE_SID="$oracle_instance"

    export PATH="$ORACLE_HOME/bin:$PATH"

    export LD_LIBRARY_PATH="$ORACLE_HOME/lib:${LD_LIBRARY_PATH:-}"


    command -v sqlplus >/dev/null ||
        fatal "sqlplus not found"


    command -v bc >/dev/null ||
        fatal "bc package missing"
}


###############################################################################
# SQL execution wrapper
###############################################################################

run_sql()
{
    local sql="$1"

    sqlplus -s / as sysdba <<EOF
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET PAGESIZE 0
SET FEEDBACK OFF
SET VERIFY OFF
SET HEADING OFF
SET ECHO OFF

$sql

EXIT
EOF
}


###############################################################################
# HugePages validation
###############################################################################

validate_hugepages()
{

    log INFO "Validating HugePages"


    local hugepage_size
    hugepage_size=$(awk '/Hugepagesize/ {print $2}' /proc/meminfo)


    local required_pages

    required_pages=$(echo "
    ($sga_max_size_gb*1024*1024) / $hugepage_size
    " | bc)


    local current_pages

    current_pages=$(awk '/HugePages_Total/ {print $2}' /proc/meminfo)


    log INFO "HugePage size : ${hugepage_size} KB"
    log INFO "Required pages: ${required_pages}"
    log INFO "Current pages : ${current_pages}"


    if (( current_pages < required_pages ))
    then
        fatal "Insufficient HugePages configured"
    fi


    log SUCCESS "HugePages validation successful"
}


###############################################################################
# RAM validation
###############################################################################

validate_memory()
{

    log INFO "Validating server memory"


    local total_ram_gb

    total_ram_gb=$(awk '/MemTotal/ {
        printf "%.2f",$2/1024/1024
    }' /proc/meminfo)


    local oracle_memory

    oracle_memory=$(echo "
    $sga_max_size_gb+$pga_aggregate_target_gb
    " | bc)


    local allowed

    allowed=$(echo "
    $total_ram_gb*0.80
    " | bc)


    log INFO "Server RAM       : ${total_ram_gb} GB"
    log INFO "Oracle allocation: ${oracle_memory} GB"
    log INFO "Allowed limit    : ${allowed} GB"


    if (( $(echo "$oracle_memory > $allowed" | bc -l) ))
    then
        fatal "Oracle memory exceeds 80% RAM safety limit"
    fi


    log SUCCESS "Memory validation successful"
}