#!/bin/bash

# Function to display messages with different severity levels
# Usage: icinga2_log <severity> <message>
icinga2_log() {
    local severity="$1"
    local message="$2"

    if [ "$severity" -lt "${ICINGA2_LOG_LEVEL_WEIGHT:-3}" ]; then
        return 0
    fi

    echo "[$(date +'%Y-%m-%d %H:%M:%S %z')] ${severity}/DockerEntrypoint: ${message}" >&2
}

satellite_setup() {
    local parent_ticket
    local response
    local common_name

    : "${ICINGA2_API_USER:?ICINGA2_API_USER is required when ICINGA2_PARENT_HOST is set}"
    : "${ICINGA2_API_PASSWORD:?ICINGA2_API_PASSWORD is required when ICINGA2_PARENT_HOST is set}"
    : "${ICINGA2_PARENT_IP:${ICINGA2_PARENT_HOST}}"
    : "${ICINGA2_PARENT_ZONE:=master}"
    : "${ICINGA2_PARENT_PORT:=5665}"
    : "${ICINGA2_HOST:=$(hostname -f)}"
    : "${ICINGA2_IP:=0.0.0.0}"
    : "${ICINGA2_PORT:=5665}"
    : "${ICINGA2_ZONE:=satellite}"

    common_name="$(hostname -f 2>/dev/null || hostname)"

    icinga2_log 3 "Generating PKI ticket from ${ICINGA2_PARENT_IP}:${ICINGA2_PARENT_PORT} for ${common_name}."
    response=$(curl -k -sS --fail \
        -u "${ICINGA2_API_USER}:${ICINGA2_API_PASSWORD}" \
        -H 'Accept: application/json' \
        -X POST "https://${ICINGA2_PARENT_HOST}:${ICINGA2_PARENT_PORT}/v1/actions/generate-ticket" \
        -d "{\"cn\":\"${common_name}\"}")

    parent_ticket=$(printf "%s" "$response" | sed -n 's/.*"ticket"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    if [ -z "$parent_ticket" ]; then
        icinga2_log 5 "Failed to parse generated PKI ticket from parent API response."
        icinga2_log 3 "Response was:\n$response"
        return 1
    fi

    icinga2_log 3 "Setting up Icinga2 as satellite/agent with parent ${ICINGA2_PARENT_HOST}."
    
    icinga2 pki save-cert \
        --host "${ICINGA2_PARENT_IP}" \
        --port "${ICINGA2_PARENT_PORT}" \
        --trustedcert /icinga/ca.cert \
        --log-level "${ICINGA2_LOG_LEVEL}"

    icinga2 node setup \
        --cn "${ICINGA2_HOST}" \
        --zone "${ICINGA2_ZONE}" \
        --listen "${ICINGA2_IP},${ICINGA2_PORT}" \
        --endpoint "${ICINGA2_PARENT_HOST},${ICINGA2_PARENT_IP},${ICINGA2_PARENT_PORT}" \
        --parent_host "${ICINGA2_PARENT_IP},${ICINGA2_PARENT_PORT}" \
        --parent_zone "${ICINGA2_PARENT_ZONE}" \
        --ticket "$parent_ticket" \
        --trustedcert /icinga/ca.cert \
        --accept-config \
        --accept-commands \
        --disable-confd \
        --log-level "${ICINGA2_LOG_LEVEL}"
}

create_influxdb_database() {
    local auth_header="$1"
    local db_url="$2"
    local database_name="$3"
    local retention_period="$4"
    local payload
    local code

    payload=$(cat <<EOF
{
  "db": "$database_name",
  "retention_period": "$retention_period"
}
EOF
)

    code=$(curl -s -o /dev/null -w '%{http_code}' \
      -X POST "$db_url" \
      --header "$auth_header" \
      --header "Content-Type: application/json" \
      --data "$payload")

    if [ "$code" -eq 200 ]; then
        icinga2_log 3 "InfluxDB database '$database_name' created."
    elif [ "$code" -eq 409 ]; then
        icinga2_log 3 "InfluxDB database '$database_name' already exists."
    else
        icinga2_log 5 "Failed to create InfluxDB database '$database_name'. HTTP status code: $code"
        return 1
    fi
}

write_api_user_config() {
    : "${ICINGA2_API_PASSWORD:?ICINGA2_API_PASSWORD is required when ICINGA2_API_USER is set}"
    icinga2_log 3 "Writing Icinga2 API user configuration..."
    cat > "/icinga/etc/conf.d/api-users.conf" <<EOF
object ApiUser "${ICINGA2_API_USER}" {
    password = "${ICINGA2_API_PASSWORD}"
    permissions = [ "*" ]
}
EOF
}

write_icingadb_config() {
    : "${ICINGADB_REDIS_PORT:=6379}"
    icinga2_log 3 "Writing Icinga2 Redis configuration..."
    cat > "/icinga/etc/features-available/icingadb.conf" <<EOF
object IcingaDB "icingadb" {
    host = "${ICINGADB_REDIS_HOST}"
    port = ${ICINGADB_REDIS_PORT}
}
EOF
    icinga2 feature enable icingadb \
        --log-level "${ICINGA2_LOG_LEVEL}"
}

write_influxdb_config() {
    local timeout=30
    local auth_header
    local db_url
    local resp
    local influxdb_url

    : "${ICINGA2_INFLUXDB_PORT:=8181}"
    : "${ICINGA2_INFLUXDB_DATABASE:=icinga2}"
    : "${ICINGA2_INFLUXDB_PASSWORD:?ICINGA2_INFLUXDB_PASSWORD is required when ICINGA2_INFLUXDB_HOST is set}"
    icinga2_log 3 "Writing Icinga2 InfluxDB configuration..."
    cat > "/icinga/etc/features-available/influxdb2.conf" <<EOF
object Influxdb2Writer "influxdb2" {
    host = "${ICINGA2_INFLUXDB_HOST}"
    port = "${ICINGA2_INFLUXDB_PORT}"
    organization = "monitoring"
    bucket = "${ICINGA2_INFLUXDB_DATABASE}"
    auth_token = "${ICINGA2_INFLUXDB_PASSWORD}"

    flush_threshold = 1024
    flush_interval = 10s

    host_template = {
        measurement = "\$host.check_command\$"
        tags = {
            hostname = "\$host.name\$"
            service = "\$host.check_command\$"
        }
    }
    service_template = {
        measurement = "\$service.check_command\$"
        tags = {
            hostname = "\$host.name\$"
            service = "\$service.name\$"
        }
    }
}
EOF
    icinga2 feature enable influxdb2 \
        --log-level "${ICINGA2_LOG_LEVEL}"

    influxdb_url="http://${ICINGA2_INFLUXDB_HOST}:${ICINGA2_INFLUXDB_PORT}"

    icinga2_log 3 "Setting up InfluxDB."
    while [ "$(curl -s -o /dev/null -w '%{http_code}' "${influxdb_url}/health" 2>/dev/null)" -ne 200 ]; do
        timeout=$((timeout - 1))
        if [ "$timeout" -le 0 ]; then
            icinga2_log 5 "InfluxDB not ready after timeout."
            return 1
        fi
        icinga2_log 2 "Waiting for InfluxDB to be ready at ${ICINGA2_INFLUXDB_HOST}:${ICINGA2_INFLUXDB_PORT}."
        sleep 2
    done

    icinga2_log 3 "InfluxDB is ready at ${ICINGA2_INFLUXDB_HOST}:${ICINGA2_INFLUXDB_PORT}."
    auth_header="Authorization: Bearer ${ICINGA2_INFLUXDB_PASSWORD}"
    db_url="${influxdb_url}/api/v3/configure/database"

    resp=$(curl -sSf --header "$auth_header" "$db_url?format=json")
    if [[ "$resp" == *\"iox::database\":\"${ICINGA2_INFLUXDB_DATABASE}\"* ]]; then
        icinga2_log 3 "InfluxDB database '${ICINGA2_INFLUXDB_DATABASE}' already configured."
    else
        icinga2_log 3 "Configuring InfluxDB database '${ICINGA2_INFLUXDB_DATABASE}'."
        create_influxdb_database "$auth_header" "$db_url" "${ICINGA2_INFLUXDB_DATABASE}" "7d"
        create_influxdb_database "$auth_header" "$db_url" "${ICINGA2_INFLUXDB_DATABASE}_5" "21d"
        create_influxdb_database "$auth_header" "$db_url" "${ICINGA2_INFLUXDB_DATABASE}_60" "90d"
        create_influxdb_database "$auth_header" "$db_url" "${ICINGA2_INFLUXDB_DATABASE}_1440" "1y"
        create_influxdb_database "$auth_header" "$db_url" "${ICINGA2_INFLUXDB_DATABASE}_10080" "10y"
    fi

    icinga2_log 3 "InfluxDB setup completed."
}

