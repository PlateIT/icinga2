#!/bin/bash

icinga2_log() {
    local severity="$1"
    local message="$2"

    if [ "$severity" -lt "${ICINGA2_LOG_LEVEL_WEIGHT:-3}" ]; then
        return 0
    fi

    echo "[$(date +'%Y-%m-%d %H:%M:%S %z')] ${severity}/DockerEntrypoint: ${message}" >&2
}

assert_icinga_name() {
    case "$1" in
        ''|*[!A-Za-z0-9_.-]*)
            icinga2_log 5 "$2 contains characters that are unsafe for Icinga configuration."
            return 1
            ;;
    esac
}

assert_endpoint_address() {
    case "$1" in
        ''|*[!A-Za-z0-9.-]*)
            icinga2_log 5 "$2 is not a valid DNS name or IPv4 address."
            return 1
            ;;
    esac
}

assert_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ] || {
        icinga2_log 5 "$2 must be between 1 and 65535."
        return 1
    }
}

icinga_string_literal() {
    local value="$1"
    case "$value" in
        *$'\n'*|*$'\r'*)
            icinga2_log 5 "$2 must not contain line breaks."
            return 1
            ;;
    esac
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

bootstrap_from_parent() {
    local parent_name
    local parent_address
    local parent_port
    local response
    local common_name

    parent_name="$1"
    parent_address="$2"
    parent_port="$3"
    common_name="$4"

    : "${ICINGA2_CA_CERT_FILE:?ICINGA2_CA_CERT_FILE is required for parent certificate verification}"

    icinga2_log 3 "Saving the certificate from parent ${parent_name} at ${parent_address}:${parent_port}."
    if ! icinga2 pki save-cert \
        --host "${parent_address}" \
        --port "${parent_port}" \
        --trustedcert /icinga/ca.cert \
        --log-level "${ICINGA2_LOG_LEVEL}"; then
        icinga2_log 4 "Could not save the trusted certificate from parent ${parent_name}."
        return 1
    fi

    if ! openssl verify -CAfile "$ICINGA2_CA_CERT_FILE" /icinga/ca.cert >/dev/null; then
        icinga2_log 4 "Parent ${parent_name} presented a certificate outside the configured Icinga CA."
        return 1
    fi

    icinga2_log 3 "Requesting a PKI ticket from parent ${parent_name} at ${parent_address}:${parent_port}."
    if ! response=$(curl --cacert "$ICINGA2_CA_CERT_FILE" \
        --resolve "${parent_name}:${parent_port}:${parent_address}" \
        -sS --fail \
        -u "${ICINGA2_API_USER}:${ICINGA2_API_PASSWORD}" \
        -H 'Accept: application/json' \
        -X POST "https://${parent_name}:${parent_port}/v1/actions/generate-ticket" \
        -d "{\"cn\":\"${common_name}\"}"); then
        icinga2_log 4 "Parent ${parent_name} did not issue a PKI ticket."
        return 1
    fi

    BOOTSTRAP_PARENT_TICKET=$(printf "%s" "$response" | sed -n 's/.*"ticket"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    if [ -z "$BOOTSTRAP_PARENT_TICKET" ]; then
        icinga2_log 4 "Parent ${parent_name} returned no usable PKI ticket."
        return 1
    fi

    BOOTSTRAP_PARENT_NAME="$parent_name"
    BOOTSTRAP_PARENT_ADDRESS="$parent_address"
    BOOTSTRAP_PARENT_PORT="$parent_port"
}

satellite_setup() {
    local common_name

    : "${ICINGA2_API_USER:?ICINGA2_API_USER is required when a parent endpoint is set}"
    : "${ICINGA2_API_PASSWORD:?ICINGA2_API_PASSWORD is required when a parent endpoint is set}"
    : "${ICINGA2_PARENT_ENDPOINT_0_NAME:?ICINGA2_PARENT_ENDPOINT_0_NAME is required}"
    : "${ICINGA2_PARENT_ENDPOINT_0_ADDRESS:?ICINGA2_PARENT_ENDPOINT_0_ADDRESS is required}"
    : "${ICINGA2_PARENT_ENDPOINT_0_PORT:?ICINGA2_PARENT_ENDPOINT_0_PORT is required}"
    : "${ICINGA2_PARENT_ENDPOINT_1_NAME:?ICINGA2_PARENT_ENDPOINT_1_NAME is required}"
    : "${ICINGA2_PARENT_ENDPOINT_1_ADDRESS:?ICINGA2_PARENT_ENDPOINT_1_ADDRESS is required}"
    : "${ICINGA2_PARENT_ENDPOINT_1_PORT:?ICINGA2_PARENT_ENDPOINT_1_PORT is required}"
    : "${ICINGA2_PARENT_ZONE:?ICINGA2_PARENT_ZONE is required}"
    : "${ICINGA2_HOST:?ICINGA2_HOST is required}"
    : "${ICINGA2_IP:=0.0.0.0}"
    : "${ICINGA2_PORT:=5665}"
    : "${ICINGA2_ZONE:?ICINGA2_ZONE is required}"

    assert_icinga_name "$ICINGA2_HOST" ICINGA2_HOST
    assert_icinga_name "$ICINGA2_ZONE" ICINGA2_ZONE
    assert_icinga_name "$ICINGA2_PARENT_ZONE" ICINGA2_PARENT_ZONE
    assert_icinga_name "$ICINGA2_PARENT_ENDPOINT_0_NAME" ICINGA2_PARENT_ENDPOINT_0_NAME
    assert_icinga_name "$ICINGA2_PARENT_ENDPOINT_1_NAME" ICINGA2_PARENT_ENDPOINT_1_NAME
    assert_endpoint_address "$ICINGA2_PARENT_ENDPOINT_0_ADDRESS" ICINGA2_PARENT_ENDPOINT_0_ADDRESS
    assert_endpoint_address "$ICINGA2_PARENT_ENDPOINT_1_ADDRESS" ICINGA2_PARENT_ENDPOINT_1_ADDRESS
    assert_port "$ICINGA2_PARENT_ENDPOINT_0_PORT" ICINGA2_PARENT_ENDPOINT_0_PORT
    assert_port "$ICINGA2_PARENT_ENDPOINT_1_PORT" ICINGA2_PARENT_ENDPOINT_1_PORT

    common_name="${ICINGA2_HOST}"

    if bootstrap_from_parent \
        "$ICINGA2_PARENT_ENDPOINT_0_NAME" \
        "$ICINGA2_PARENT_ENDPOINT_0_ADDRESS" \
        "$ICINGA2_PARENT_ENDPOINT_0_PORT" \
        "$common_name"; then
        :
    elif bootstrap_from_parent \
        "$ICINGA2_PARENT_ENDPOINT_1_NAME" \
        "$ICINGA2_PARENT_ENDPOINT_1_ADDRESS" \
        "$ICINGA2_PARENT_ENDPOINT_1_PORT" \
        "$common_name"; then
        :
    else
        icinga2_log 5 "Neither configured parent endpoint was available for the initial PKI bootstrap."
        return 1
    fi

    icinga2_log 3 "Setting up Icinga2 as satellite/agent with parent ${BOOTSTRAP_PARENT_NAME}."

    icinga2 node setup \
        --cn "${ICINGA2_HOST}" \
        --zone "${ICINGA2_ZONE}" \
        --listen "${ICINGA2_IP},${ICINGA2_PORT}" \
        --endpoint "${BOOTSTRAP_PARENT_NAME},${BOOTSTRAP_PARENT_ADDRESS},${BOOTSTRAP_PARENT_PORT}" \
        --parent_host "${BOOTSTRAP_PARENT_ADDRESS},${BOOTSTRAP_PARENT_PORT}" \
        --parent_zone "${ICINGA2_PARENT_ZONE}" \
        --ticket "$BOOTSTRAP_PARENT_TICKET" \
        --trustedcert /icinga/ca.cert \
        --accept-config \
        --accept-commands \
        --disable-confd \
        --log-level "${ICINGA2_LOG_LEVEL}"

    # A satellite master is itself bootstrapped by its parent, but must also
    # be able to issue tickets for its own direct children. Supplying the CA
    # key explicitly promotes only that control-plane role to a signing node.
    if [ -n "${ICINGA2_CA_KEY_FILE:-}" ]; then
        install_shared_ca
    fi
}

install_shared_ca() {
    : "${ICINGA2_CA_CERT_FILE:?ICINGA2_CA_CERT_FILE is required for a master HA zone}"
    : "${ICINGA2_CA_KEY_FILE:?ICINGA2_CA_KEY_FILE is required for a master HA zone}"
    if [ ! -s "$ICINGA2_CA_CERT_FILE" ] || [ ! -s "$ICINGA2_CA_KEY_FILE" ]; then
        icinga2_log 5 "The configured shared CA certificate or key is empty."
        return 1
    fi
    install -d -m 0700 /icinga/lib/icinga2/ca
    install -m 0644 "$ICINGA2_CA_CERT_FILE" /icinga/lib/icinga2/ca/ca.crt
    install -m 0600 "$ICINGA2_CA_KEY_FILE" /icinga/lib/icinga2/ca/ca.key
}

write_ha_zone_config() {
    local config_dir

    : "${ICINGA2_ZONE:?ICINGA2_ZONE is required for HA}"
    : "${ICINGA2_HA_ENDPOINT_0_NAME:?ICINGA2_HA_ENDPOINT_0_NAME is required}"
    : "${ICINGA2_HA_ENDPOINT_0_HOST:?ICINGA2_HA_ENDPOINT_0_HOST is required}"
    : "${ICINGA2_HA_ENDPOINT_1_NAME:?ICINGA2_HA_ENDPOINT_1_NAME is required}"
    : "${ICINGA2_HA_ENDPOINT_1_HOST:?ICINGA2_HA_ENDPOINT_1_HOST is required}"
    : "${ICINGA2_HOST:?ICINGA2_HOST is required for HA}"

    assert_icinga_name "$ICINGA2_ZONE" ICINGA2_ZONE
    assert_icinga_name "$ICINGA2_HOST" ICINGA2_HOST
    assert_icinga_name "$ICINGA2_HA_ENDPOINT_0_NAME" ICINGA2_HA_ENDPOINT_0_NAME
    assert_icinga_name "$ICINGA2_HA_ENDPOINT_1_NAME" ICINGA2_HA_ENDPOINT_1_NAME
    assert_endpoint_address "$ICINGA2_HA_ENDPOINT_0_HOST" ICINGA2_HA_ENDPOINT_0_HOST
    assert_endpoint_address "$ICINGA2_HA_ENDPOINT_1_HOST" ICINGA2_HA_ENDPOINT_1_HOST
    assert_port "${ICINGA2_PORT:-5665}" ICINGA2_PORT

    config_dir="${ICINGA2_CONFIG_DIR:-/icinga/etc}"
    install -d "$config_dir"

    cat > "$config_dir/zones.conf" <<EOF
object Endpoint "${ICINGA2_HA_ENDPOINT_0_NAME}" {
EOF
    if [ "$ICINGA2_HOST" != "$ICINGA2_HA_ENDPOINT_0_NAME" ]; then
        cat >> "$config_dir/zones.conf" <<EOF
    host = "${ICINGA2_HA_ENDPOINT_0_HOST}"
    port = ${ICINGA2_PORT:-5665}
EOF
    fi
    cat >> "$config_dir/zones.conf" <<EOF
}
object Endpoint "${ICINGA2_HA_ENDPOINT_1_NAME}" {
EOF
    if [ "$ICINGA2_HOST" != "$ICINGA2_HA_ENDPOINT_1_NAME" ]; then
        cat >> "$config_dir/zones.conf" <<EOF
    host = "${ICINGA2_HA_ENDPOINT_1_HOST}"
    port = ${ICINGA2_PORT:-5665}
EOF
    fi
    cat >> "$config_dir/zones.conf" <<EOF
}
object Zone "${ICINGA2_ZONE}" {
    endpoints = [ "${ICINGA2_HA_ENDPOINT_0_NAME}", "${ICINGA2_HA_ENDPOINT_1_NAME}" ]
}
object Zone "global-templates" {
    global = true
}
object Zone "director-global" {
    global = true
}
EOF

    if [ -n "${ICINGA2_PARENT_ENDPOINT_0_NAME:-}" ]; then
        : "${ICINGA2_PARENT_ZONE:?ICINGA2_PARENT_ZONE is required for a satellite HA zone}"
        : "${ICINGA2_PARENT_ENDPOINT_1_NAME:?ICINGA2_PARENT_ENDPOINT_1_NAME is required}"
        : "${ICINGA2_PARENT_ENDPOINT_1_ADDRESS:?ICINGA2_PARENT_ENDPOINT_1_ADDRESS is required}"
        : "${ICINGA2_PARENT_ENDPOINT_1_PORT:?ICINGA2_PARENT_ENDPOINT_1_PORT is required}"
        assert_icinga_name "$ICINGA2_PARENT_ZONE" ICINGA2_PARENT_ZONE
        assert_icinga_name "$ICINGA2_PARENT_ENDPOINT_0_NAME" ICINGA2_PARENT_ENDPOINT_0_NAME
        assert_icinga_name "$ICINGA2_PARENT_ENDPOINT_1_NAME" ICINGA2_PARENT_ENDPOINT_1_NAME
        assert_endpoint_address "$ICINGA2_PARENT_ENDPOINT_0_ADDRESS" ICINGA2_PARENT_ENDPOINT_0_ADDRESS
        assert_endpoint_address "$ICINGA2_PARENT_ENDPOINT_1_ADDRESS" ICINGA2_PARENT_ENDPOINT_1_ADDRESS
        assert_port "$ICINGA2_PARENT_ENDPOINT_0_PORT" ICINGA2_PARENT_ENDPOINT_0_PORT
        assert_port "$ICINGA2_PARENT_ENDPOINT_1_PORT" ICINGA2_PARENT_ENDPOINT_1_PORT
        cat >> "$config_dir/zones.conf" <<EOF
object Endpoint "${ICINGA2_PARENT_ENDPOINT_0_NAME}" {
    host = "${ICINGA2_PARENT_ENDPOINT_0_ADDRESS}"
    port = ${ICINGA2_PARENT_ENDPOINT_0_PORT}
}
object Endpoint "${ICINGA2_PARENT_ENDPOINT_1_NAME}" {
    host = "${ICINGA2_PARENT_ENDPOINT_1_ADDRESS}"
    port = ${ICINGA2_PARENT_ENDPOINT_1_PORT}
}
object Zone "${ICINGA2_PARENT_ZONE}" {
    endpoints = [ "${ICINGA2_PARENT_ENDPOINT_0_NAME}", "${ICINGA2_PARENT_ENDPOINT_1_NAME}" ]
}
EOF
    fi
}

write_api_user_config() {
    : "${ICINGA2_API_PASSWORD:?ICINGA2_API_PASSWORD is required when ICINGA2_API_USER is set}"
    local config_dir="${ICINGA2_CONFIG_DIR:-/icinga/etc}"
    local escaped_password
    assert_icinga_name "$ICINGA2_API_USER" ICINGA2_API_USER || return 1
    escaped_password="$(icinga_string_literal "$ICINGA2_API_PASSWORD" ICINGA2_API_PASSWORD)" || return 1
    icinga2_log 3 "Writing Icinga2 API user configuration..."
    mkdir -p "$config_dir/conf.d"
    cat > "$config_dir/conf.d/api-users.conf" <<EOF
object ApiUser "${ICINGA2_API_USER}" {
    password = "${escaped_password}"
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
    icinga2 feature enable icingadb --log-level "${ICINGA2_LOG_LEVEL}"
}
