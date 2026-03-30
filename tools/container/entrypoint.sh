#!/bin/bash
set -eo pipefail

: "${ICINGA_LOG_LEVEL:=information}"

case "$ICINGA_LOG_LEVEL" in
    debug)
        ICINGA_LOG_LEVEL_WEIGHT=1
        ;;
    notice)
        ICINGA_LOG_LEVEL_WEIGHT=2
        ;;
    information)
        ICINGA_LOG_LEVEL_WEIGHT=3
        ;;
    warning)
        ICINGA_LOG_LEVEL_WEIGHT=4
        ;;
    critical)
        ICINGA_LOG_LEVEL_WEIGHT=5
        ;;
    *)
        ICINGA_LOG_LEVEL_WEIGHT=3
        ;;
esac

source /usr/libexec/icinga2-container-functions.sh

icinga2_log 3 "Icinga 2 Docker entrypoint script started."

if [ ! -f "/icinga/setup.done" ]; then
    cp -a /icinga-init/. /icinga/
    if [ -n "${ICINGA_PARENT_HOST:-}" ]; then
        satellite_setup
    else
        icinga2_log 3 "Setting up Icinga2 as master node."
        icinga2 node setup --master --accept-config --accept-commands --disable-confd
    fi
    icinga2 feature disable mainlog notification
    touch /icinga/setup.done
fi

if [ -n "${ICINGA2_API_USER:-}" ]; then
    write_api_user_config
fi

if [ -n "${ICINGADB_REDIS_HOST:-}" ]; then
    write_icingadb_config
fi

if [ -n "${ICINGA2_INFLUXDB_HOST:-}" ]; then
    write_influxdb_config
fi


icinga2_log 3 "Starting Icinga2 daemon..."
exec icinga2 daemon --log-level "$ICINGA_LOG_LEVEL"