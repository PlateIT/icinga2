#!/bin/bash

# Export the current runtime UID for Icinga-related scripts.
ICINGA2_USER="$(whoami)"
export ICINGA2_USER