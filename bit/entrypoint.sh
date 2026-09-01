#!/bin/bash
set -eo pipefail

: "${ICINGA2_LOG_LEVEL:=information}"

case "$ICINGA2_LOG_LEVEL" in
    debug) ICINGA2_LOG_LEVEL_WEIGHT=1 ;;
    notice) ICINGA2_LOG_LEVEL_WEIGHT=2 ;;
    information) ICINGA2_LOG_LEVEL_WEIGHT=3 ;;
    warning) ICINGA2_LOG_LEVEL_WEIGHT=4 ;;
    critical) ICINGA2_LOG_LEVEL_WEIGHT=5 ;;
    *) ICINGA2_LOG_LEVEL_WEIGHT=3 ;;
esac

source /usr/libexec/icinga2-container-functions.sh

icinga2_log 3 "Icinga 2 Docker entrypoint script started."

# The first StatefulSet ordinal is the deterministic CA signer. A second
# member of a root HA zone joins it exactly like any other trusted endpoint;
# it must never create an independent root CA.
if [ "${ICINGA2_ROOT_ZONE:-false}" = "true" ]; then
    case "${ICINGA2_POD_NAME:-}" in
        *-0)
            ICINGA2_CA_SIGNER=true
            ;;
        *)
            ICINGA2_CA_SIGNER=false
            : "${ICINGA2_CA_PRIMARY_NAME:?ICINGA2_CA_PRIMARY_NAME is required}"
            : "${ICINGA2_CA_PRIMARY_ADDRESS:?ICINGA2_CA_PRIMARY_ADDRESS is required}"
            ICINGA2_PARENT_ENDPOINT_0_NAME="$ICINGA2_CA_PRIMARY_NAME"
            ICINGA2_PARENT_ENDPOINT_0_ADDRESS="$ICINGA2_CA_PRIMARY_ADDRESS"
            ICINGA2_PARENT_ENDPOINT_0_PORT="${ICINGA2_CA_PRIMARY_PORT:-5665}"
            ICINGA2_PARENT_ENDPOINT_1_NAME="$ICINGA2_CA_PRIMARY_NAME"
            ICINGA2_PARENT_ENDPOINT_1_ADDRESS="$ICINGA2_CA_PRIMARY_ADDRESS"
            ICINGA2_PARENT_ENDPOINT_1_PORT="${ICINGA2_CA_PRIMARY_PORT:-5665}"
            ICINGA2_PARENT_ZONE="$ICINGA2_ZONE"
            ;;
    esac
fi

if [ ! -f "/icinga/setup.done" ]; then
    cp -r /icinga-init/. /icinga/
    if [ "${ICINGA2_CA_MODE:-internal}" = "intermediate" ] && [ "${ICINGA2_CA_SIGNER:-false}" = "true" ]; then
        install_managed_intermediate
    fi
    if [ -n "${ICINGA2_PARENT_ENDPOINT_0_NAME:-}" ]; then
        satellite_setup
        if [ "${ICINGA2_ROOT_ZONE:-false}" = "true" ]; then
            unset ICINGA2_PARENT_ENDPOINT_0_NAME ICINGA2_PARENT_ENDPOINT_0_ADDRESS ICINGA2_PARENT_ENDPOINT_0_PORT
            unset ICINGA2_PARENT_ENDPOINT_1_NAME ICINGA2_PARENT_ENDPOINT_1_ADDRESS ICINGA2_PARENT_ENDPOINT_1_PORT
            unset ICINGA2_PARENT_ZONE
        fi
    else
        : "${ICINGA2_HOST:?ICINGA2_HOST is required}"
        : "${ICINGA2_ZONE:?ICINGA2_ZONE is required}"
        icinga2_log 3 "Setting up Icinga2 as master node."
        icinga2 node setup \
            --master \
            --cn "${ICINGA2_HOST}" \
            --zone "${ICINGA2_ZONE}" \
            --listen "${ICINGA2_IP:=0.0.0.0},${ICINGA2_PORT:=5665}" \
            --accept-config \
            --accept-commands \
            --disable-confd \
            --log-level "${ICINGA2_LOG_LEVEL}"
    fi

    icinga2 feature disable \
        mainlog \
        notification \
        --log-level "${ICINGA2_LOG_LEVEL}"

    touch /icinga/setup.done
fi

# Parent variables on root ordinal 1 are bootstrap-only. The final zone
# configuration contains both local HA endpoints and no parent zone.
if [ "${ICINGA2_ROOT_ZONE:-false}" = "true" ] && [ "${ICINGA2_CA_SIGNER:-false}" != "true" ]; then
    unset ICINGA2_PARENT_ENDPOINT_0_NAME ICINGA2_PARENT_ENDPOINT_0_ADDRESS ICINGA2_PARENT_ENDPOINT_0_PORT
    unset ICINGA2_PARENT_ENDPOINT_1_NAME ICINGA2_PARENT_ENDPOINT_1_ADDRESS ICINGA2_PARENT_ENDPOINT_1_PORT
    unset ICINGA2_PARENT_ZONE
fi

# A corporate intermediate is reconciled on signer restart. Existing leaf
# certificates remain valid and renew naturally against the new signer.
if [ "${ICINGA2_CA_MODE:-internal}" = "intermediate" ] && [ "${ICINGA2_CA_SIGNER:-false}" = "true" ]; then
    install_managed_intermediate
fi

if [ "${ICINGA2_HA_ENABLED:-false}" = "true" ]; then
    write_ha_zone_config
fi

if [ -n "${ICINGA2_API_USER:-}" ]; then
    write_api_user_config
fi

if [ -n "${ICINGADB_REDIS_HOST:-}" ]; then
    write_icingadb_config
fi

icinga2_log 3 "Starting Icinga2 daemon..."
exec icinga2 daemon --log-level "$ICINGA2_LOG_LEVEL"
