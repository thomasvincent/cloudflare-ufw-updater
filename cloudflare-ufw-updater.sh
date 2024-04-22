#!/bin/bash

# MIT License
#
# Copyright (c) 2022-2024 Thomas Vincent
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# This script updates the UFW rules to permit only HTTP and HTTPS traffic
# originating from Cloudflare IP addresses. For further information and
# documentation, visit:
# https://github.com/thomasvincent/cloudflare-ufw-updater/blob/master/README.md

set -euo pipefail

# Check Bash version compatibility - Mac OS X ships with 3.2.* for several releases. Use brew bash. =(
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "This script requires Bash version 4.0 or higher. You are using Bash version ${BASH_VERSION}. Please upgrade your Bash." >&2
    exit 1
fi

readonly CLOUDFLARE_IP_FILE="$(mktemp)"
readonly CLOUDFLARE_IPV4_URL="https://www.cloudflare.com/ips-v4"
readonly CLOUDFLARE_IPV6_URL="https://www.cloudflare.com/ips-v6"
readonly ALLOWED_HTTP_PORTS="80,443"
readonly CLOUDFLARE_RULE_LABEL="Cloudflare"
readonly LOG_FILE="/var/log/cloudflare-ufw-updater.log"
readonly CONFIG_FILE="/etc/cloudflare-ufw-updater.conf"
readonly BACKUP_FILE="/etc/ufw/cloudflare-ufw-updater.backup"
readonly MIN_UFW_VERSION="0.36"

# Clean up temporary files on exit
trap 'rm -f "$CLOUDFLARE_IP_FILE"' EXIT

check_dependencies() {
  local missing=0
  for cmd in ufw curl; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "Command not found in PATH: $cmd"
      missing=1
    fi
  done
  if (( missing )); then
    exit 1
  fi
}

check_permissions() {
  if (( EUID != 0 )); then
    log_error "This script must be run as root. Aborting."
    exit 1
  fi
}

check_ufw_version() {
  local ufw_version
  ufw_version="$(ufw --version | awk '{print $2}')"
  if ! version_greater_equal "$ufw_version" "$MIN_UFW_VERSION"; then
    log_error "UFW version $ufw_version is not compatible. Minimum required version is $MIN_UFW_VERSION."
    exit 1
  fi
}

version_greater_equal() {
  printf '%s\n%s' "$1" "$2" | sort -C -V
}

fetch_addresses() {
  local url="$1"
  if ! curl -s --retry 3 --retry-delay 5 "$url" >> "$CLOUDFLARE_IP_FILE"; then
    log_error "Failed to fetch addresses from $url"
    exit 1
  fi
}

update_ufw_rules() {
  # Delete existing Cloudflare rules
  ufw delete allow from any to any port "$ALLOWED_HTTP_PORTS" proto tcp comment "$CLOUDFLARE_RULE_LABEL"

  while IFS= read -r ip; do
    ufw allow from "$ip" to any port "$ALLOWED_HTTP_PORTS" proto tcp comment "$CLOUDFLARE_RULE_LABEL"
    log_message "Allowing traffic from $ip to ports $ALLOWED_HTTP_PORTS"
  done < "$CLOUDFLARE_IP_FILE"
}

log_message() {
  printf "%s - %s\n" "$(date +"%Y-%m-%d %H:%M:%S")" "$1" | tee -a "$LOG_FILE"
}

log_error() {
  printf "%s - [ERROR] %s\n" "$(date +"%Y-%m-%d %H:%M:%S")" "$1" | tee -a "$LOG_FILE" >&2
}

load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck source=/etc/cloudflare-ufw-updater.conf
    source "$CONFIG_FILE"
  fi

  # Override config values with environment variables if set
  CLOUDFLARE_IPV4_URL="${CLOUDFLARE_IPV4_URL:-$CLOUDFLARE_IPV4_URL}"
  CLOUDFLARE_IPV6_URL="${CLOUDFLARE_IPV6_URL:-$CLOUDFLARE_IPV6_URL}"
  ALLOWED_HTTP_PORTS="${ALLOWED_HTTP_PORTS:-$ALLOWED_HTTP_PORTS}"
  CLOUDFLARE_RULE_LABEL="${CLOUDFLARE_RULE_LABEL:-$CLOUDFLARE_RULE_LABEL}"
  LOG_FILE="${LOG_FILE:-$LOG_FILE}"
  BACKUP_FILE="${BACKUP_FILE:-$BACKUP_FILE}"
}

backup_ufw_rules() {
  ufw status numbered | tee "$BACKUP_FILE"
  log_message "Backed up UFW rules to $BACKUP_FILE"
}

restore_ufw_rules() {
  if [[ -f "$BACKUP_FILE" ]]; then
    ufw reset 1>/dev/null
    while read -r rule; do
      # Skip comment lines
      if [[ $rule =~ ^\s*# ]]; then
        continue
      fi
      ufw "$rule"
    done < "$BACKUP_FILE"
    log_message "Restored UFW rules from $BACKUP_FILE"
  else
    log_error "Backup file not found: $BACKUP_FILE"
  fi
}

main() {
  check_dependencies
  check_permissions
  check_ufw_version
  load_config

  if [[ "$1" == "--restore" ]]; then
    restore_ufw_rules
    exit 0
  fi

  log_message "Starting Cloudflare UFW Updater"

  log_message "Fetching Cloudflare IP addresses..."
  fetch_addresses "$CLOUDFLARE_IPV4_URL"
  fetch_addresses "$CLOUDFLARE_IPV6_URL"

  backup_ufw_rules

  log_message "Updating UFW rules..."
  update_ufw_rules

  log_message "Reloading UFW..."
  ufw reload

  log_message "UFW rules updated successfully."
}

main "$@"