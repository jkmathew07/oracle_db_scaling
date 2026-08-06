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
###############################################################################
# Database status checks
###############################################################################

get_db_status()
{
    run_sql "select status from v\$instance;" 2>/dev/null | xargs
}


###############################################################################
# Confirm execution
###############################################################################

confirm_execution()
{

    echo
    echo "====================================================="
    echo " Oracle Memory Reconfiguration Summary"
    echo "====================================================="
    echo "Instance              : ${oracle_instance}"
    echo "Oracle Home            : ${oracle_home}"
    echo "SGA Max Size           : ${sga_max_size_gb} GB"
    echo "SGA Target             : ${sga_target_gb} GB"
    echo "PGA Target             : ${pga_aggregate_target_gb} GB"
    echo "PGA Limit              : ${pga_aggregate_limit_gb} GB"
    echo "Processes              : ${processes}"
    echo "====================================================="
    echo


    read -r -p "Continue? (Y/N): " answer


    if [[ ! "$answer" =~ ^[Yy]$ ]]
    then
        fatal "User cancelled execution"
    fi

}



###############################################################################
# Start database in mount mode
###############################################################################

startup_mount()
{

    log INFO "Checking database state"


    local status

    status=$(get_db_status)


    case "$status" in

        OPEN)

            log INFO "Database OPEN. Performing clean shutdown"

            run_sql "shutdown immediate;" ||
                fatal "Shutdown failed"

            ;;


        MOUNTED)

            log INFO "Database already mounted"

            return
            ;;


        "")

            log INFO "Database down"

            ;;


        *)

            fatal "Unexpected database state: $status"

            ;;

    esac



    log INFO "Starting database MOUNT"


    run_sql "startup mount;" ||
        fatal "Startup mount failed"


    log SUCCESS "Database mounted"

}



###############################################################################
# Detect SPFILE location and create PFILE backup
###############################################################################

