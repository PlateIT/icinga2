#!/bin/bash
set -euo pipefail

source "$(dirname "$0")/../entrypoint_functions.sh"

TEST_LOG=$(mktemp)
TEST_CA_DIR=$(mktemp -d)
trap 'rm -f "$TEST_LOG"; rm -rf "$TEST_CA_DIR"' EXIT

ICINGA2_LOG_LEVEL=information
ICINGA2_LOG_LEVEL_WEIGHT=5
ICINGA2_API_USER=test-user
ICINGA2_API_PASSWORD=test-password
ICINGA2_PARENT_ENDPOINT_0_NAME=parent-0
ICINGA2_PARENT_ENDPOINT_0_ADDRESS=192.0.2.10
ICINGA2_PARENT_ENDPOINT_0_PORT=5665
ICINGA2_PARENT_ENDPOINT_1_NAME=parent-1
ICINGA2_PARENT_ENDPOINT_1_ADDRESS=192.0.2.10
ICINGA2_PARENT_ENDPOINT_1_PORT=5666
ICINGA2_PARENT_ZONE=parent
ICINGA2_CA_CERT_FILE=/test/icinga-ca.crt
ICINGA2_HOST=child-icinga-0
ICINGA2_ZONE=child

curl() {
    printf 'curl %s\n' "$*" >> "$TEST_LOG"
    case "$*" in
        *:5665/*) return 22 ;;
        *:5666/*) printf '%s\n' '{"results":[{"ticket":"ticket-from-parent-1"}]}' ;;
        *) return 22 ;;
    esac
}

openssl() {
    printf 'openssl %s\n' "$*" >> "$TEST_LOG"
}

icinga2() {
    printf 'icinga2 %s\n' "$*" >> "$TEST_LOG"
}

satellite_setup

if grep -Fq 'curl -k' "$TEST_LOG"; then
    echo 'bootstrap credentials must never be sent without certificate verification' >&2
    exit 1
fi
grep -Fq 'curl --cacert /test/icinga-ca.crt --resolve parent-0:5665:192.0.2.10 -sS --fail -u test-user:test-password' "$TEST_LOG"
grep -Fq 'https://parent-0:5665/v1/actions/generate-ticket' "$TEST_LOG"
grep -Fq 'https://parent-1:5666/v1/actions/generate-ticket' "$TEST_LOG"
grep -Fq 'openssl verify -CAfile /test/icinga-ca.crt /icinga/ca.cert' "$TEST_LOG"
grep -Fq 'icinga2 pki save-cert --host 192.0.2.10 --port 5665' "$TEST_LOG"
grep -Fq 'icinga2 pki save-cert --host 192.0.2.10 --port 5666' "$TEST_LOG"
grep -Fq -- '--endpoint parent-1,192.0.2.10,5666' "$TEST_LOG"
grep -Fq -- '--ticket ticket-from-parent-1' "$TEST_LOG"

printf '%s\n' certificate > "$TEST_CA_DIR/ca.crt"
printf '%s\n' private-key > "$TEST_CA_DIR/ca.key"
ICINGA2_CA_CERT_FILE="$TEST_CA_DIR/ca.crt"
ICINGA2_CA_KEY_FILE="$TEST_CA_DIR/ca.key"
install() {
    printf 'install %s\n' "$*" >> "$TEST_LOG"
}
satellite_setup
grep -Fq "install -m 0600 $TEST_CA_DIR/ca.key /icinga/lib/icinga2/ca/ca.key" "$TEST_LOG"
unset ICINGA2_CA_KEY_FILE
ICINGA2_CA_CERT_FILE=/test/icinga-ca.crt

if assert_icinga_name 'broken"name' TEST_NAME; then
    echo 'unsafe Icinga object name was accepted' >&2
    exit 1
fi
if assert_endpoint_address 'https://parent.example' TEST_ADDRESS; then
    echo 'endpoint URL was accepted where a DNS name or IPv4 address is required' >&2
    exit 1
fi
if assert_port 70000 TEST_PORT; then
    echo 'out-of-range endpoint port was accepted' >&2
    exit 1
fi

: > "$TEST_LOG"
curl() {
    printf 'curl %s\n' "$*" >> "$TEST_LOG"
    return 22
}

if satellite_setup; then
    echo 'bootstrap unexpectedly succeeded without an available parent' >&2
    exit 1
fi
if grep -Fq 'icinga2 node setup' "$TEST_LOG"; then
    echo 'node setup must not run without a ticket and trusted certificate' >&2
    exit 1
fi

TEST_CONFIG_DIR=$(mktemp -d)
trap 'rm -f "$TEST_LOG"; rm -rf "$TEST_CONFIG_DIR" "$TEST_CA_DIR"' EXIT
ICINGA2_CONFIG_DIR="$TEST_CONFIG_DIR"
ICINGA2_HA_ENDPOINT_0_NAME=child-icinga-0
ICINGA2_HA_ENDPOINT_0_HOST=icinga-0.icinga-headless
ICINGA2_HA_ENDPOINT_1_NAME=child-icinga-1
ICINGA2_HA_ENDPOINT_1_HOST=icinga-1.icinga-headless
write_ha_zone_config

if sed -n '/object Endpoint "child-icinga-0"/,/^}/p' "$TEST_CONFIG_DIR/zones.conf" | grep -Fq 'host ='; then
    echo 'the local endpoint must not connect to itself' >&2
    exit 1
fi
sed -n '/object Endpoint "child-icinga-1"/,/^}/p' "$TEST_CONFIG_DIR/zones.conf" | grep -Fq 'host = "icinga-1.icinga-headless"'
grep -Fq 'object Endpoint "parent-0"' "$TEST_CONFIG_DIR/zones.conf"
grep -Fq 'object Endpoint "parent-1"' "$TEST_CONFIG_DIR/zones.conf"

ICINGA2_API_USER=web-api
ICINGA2_API_PASSWORD='quote"and\backslash'
write_api_user_config
grep -Fq 'object ApiUser "web-api"' "$TEST_CONFIG_DIR/conf.d/api-users.conf"
grep -Fq 'password = "quote\"and\\backslash"' "$TEST_CONFIG_DIR/conf.d/api-users.conf"

ICINGA2_API_USER='broken"user'
if write_api_user_config; then
    echo 'unsafe API user name was accepted' >&2
    exit 1
fi
ICINGA2_API_USER=web-api
ICINGA2_API_PASSWORD=$'line1\nline2'
if write_api_user_config; then
    echo 'multiline API password was accepted' >&2
    exit 1
fi

echo 'Entrypoint HA bootstrap tests passed.'
