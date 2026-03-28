#!/bin/bash

# Export the current runtime UID for Icinga-related scripts.
ICINGA_USER="$(whoami)"
export ICINGA_USER