backup_spfile()
{

    log INFO "Creating SPFILE backup"


    local spfile


    spfile=$(run_sql "
    select value
    from v\$parameter
    where name='spfile';
    " | xargs)


    local backup_dir="/tmp/oracle_spfile_backup"

    mkdir -p "$backup_dir"


    PFILE_BACKUP="${backup_dir}/init${ORACLE_SID}_$(date +%Y%m%d_%H%M%S).ora"



    run_sql "
    create pfile='${PFILE_BACKUP}'
    from spfile;
    " || fatal "Unable to create PFILE backup"



    [[ -f "$PFILE_BACKUP" ]] ||
        fatal "PFILE backup not created"



    log SUCCESS "PFILE backup created:"
    log INFO "$PFILE_BACKUP"


}



###############################################################################
# Parameter comparison
###############################################################################

check_parameter()
{

    local name="$1"
    local current="$2"
    local target="$3"


    local diff


    diff=$(echo "
    scale=4;
    (($current-$target)/$target)*100
    " | bc)


    local abs


    abs=$(echo "
    if ($diff < 0)
        -$diff
    else
        $diff
    " | bc)



    if (( $(echo "$abs <= 2" | bc) ))
    then
        log INFO "$name OK Current=$current Target=$target"
        return 0
    else
        log WARN "$name mismatch Current=$current Target=$target"
        return 1
    fi

}



validate_current_configuration()
{

    log INFO "Checking current database parameters"


    local failed=0


    local sga_max
    local sga_target
    local pga_target
    local pga_limit
    local proc


    sga_max=$(run_sql "
    select value/1024/1024/1024
    from v\$parameter
    where name='sga_max_size';
    " | xargs)


    sga_target=$(run_sql "
    select value/1024/1024/1024
    from v\$parameter
    where name='sga_target';
    " | xargs)



    pga_target=$(run_sql "
    select value/1024/1024/1024
    from v\$parameter
    where name='pga_aggregate_target';
    " | xargs)



    pga_limit=$(run_sql "
    select value/1024/1024/1024
    from v\$parameter
    where name='pga_aggregate_limit';
    " | xargs)



    proc=$(run_sql "
    select value
    from v\$parameter
    where name='processes';
    " | xargs)



    check_parameter \
        sga_max_size \
        "$sga_max" \
        "$sga_max_size_gb" || failed=1



    check_parameter \
        sga_target \
        "$sga_target" \
        "$sga_target_gb" || failed=1



    check_parameter \
        pga_aggregate_target \
        "$pga_target" \
        "$pga_aggregate_target_gb" || failed=1



    check_parameter \
        pga_aggregate_limit \
        "$pga_limit" \
        "$pga_aggregate_limit_gb" || failed=1



    if [[ "$proc" != "$processes" ]]
    then
        failed=1
        log WARN "Processes mismatch Current=$proc Target=$processes"
    fi



    return $failed

}



###############################################################################
# Apply new parameters
###############################################################################

apply_parameters()
{

    log INFO "Applying SPFILE changes"


    local sga_max_bytes
    local sga_target_bytes
    local pga_target_bytes
    local pga_limit_bytes



    sga_max_bytes=$(echo "$sga_max_size_gb*1024*1024*1024" | bc)

    sga_target_bytes=$(echo "$sga_target_gb*1024*1024*1024" | bc)

    pga_target_bytes=$(echo "$pga_aggregate_target_gb*1024*1024*1024" | bc)

    pga_limit_bytes=$(echo "$pga_aggregate_limit_gb*1024*1024*1024" | bc)



    run_sql "
    alter system set sga_max_size=${sga_max_bytes} scope=spfile;

    alter system set sga_target=${sga_target_bytes} scope=spfile;

    alter system set pga_aggregate_target=${pga_target_bytes} scope=spfile;

    alter system set pga_aggregate_limit=${pga_limit_bytes} scope=spfile;

    alter system set processes=${processes} scope=spfile;
    " || fatal "SPFILE update failed"



    log SUCCESS "SPFILE updated"


}
###############################################################################
# Restart database and validate
###############################################################################

restart_database()
{

    log INFO "Restarting database to activate SPFILE parameters"


    run_sql "shutdown immediate;" ||
        fatal "Database shutdown failed"


    run_sql "startup mount;" ||
        fatal "Database startup mount failed"


    log INFO "Validating new parameters"


    if ! validate_current_configuration
    then
        fatal "Post restart validation failed"
    fi


    log SUCCESS "Memory parameters validated successfully"

}



###############################################################################
# Data Guard detection and database open
###############################################################################

open_database()
{

    log INFO "Checking database role"


    local role


    role=$(run_sql "
    select database_role
    from v\$database;
    " | xargs)



    case "$role" in


        PRIMARY)

            log INFO "Primary database detected"

            run_sql "
            alter database open;
            " ||
            fatal "Unable to open primary database"


            ;;


        PHYSICAL\ STANDBY)

            log INFO "Physical standby detected"


            run_sql "
            alter database recover managed standby database using current logfile disconnect;
            " ||
            log WARN "Managed recovery may already be running"


            ;;


        *)

            log WARN "Unknown role ${role}"

            run_sql "
            alter database open;
            " ||
            fatal "Unable to open database"


            ;;

    esac



    log SUCCESS "Database role processing completed"

}




###############################################################################
# Final validation
###############################################################################

final_validation()
{

    log INFO "Performing final database validation"


    local status


    status=$(get_db_status)


    if [[ "$status" != "OPEN" && "$status" != "MOUNTED" ]]
    then
        fatal "Database validation failed. Status=${status}"
    fi



    log INFO "Final parameter values"


    run_sql "
    column name format a30

    select name,
           value
    from v\$parameter
    where name in
    (
       'sga_max_size',
       'sga_target',
       'pga_aggregate_target',
       'pga_aggregate_limit',
       'processes'
    );

    "



    log SUCCESS "Validation completed"

}



###############################################################################
# Main workflow
###############################################################################

main()
{

    log INFO "Oracle memory reconfiguration started"



    load_params


    setup_environment


    validate_hugepages


    validate_memory


    confirm_execution



    startup_mount



    backup_spfile



    if validate_current_configuration
    then

        log INFO "Current configuration already matches target"

        open_database

        final_validation

        exit 0

    fi



    apply_parameters


    restart_database



    open_database



    final_validation



    RECONFIGURED=1



    echo
    echo "====================================================="
    echo " Reconfiguration completed"
    echo "====================================================="
    echo
    echo "Rollback available:"
    echo
    echo "./rollback_oracle.sh ${PFILE_BACKUP}"
    echo
    echo "====================================================="


    log SUCCESS "Oracle memory reconfiguration completed successfully"

}



main "$@"