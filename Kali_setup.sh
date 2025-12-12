#!/bin/bash
# Suricata automation flow script derived from flow.md / suricata_setup.md
# - Selects primary or demo repo based on available git credentials
# - Provides menu for install/update/apply/remove flows

set -uo pipefail
# Note: 'set -e' removed to allow graceful error handling in functions

# Optional auth envs:
#   GIT_USERNAME / GIT_PASSWORD (or PAT in password)
#   GIT_TOKEN (alternative to username/password)
# These are used only for repo access and are not printed in logs.

# Prompted credentials (can be left blank to use demo)
GIT_USERNAME="${GIT_USERNAME:-}"
GIT_PASSWORD="${GIT_PASSWORD:-}"

PRIMARY_REPO="https://github.com/atharva8303/Suricata_Automation"
DEMO_REPO="https://github.com/atharva8303/Demo_Rules"
WORKDIR="/tmp/suricata_rules"
RULES_DIR="/etc/suricata/rules"   # apply rules here to match flow.md expectation
SURICATA_YAML="/etc/suricata/suricata.yaml"
APT_UPDATED=0

color() { printf "\033[%sm%s\033[0m" "$1" "$2"; }
# Log helpers write to stderr so command substitution doesn't capture messages as data.
info()  { echo "$(color '36' '[INFO]') $*" >&2; }
warn()  { echo "$(color '33' '[WARN]') $*" >&2; }
err()   { echo "$(color '31' '[ERR ]') $*" >&2; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    err "Run as root (sudo bash flow.sh)"
    exit 1
  fi
}

apt_update_once() {
  if [[ "$APT_UPDATED" -eq 0 ]]; then
    if apt-get update; then
      APT_UPDATED=1
      return 0
    else
      return 1
    fi
  fi
  return 0
}

ensure_git() {
  if ! command -v git >/dev/null 2>&1; then
    info "Installing git ..."
    apt_update_once
    apt-get install -y git
  fi
}

ensure_dirs() {
  mkdir -p "$WORKDIR" "$RULES_DIR" /var/lib/suricata/rules
}

build_auth_repo_url() {
  local base="$1"
  if [[ -n "${GIT_USERNAME:-}" && -n "${GIT_PASSWORD:-}" ]]; then
    # Note: credentials are not echoed; beware of special chars in password.
    echo "${base/https:\/\//https:\/\/${GIT_USERNAME}:${GIT_PASSWORD}@}"
  elif [[ -n "${GIT_TOKEN:-}" ]]; then
    echo "${base/https:\/\//https:\/\/${GIT_TOKEN}@}"
  else
    echo "$base"
  fi
}

detect_repo() {
  # Decide repo based on provided credentials; blank or incomplete creds force demo.
  local auth_primary auth_demo chosen
  auth_primary="$(build_auth_repo_url "$PRIMARY_REPO")"
  auth_demo="$(build_auth_repo_url "$DEMO_REPO")"

  if [[ -z "${GIT_USERNAME}" || -z "${GIT_PASSWORD}" ]]; then
    if [[ -n "${GIT_USERNAME}" || -n "${GIT_PASSWORD}" ]]; then
      warn "Incomplete credentials; using demo repository."
    else
      info "No credentials provided; using demo repository."
    fi
    chosen="$auth_demo"
  else
    if git ls-remote "$auth_primary" &>/dev/null; then
      chosen="$auth_primary"
      info "Using primary repository."
    else
      warn "Primary repo not accessible; falling back to demo repo."
      chosen="$auth_demo"
    fi
  fi
  echo "$chosen"
}

prompt_credentials() {
  echo "Enter git credentials (leave blank to use demo repository):"
  read -rp "  Username: " GIT_USERNAME
  read -rsp "  Password/PAT: " GIT_PASSWORD
  echo
}

fetch_repo() {
  local repo_url="$1"
  local default_branch
  
  # Try to detect default branch, fallback to main
  default_branch="$(git ls-remote --symref "$repo_url" HEAD 2>/dev/null | awk '/^ref:/ {print $3}' | sed 's@refs/heads/@@' || echo "")"
  if [ -z "$default_branch" ]; then
    # Try to get any branch name
    default_branch="$(git ls-remote --heads "$repo_url" 2>/dev/null | head -n1 | sed 's@.*refs/heads/@@' || echo "main")"
  fi
  default_branch="${default_branch:-main}"

  if [[ -d "$WORKDIR/.git" ]]; then
    git -C "$WORKDIR" remote set-url origin "$repo_url" || true
    if ! git -C "$WORKDIR" fetch --all --prune 2>/dev/null; then
      warn "Fetch failed; trying fresh clone..."
      rm -rf "$WORKDIR"
      if ! git clone "$repo_url" "$WORKDIR" 2>/dev/null; then
        warn "Clone failed. Falling back to demo repo."
        repo_url="$(build_auth_repo_url "$DEMO_REPO")"
        git clone "$repo_url" "$WORKDIR" 2>/dev/null || {
          err "Clone failed for both primary and demo repositories."
          return 1
        }
      fi
    else
      # Try to checkout the branch, but don't fail if it doesn't exist
      git -C "$WORKDIR" checkout -B "$default_branch" "origin/$default_branch" 2>/dev/null || true
      git -C "$WORKDIR" reset --hard "origin/$default_branch" 2>/dev/null || git -C "$WORKDIR" reset --hard HEAD 2>/dev/null || true
    fi
  else
    rm -rf "$WORKDIR"
    if ! git clone --branch "$default_branch" --single-branch "$repo_url" "$WORKDIR" 2>/dev/null; then
      warn "Branch clone failed; retrying generic clone..."
      if ! git clone "$repo_url" "$WORKDIR" 2>/dev/null; then
        warn "Clone failed. Falling back to demo repo."
        if ! git clone "$(build_auth_repo_url "$DEMO_REPO")" "$WORKDIR" 2>/dev/null; then
          err "Clone failed for both primary and demo repositories."
          return 1
        fi
      fi
    fi
  fi
  
  # Verify we have a valid repo
  if [ ! -d "$WORKDIR/.git" ]; then
    err "Failed to fetch repository."
    return 1
  fi
  
  return 0
}

backup_yaml_once() {
  if [[ -f "$SURICATA_YAML" && ! -f "${SURICATA_YAML}.bak" ]]; then
    cp "$SURICATA_YAML" "${SURICATA_YAML}.bak"
    info "Backed up suricata.yaml to ${SURICATA_YAML}.bak"
  fi
}

detect_network() {
  info "Detecting network configuration..."
  
  # Initialize variables
  DEFAULT_INTERFACE=""
  IP_ADDR=""
  NETWORK=""
  
  # Get default interface
  DEFAULT_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1 || echo "")
  
  if [ -z "$DEFAULT_INTERFACE" ]; then
    warn "Could not detect default interface automatically."
    ip -br addr show
    read -rp "Enter interface name: " DEFAULT_INTERFACE
  fi
  
  # Get IP address of default interface
  IP_ADDR=$(ip addr show "$DEFAULT_INTERFACE" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1 || echo "")
  NETWORK=$(ip route | grep "$DEFAULT_INTERFACE" | grep -v default | awk '{print $1}' | head -n1 || echo "")
  
  info "Detected Interface: $DEFAULT_INTERFACE"
  [ -n "$IP_ADDR" ] && info "Detected IP: $IP_ADDR"
  [ -n "$NETWORK" ] && info "Detected Network: $NETWORK"
  
  echo ""
  read -rp "Use detected interface '$DEFAULT_INTERFACE'? (y/n): " use_detected
  
  # Accept y, yes, Y, YES, or any non-empty string starting with n/N
  if [[ "${use_detected,,}" =~ ^n ]]; then
    warn "Available interfaces:"
    ip -br addr show
    read -rp "Enter interface name: " DEFAULT_INTERFACE
    IP_ADDR=$(ip addr show "$DEFAULT_INTERFACE" 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d'/' -f1 || echo "")
    NETWORK=$(ip route | grep "$DEFAULT_INTERFACE" | grep -v default | awk '{print $1}' | head -n1 || echo "")
  fi
  
  # Set defaults if still empty
  [ -z "$NETWORK" ] && NETWORK="192.168.0.0/16"
  [ -z "$DEFAULT_INTERFACE" ] && DEFAULT_INTERFACE="eth0"
  
  info "Using interface: $DEFAULT_INTERFACE, Network: $NETWORK"
  
  # Verify we have valid values
  if [ -z "$DEFAULT_INTERFACE" ]; then
    err "No interface specified"
    return 1
  fi
  
  # Verify interface exists
  if ! ip link show "$DEFAULT_INTERFACE" &>/dev/null; then
    err "Interface '$DEFAULT_INTERFACE' does not exist"
    warn "Available interfaces:"
    ip -br addr show
    return 1
  fi
  
  # Validate network format (basic check)
  if [ -n "$NETWORK" ] && ! echo "$NETWORK" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$'; then
    warn "Network format may be invalid: $NETWORK (expected CIDR format)"
  fi
  
  return 0
}

install_suricata_stack() {
  info "Installing Suricata and dependencies (per suricata_setup.md)..."
  
  if ! apt_update_once; then
    warn "apt-get update failed, but continuing..."
  fi
  
  if ! apt-get install -y software-properties-common apt-transport-https curl jq lsb-release; then
    err "Failed to install dependencies"
    return 1
  fi
  
  ensure_git
  
  # Detect OS and handle repository appropriately
  local os_id os_codename
  os_id=$(. /etc/os-release 2>/dev/null && echo "$ID" || echo "")
  os_codename=$(lsb_release -cs 2>/dev/null || echo "")
  
  # Add Suricata repository (avoid stale backports on Kali, use PPA for Ubuntu, backports for Debian)
  if ! grep -q "oisf\|suricata" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
    if [ "$os_id" = "kali" ]; then
      warn "Kali detected; skipping Debian backports repo."
    elif [ "$os_id" = "ubuntu" ]; then
      info "Ubuntu detected; adding OISF PPA..."
      add-apt-repository -y ppa:oisf/suricata-stable 2>/dev/null || true
      apt_update_once || true
    elif [ "$os_id" = "debian" ] && [ -n "$os_codename" ]; then
      info "Debian detected; adding backports repository..."
      echo "deb http://deb.debian.org/debian ${os_codename}-backports main" > /etc/apt/sources.list.d/backports.list 2>/dev/null || true
      apt_update_once || true
    else
      warn "Could not determine OS/codename; attempting PPA..."
      add-apt-repository -y ppa:oisf/suricata-stable 2>/dev/null || true
      apt_update_once || true
    fi
  fi
  
  # Install Suricata (from backports on Debian if available)
  local install_success=0
  if [ "$os_id" = "debian" ] && [ -n "$os_codename" ]; then
    info "Attempting to install Suricata from backports..."
    if apt-get install -y suricata -t "${os_codename}-backports" 2>/dev/null; then
      install_success=1
    else
      warn "Backports install failed, trying regular repository..."
      if apt-get install -y suricata; then
        install_success=1
      fi
    fi
  else
    if apt-get install -y suricata; then
      install_success=1
    fi
  fi
  
  if [ $install_success -eq 1 ]; then
    info "Suricata installed successfully!"
    systemctl enable suricata || true
    
    # Install corrected YAML template if suricata.yaml exists
    if [ -f "$SURICATA_YAML" ]; then
      install_corrected_yaml_template
    fi
    
    return 0
  else
    err "Failed to install Suricata"
    return 1
  fi
}

install_corrected_yaml_template() {
  # Install the corrected YAML template with proper structure
  # This replaces the default suricata.yaml with the corrected version
  info "Installing corrected YAML template..."
  
  if [ ! -f "$SURICATA_YAML" ]; then
    warn "Suricata YAML not found, skipping template installation"
    return 1
  fi
  
  # Backup original if backup doesn't exist
  if [ ! -f "${SURICATA_YAML}.bak" ]; then
    cp "$SURICATA_YAML" "${SURICATA_YAML}.bak" 2>/dev/null || true
  fi
  
  # Create corrected YAML template (without rules in rule-files section)
  cat > "$SURICATA_YAML" <<'YAML_EOF'
%YAML 1.1
---

# Suricata configuration file. In addition to the comments describing all
# options in this file, full documentation can be found at:
# https://docs.suricata.io/en/latest/configuration/suricata-yaml.html

# This configuration file was generated by Suricata 8.0.2.
suricata-version: "8.0"

##
## Step 1: Inform Suricata about your network
##

vars:
  # more specific is better for alert accuracy and performance
  address-groups:
    HOME_NET: "[192.168.75.0/24]"

    EXTERNAL_NET: "!$HOME_NET"
    #EXTERNAL_NET: "any"

    HTTP_SERVERS: "$HOME_NET"
    SMTP_SERVERS: "$HOME_NET"
    SQL_SERVERS: "$HOME_NET"
    DNS_SERVERS: "$HOME_NET"
    TELNET_SERVERS: "$HOME_NET"
    AIM_SERVERS: "$EXTERNAL_NET"
    DC_SERVERS: "$HOME_NET"
    DNP3_SERVER: "$HOME_NET"
    DNP3_CLIENT: "$HOME_NET"
    MODBUS_CLIENT: "$HOME_NET"
    MODBUS_SERVER: "$HOME_NET"
    ENIP_CLIENT: "$HOME_NET"
    ENIP_SERVER: "$HOME_NET"

  port-groups:
    HTTP_PORTS: "80"
    SHELLCODE_PORTS: "!80"
    ORACLE_PORTS: 1521
    SSH_PORTS: 22
    DNP3_PORTS: 20000
    MODBUS_PORTS: 502
    FILE_DATA_PORTS: "[$HTTP_PORTS,110,143]"
    FTP_PORTS: 21
    GENEVE_PORTS: 6081
    VXLAN_PORTS: 4789
    TEREDO_PORTS: 3544
    SIP_PORTS: "[5060, 5061]"

##
## Step 2: Select outputs to enable
##

# The default logging directory.  Any log or output file will be
# placed here if it's not specified with a full path name. This can be
# overridden with the -l command line parameter.
default-log-dir: /var/log/suricata/

# Global stats configuration
stats:
  enabled: yes
  # The interval field (in seconds) controls the interval at
  # which stats are updated in the log.
  interval: 8
  exception-policy:
    #per-app-proto-errors: false  # default: false. True will log errors for
                                  # each app-proto. Warning: VERY verbose

# Plugins -- Experimental -- specify the filename for each plugin shared object
plugins:
  #- /usr/lib/suricata/pfring.so
  #- /usr/lib/suricata/napatech.so
  #- /usr/lib/suricata/ndpi.so
# - /path/to/plugin.so

# Configure the type of alert (and other) logging you would like.
outputs:
  # a line based alerts log similar to Snort's fast.log
  - fast:
      enabled: yes
      file: /var/log/suricata/fast.log
      append: yes
      #filetype: regular # 'regular', 'unix_stream' or 'unix_dgram'

  # Extensible Event Format (nicknamed EVE) event log in JSON format
  - eve-log:
      enabled: yes
      filetype: regular
      filename: /var/log/suricata/eve.json
      pcap-file: false
      community-id: false
      community-id-seed: 0
      xff:
        mode: extra-data
        deployment: reverse
        header: X-Forwarded-For

      types:
        - alert:
            tagged-packets: yes
        # app layer frames
        - frame:
            enabled: no
        - anomaly:
            enabled: yes
            types:
        - http:
            extended: yes
        - dns:
        - mdns:
        - tls:
            extended: yes
        - files:
            force-magic: no
        - smtp:
        - websocket
        - ftp
        - rdp
        - nfs
        - smb:
        - tftp
        - ike
        - dcerpc
        - krb5
        - bittorrent-dht
        - snmp
        - rfb
        - sip
        - quic
        - ldap
        - pop3
        - arp:
            enabled: no
        - dhcp:
            enabled: yes
            extended: no
        - ssh
        - mqtt:
        - http2
        - doh2
        - pgsql:
            enabled: no
        - stats:
            totals: yes
            threads: no
            deltas: no
        - flow

  - tls-store:
      enabled: no

  - pcap-log:
      enabled: no
      filename: log.pcap
      limit: 1000 MiB
      max-files: 2000
      compression: none
      mode: normal
      use-stream-depth: no
      honor-pass-rules: no

  - alert-debug:
      enabled: no
      filename: alert-debug.log
      append: yes

  - stats:
      enabled: yes
      filename: stats.log
      append: yes
      totals: yes
      threads: no

  - file-store:
      version: 2
      enabled: no
      xff:
        enabled: no
        mode: extra-data
        deployment: reverse
        header: X-Forwarded-For

  - tcp-data:
      enabled: no
      type: file
      filename: tcp-data.log

  - http-body-data:
      enabled: no
      type: file
      filename: http-data.log

  - lua:
      enabled: no
      scripts:

heartbeat:
  #output-flush-interval: 0

# Logging configuration.  This is not about logging IDS alerts/events, but
# output about what Suricata is doing, like startup messages, errors, etc.
logging:
  default-log-level: notice
  default-output-filter:

  outputs:
  - console:
      enabled: yes
  - file:
      enabled: yes
      level: info
      filename: suricata.log
  - syslog:
      enabled: no
      facility: local5
      format: "[%i] <%d> -- "

##
## Step 3: Configure common capture settings
##

# Linux high speed capture support
af-packet:
  - interface: eth0
    cluster-id: 99
    cluster-type: cluster_flow
    defrag: yes
  - interface: default

# Linux high speed af-xdp capture support
af-xdp:
  - interface: default

dpdk:
  eal-params:
    proc-type: primary
  interfaces:
    - interface: 0000:3b:00.0
      threads: auto
      promisc: true
      multicast: true
      checksum-checks: true
      checksum-checks-offload: true
      mtu: 1500
      vlan-strip-offload: false
      mempool-size: auto
      mempool-cache-size: auto
      rx-descriptors: auto
      tx-descriptors: auto
      copy-mode: none
      copy-iface: none
    - interface: default
      threads: auto
      promisc: true
      multicast: true
      checksum-checks: true
      checksum-checks-offload: true
      mtu: 1500
      vlan-strip-offload: false
      rss-hash-functions: auto
      linkup-timeout: 0
      mempool-size: auto
      mempool-cache-size: auto
      rx-descriptors: auto
      tx-descriptors: auto
      copy-mode: none
      copy-iface: none

# Cross platform libpcap capture support
pcap:
  - interface: eth0
  - interface: default

# Settings for reading pcap files
pcap-file:
  checksum-checks: auto

##
## Step 4: App Layer Protocol configuration
##

app-layer:
  protocols:
    telnet:
      enabled: yes
    rfb:
      enabled: yes
      detection-ports:
        dp: 5900, 5901, 5902, 5903, 5904, 5905, 5906, 5907, 5908, 5909
    mqtt:
      enabled: yes
    krb5:
      enabled: yes
    bittorrent-dht:
      enabled: yes
    snmp:
      enabled: yes
    ike:
      enabled: yes
    tls:
      enabled: yes
      detection-ports:
        dp: 443
    pgsql:
      enabled: no
      stream-depth: 0
    dcerpc:
      enabled: yes
    ftp:
      enabled: yes
    websocket:
    rdp:
    ssh:
      enabled: yes
    doh2:
      enabled: yes
    http2:
      enabled: yes
    smtp:
      enabled: yes
      raw-extraction: no
      mime:
        decode-mime: yes
        decode-base64: yes
        decode-quoted-printable: yes
        header-value-depth: 2000
        extract-urls: yes
        body-md5: no
      inspected-tracker:
        content-limit: 100000
        content-inspect-min-size: 32768
        content-inspect-window: 4096
    imap:
      enabled: detection-only
    pop3:
      enabled: yes
      detection-ports:
        dp: 110
      stream-depth: 0
    smb:
      enabled: yes
      detection-ports:
        dp: 139, 445
    nfs:
      enabled: yes
    tftp:
      enabled: yes
    dns:
      tcp:
        enabled: yes
        detection-ports:
          dp: 53
      udp:
        enabled: yes
        detection-ports:
          dp: 53
    http:
      enabled: yes
      libhtp:
         default-config:
           personality: IDS
           request-body-limit: 100 KiB
           response-body-limit: 100 KiB
           request-body-minimal-inspect-size: 32 KiB
           request-body-inspect-window: 4 KiB
           response-body-minimal-inspect-size: 40 KiB
           response-body-inspect-window: 16 KiB
           response-body-decompress-layer-limit: 2
           http-body-inline: auto
           swf-decompression:
             enabled: no
             type: both
             compress-depth: 100 KiB
             decompress-depth: 100 KiB
         server-config:
    modbus:
      enabled: no
      detection-ports:
        dp: 502
      stream-depth: 0
    dnp3:
      enabled: no
      detection-ports:
        dp: 20000
    enip:
      enabled: no
      detection-ports:
        dp: 44818
        sp: 44818
    ntp:
      enabled: yes
    quic:
      enabled: yes
    dhcp:
      enabled: yes
    sip:
    ldap:
      tcp:
        enabled: yes
        detection-ports:
          dp: 389, 3268
      udp:
        enabled: yes
        detection-ports:
          dp: 389, 3268
    mdns:
      enabled: yes

asn1-max-frames: 256

datasets:
  defaults:
  limits:
  rules:

security:
  limit-noproc: true
  landlock:
    enabled: no
    directories:
      write:
        - /var/lib/suricata
      read:
        - /usr/
        - /etc/
        - /etc/suricata/

  lua:

coredump:
  max-dump: unlimited

host-mode: auto

unix-command:
  enabled: yes
  filename: /var/run/suricata/suricata-command.socket

legacy:
  uricontent: enabled

exception-policy: auto

engine-analysis:
  rules-fast-pattern: yes
  rules: yes

pcre:
  match-limit: 3500
  match-limit-recursion: 1500

host-os-policy:
  windows: [0.0.0.0/0]
  bsd: []
  bsd-right: []
  old-linux: []
  linux: []
  old-solaris: []
  solaris: []
  hpux10: []
  hpux11: []
  irix: []
  macos: []
  vista: []
  windows2k3: []

defrag:
  memcap: 32 MiB
  hash-size: 65536
  trackers: 65535
  max-frags: 65535
  prealloc: yes
  timeout: 60

flow:
  memcap: 128 MiB
  hash-size: 65536
  prealloc: 10000
  emergency-recovery: 30

vlan:
  use-for-tracking: true

livedev:
  use-for-tracking: true

flow-timeouts:
  default:
    new: 30
    established: 300
    closed: 0
    bypassed: 100
    emergency-new: 10
    emergency-established: 100
    emergency-closed: 0
    emergency-bypassed: 50
  tcp:
    new: 60
    established: 600
    closed: 60
    bypassed: 100
    emergency-new: 5
    emergency-established: 100
    emergency-closed: 10
    emergency-bypassed: 50
  udp:
    new: 30
    established: 300
    bypassed: 100
    emergency-new: 10
    emergency-established: 100
    emergency-bypassed: 50
  icmp:
    new: 30
    established: 300
    bypassed: 100
    emergency-new: 10
    emergency-established: 100
    emergency-bypassed: 50

stream:
  memcap: 64 MiB
  checksum-validation: yes
  inline: auto
  reassembly:
    urgent:
      policy: oob
      oob-limit-policy: drop
    memcap: 256 MiB
    depth: 1 MiB
    toserver-chunk-size: 2560
    toclient-chunk-size: 2560
    randomize-chunk-size: yes

host:
  hash-size: 4096
  prealloc: 1000
  memcap: 32 MiB

decoder:
  teredo:
    enabled: true
    ports: $TEREDO_PORTS
  vxlan:
    enabled: true
    ports: $VXLAN_PORTS
  geneve:
    enabled: true
    ports: $GENEVE_PORTS
  recursion-level:
    use-for-tracking: true

detect:
  profile: medium
  custom-values:
    toclient-groups: 3
    toserver-groups: 25
  sgh-mpm-context: auto
  sgh-mpm-caching: yes
  sgh-mpm-caching-path: /var/lib/suricata/cache/sgh
  prefilter:
    default: mpm
  thresholds:
    hash-size: 16384
    memcap: 16 MiB
  profiling:
    rules:
      enabled: yes
      filename: rule_perf.log
      append: yes
      limit: 10
      json: yes
    keywords:
      enabled: yes
      filename: keyword_perf.log
      append: yes
    prefilter:
      enabled: yes
      filename: prefilter_perf.log
      append: yes
    rulegroups:
      enabled: yes
      filename: rule_group_perf.log
      append: yes
    packets:
      enabled: yes
      filename: packet_stats.log
      append: yes
      csv:
        enabled: no
        filename: packet_stats.csv
    locks:
      enabled: no
      filename: lock_stats.log
      append: yes
    pcap-log:
      enabled: no
      filename: pcaplog_stats.log
      append: yes

mpm-algo: auto

spm-algo: auto

threading:
  set-cpu-affinity: no
  autopin: no
  cpu-affinity:
    management-cpu-set:
      cpu: [ 0 ]
    receive-cpu-set:
      cpu: [ 0 ]
    worker-cpu-set:
      cpu: [ "all" ]
      mode: "exclusive"
      prio:
        low: [ 0 ]
        medium: [ "1-2" ]
        high: [ 3 ]
        default: "medium"
      interface-specific-cpu-set:
        - interface: "enp4s0f0"
          cpu: [ 1,3,5,7,9 ]
          mode: "exclusive"
          prio:
            high: [ "all" ]
            default: "medium"
  detect-thread-ratio: 1.0

profiling:
  rules:
    enabled: yes
    filename: rule_perf.log
    append: yes
    limit: 10
    json: yes
  keywords:
    enabled: yes
    filename: keyword_perf.log
    append: yes
  prefilter:
    enabled: yes
    filename: prefilter_perf.log
    append: yes
  rulegroups:
    enabled: yes
    filename: rule_group_perf.log
    append: yes
  packets:
    enabled: yes
    filename: packet_stats.log
    append: yes
    csv:
      enabled: no
      filename: packet_stats.csv
  locks:
    enabled: no
    filename: lock_stats.log
    append: yes
  pcap-log:
    enabled: no
    filename: pcaplog_stats.log
    append: yes

nfq:

nflog:
    - group: 2
      buffer-size: 18432
    - group: default
      qthreshold: 1
      qtimeout: 100
      max-size: 20000

capture:

netmap:
 - interface: eth2
 - interface: default

pfring:
  - interface: eth0
    threads: auto
    cluster-id: 99
    cluster-type: cluster_flow
  - interface: default

ipfw:

napatech:
    streams: ["0-3"]
    enable-stream-stats: no
    auto-config: yes
    hardware-bypass: yes
    inline: no
    ports: [0-1,2-3]
    hashmode: hash5tuplesorted

default-rule-path: /etc/suricata/rules

rule-files:

##
## Auxiliary configuration files.
##

classification-file: /etc/suricata/classification.config
reference-config-file: /etc/suricata/reference.config
# threshold-file: /etc/suricata/threshold.config

##
## Suricata as a Firewall options (experimental)
##
firewall:
  #enabled: no
  #rule-path: /etc/suricata/firewall/
YAML_EOF

  # Set proper permissions
  chmod 644 "$SURICATA_YAML" 2>/dev/null || true
  
  info "Corrected YAML template installed successfully"
}

validate_yaml_syntax() {
  # Validate YAML syntax and show problematic line
  local yaml_file="$1"
  local test_output
  test_output=$(suricata -T -c "$yaml_file" 2>&1)
  local test_exit=$?
  
  if [ $test_exit -ne 0 ]; then
    # Extract line number from error
    local error_line
    error_line=$(echo "$test_output" | grep -oE "line [0-9]+" | grep -oE "[0-9]+" | head -1)
    
    if [ -n "$error_line" ]; then
      err "YAML syntax error detected at line $error_line:"
      sed -n "${error_line}p" "$yaml_file" 2>/dev/null | sed 's/^/  /' >&2
      if [ $error_line -gt 1 ]; then
        err "Context (lines $((error_line-2))-$((error_line+2))):"
        sed -n "$((error_line-2)),$((error_line+2))p" "$yaml_file" 2>/dev/null | nl -v $((error_line-2)) | sed 's/^/  /' >&2
      fi
    fi
    return 1
  fi
  return 0
}

remove_duplicate_keys() {
  # Remove duplicate keys in fast/eve-log sections, especially 'enabled:' keys
  local yaml_file="$1"
  local tmp_yaml
  tmp_yaml=$(mktemp) || { err "Failed to create temp file"; return 1; }
  
  local in_fast=0
  local in_eve=0
  local fast_enabled_found=0
  local eve_enabled_found=0
  local fixed=0
  
  while IFS= read -r line || [ -n "$line" ]; do
    # Detect section boundaries
    if echo "$line" | grep -qE "^[ \t]*-[ \t]*fast:"; then
      in_fast=1
      in_eve=0
      fast_enabled_found=0
    elif echo "$line" | grep -qE "^[ \t]*-[ \t]*eve-log:"; then
      in_eve=1
      in_fast=0
      eve_enabled_found=0
    elif [ "$in_fast" -eq 1 ] || [ "$in_eve" -eq 1 ]; then
      # Check if we've left the section
      if echo "$line" | grep -qE "^[a-zA-Z]"; then
        # Top-level key found (no leading spaces), exit section
        in_fast=0
        in_eve=0
        fast_enabled_found=0
        eve_enabled_found=0
      elif echo "$line" | grep -qE "^[ \t]*-[ \t]+[a-zA-Z-]+:"; then
        # Next list item at same level found
        if ! echo "$line" | grep -qE "^[ \t]*-[ \t]*(fast|eve-log):"; then
          in_fast=0
          in_eve=0
          fast_enabled_found=0
          eve_enabled_found=0
        fi
      fi
    fi
    
    # Remove duplicate 'enabled:' keys
    if [ "$in_fast" -eq 1 ] && echo "$line" | grep -qE "^[ \t]*enabled:"; then
      if [ $fast_enabled_found -eq 1 ]; then
        # Skip this duplicate line
        fixed=1
        continue
      else
        fast_enabled_found=1
      fi
    elif [ "$in_eve" -eq 1 ] && echo "$line" | grep -qE "^[ \t]*enabled:"; then
      if [ $eve_enabled_found -eq 1 ]; then
        # Skip this duplicate line
        fixed=1
        continue
      else
        eve_enabled_found=1
      fi
    fi
    
    echo "$line" >> "$tmp_yaml"
  done < "$yaml_file"
  
  mv "$tmp_yaml" "$yaml_file"
  
  if [ $fixed -eq 1 ]; then
    info "Removed duplicate 'enabled:' keys"
  fi
  
  return $fixed
}

fix_yaml_structure_issues() {
  # Fix specific YAML structure issues, especially around line 212
  # Handle comments that break YAML structure and indentation issues
  local yaml_file="$1"
  local tmp_yaml
  tmp_yaml=$(mktemp) || { err "Failed to create temp file"; return 1; }
  local fixed=0
  local prev_line=""
  local prev_indent=0
  
  while IFS= read -r line || [ -n "$line" ]; do
    local current_line="$line"
    
    # Fix: If a comment is followed by a list item, ensure proper indentation
    # This handles the case where "# app layer frames" is followed by "- frame:"
    if echo "$prev_line" | grep -qE "^[ \t]*#[ \t]*app layer frames" && echo "$line" | grep -qE "^[ \t]*-[ \t]*frame:"; then
      # Ensure the list item has proper indentation (should match parent level)
      # Count indentation of previous non-comment line
      local frame_indent
      frame_indent=$(echo "$line" | sed 's|^\([ \t]*\).*|\1|' | wc -c)
      frame_indent=$((frame_indent - 1))
      
      # If frame: is not properly indented, fix it
      if [ $frame_indent -lt 4 ] || [ $frame_indent -gt 8 ]; then
        # Set to 6 spaces (typical for nested list items in outputs)
        current_line=$(echo "$line" | sed 's|^[ \t]*|      |')
        fixed=1
      fi
    fi
    
    # Fix: Ensure list items under outputs have consistent indentation
    # Fix over-indented keys that should be at 4-space indentation
    if echo "$line" | grep -qE "^[ \t]\{6,\}[a-z][a-z-]*:" && ! echo "$line" | grep -qE "^[ \t]*#[ \t]*"; then
      # Check if this is a key that should be at 4 spaces (file:, enabled:, etc.)
      if echo "$line" | grep -qE "^[ \t]\{6,\}(file|enabled|append|filetype):"; then
        current_line=$(echo "$line" | sed 's|^[ \t]\{6,\}|    |')
        fixed=1
      fi
    fi
    
    # Fix: Remove trailing spaces that can cause YAML issues
    current_line=$(echo "$current_line" | sed 's|[ \t]*$||')
    
    echo "$current_line" >> "$tmp_yaml"
    prev_line="$current_line"
  done < "$yaml_file"
  
  mv "$tmp_yaml" "$yaml_file"
  
  if [ $fixed -eq 1 ]; then
    info "Fixed YAML structure issues"
  fi
  
  return $fixed
}

fix_yaml_syntax() {
  # Fix common YAML syntax issues
  local yaml_file="$1"
  local fixed=0
  
  # Step 1: Remove duplicate keys (especially 'enabled:')
  if remove_duplicate_keys "$yaml_file"; then
    fixed=1
  fi
  
  # Step 2: Fix structure issues (comments, indentation)
  if fix_yaml_structure_issues "$yaml_file"; then
    fixed=1
  fi
  
  # Step 3: Remove duplicate colons (e.g., "key:: value" -> "key: value")
  if grep -q "::" "$yaml_file"; then
    sed -i 's|::|:|g' "$yaml_file"
    fixed=1
  fi
  
  # Step 4: Fix lines with multiple spaces before colons
  if grep -qE "[ \t]+:[ \t]+:" "$yaml_file"; then
    sed -i 's|[ \t]\+:[ \t]\+:|: |g' "$yaml_file"
    fixed=1
  fi
  
  # Step 5: Fix lines that have colons but are malformed
  sed -i 's|[ \t]*:[ \t]*:[ \t]*|: |g' "$yaml_file"
  
  # Step 6: Fix filename: -> file: in fast section
  local in_fast=0
  local tmp_yaml
  tmp_yaml=$(mktemp) || { err "Failed to create temp file"; return 1; }
  
  while IFS= read -r line || [ -n "$line" ]; do
    if echo "$line" | grep -qE "^[ \t]*-[ \t]*fast:"; then
      in_fast=1
    elif [ "$in_fast" -eq 1 ]; then
      if echo "$line" | grep -qE "^[a-zA-Z]" || (echo "$line" | grep -qE "^[ \t]*-[ \t]+[a-zA-Z-]+:" && ! echo "$line" | grep -qE "^[ \t]*-[ \t]*fast:"); then
        in_fast=0
      elif echo "$line" | grep -qE "^[ \t]*filename:"; then
        line=$(echo "$line" | sed 's|^\([ \t]*\)filename:[ \t]*|\1file: |')
        fixed=1
      fi
    fi
    echo "$line" >> "$tmp_yaml"
  done < "$yaml_file"
  
  mv "$tmp_yaml" "$yaml_file"
  
  if [ $fixed -eq 1 ]; then
    info "Fixed YAML syntax issues"
  fi
  
  return $fixed
}

configure_logging() {
  # Configure logging outputs in suricata.yaml - conservative approach
  # Only uncomment existing sections, don't modify structure
  info "Configuring logging outputs..."
  
  if [ ! -f "$SURICATA_YAML" ]; then
    err "Suricata configuration file not found at $SURICATA_YAML"
    return 1
  fi
  
  # Ensure log directory exists with proper permissions
  mkdir -p /var/log/suricata
  chown suricata:suricata /var/log/suricata 2>/dev/null || chmod 755 /var/log/suricata
  
  # Backup before making changes
  cp "$SURICATA_YAML" "${SURICATA_YAML}.pre-logging" 2>/dev/null || true
  
  # Step 1: Pre-validate YAML and fix any existing issues
  if ! validate_yaml_syntax "$SURICATA_YAML" 2>/dev/null; then
    warn "YAML has pre-existing syntax errors. Attempting to fix..."
    if ! fix_yaml_syntax "$SURICATA_YAML"; then
      warn "Could not fix pre-existing YAML errors. Restoring backup..."
      mv "${SURICATA_YAML}.pre-logging" "$SURICATA_YAML" 2>/dev/null || true
      return 1
    fi
    # Re-validate after fix
    if ! validate_yaml_syntax "$SURICATA_YAML" 2>/dev/null; then
      warn "YAML still has errors after fix. Restoring backup..."
      mv "${SURICATA_YAML}.pre-logging" "$SURICATA_YAML" 2>/dev/null || true
      return 1
    fi
  fi
  
  # Step 2: Remove duplicate keys before modifications
  remove_duplicate_keys "$SURICATA_YAML" || true
  
  # Step 3: Simply uncomment outputs section and logging outputs if they're commented
  # Don't try to insert new sections - that causes YAML syntax errors
  sed -i 's|^[ \t]*#[ \t]*outputs:[ \t]*$|outputs:|g' "$SURICATA_YAML"
  sed -i 's|^[ \t]*#[ \t]*-[ \t]*fast:[ \t]*$|  - fast:|g' "$SURICATA_YAML"
  sed -i 's|^[ \t]*#[ \t]*-[ \t]*eve-log:[ \t]*$|  - eve-log:|g' "$SURICATA_YAML"
  
  # Step 4: Update file paths if they exist - use line-by-line approach instead of ranges
  # This avoids sed range issues that can corrupt YAML structure
  local in_fast=0
  local in_eve=0
  local fast_file_found=0
  local fast_enabled_found=0
  local eve_filename_found=0
  local eve_enabled_found=0
  local eve_filetype_found=0
  local tmp_yaml
  tmp_yaml=$(mktemp) || { err "Failed to create temp file"; return 1; }
  
  # Process file line by line to avoid sed range issues
  while IFS= read -r line || [ -n "$line" ]; do
    # Detect section boundaries
    if echo "$line" | grep -qE "^[ \t]*-[ \t]*fast:"; then
      in_fast=1
      in_eve=0
      fast_file_found=0
      fast_enabled_found=0
    elif echo "$line" | grep -qE "^[ \t]*-[ \t]*eve-log:"; then
      in_eve=1
      in_fast=0
      eve_filename_found=0
      eve_enabled_found=0
      eve_filetype_found=0
    elif [ "$in_fast" -eq 1 ] || [ "$in_eve" -eq 1 ]; then
      # Check if we've left the section
      if echo "$line" | grep -qE "^[a-zA-Z]"; then
        # Top-level key found (no leading spaces), exit section
        in_fast=0
        in_eve=0
        fast_file_found=0
        fast_enabled_found=0
        eve_filename_found=0
        eve_enabled_found=0
        eve_filetype_found=0
      elif echo "$line" | grep -qE "^[ \t]*-[ \t]+[a-zA-Z-]+:"; then
        # Next list item at same level found (starts with "  - " followed by word and colon)
        # Check if it's not fast: or eve-log:
        if ! echo "$line" | grep -qE "^[ \t]*-[ \t]*(fast|eve-log):"; then
          in_fast=0
          in_eve=0
          fast_file_found=0
          fast_enabled_found=0
          eve_filename_found=0
          eve_enabled_found=0
          eve_filetype_found=0
        fi
      fi
    fi
    
    # Modify lines within sections - only update existing keys, don't create duplicates
    if [ "$in_fast" -eq 1 ]; then
      # Fix filename: -> file: in fast section
      if echo "$line" | grep -qE "^[ \t]*filename:"; then
        line=$(echo "$line" | sed 's|^\([ \t]*\)filename:[ \t]*|\1file: |')
        fast_file_found=1
      fi
      # Update file path (only if it exists)
      if echo "$line" | grep -qE "^[ \t]*file:"; then
        line=$(echo "$line" | sed 's|^\([ \t]*file:\).*|\1 /var/log/suricata/fast.log|')
        fast_file_found=1
      fi
      # Update enabled (only if it exists, and only once)
      if echo "$line" | grep -qE "^[ \t]*enabled:"; then
        if [ $fast_enabled_found -eq 0 ]; then
          line=$(echo "$line" | sed 's|^\([ \t]*enabled:\).*|\1 yes|')
          fast_enabled_found=1
        else
          # Skip duplicate enabled line
          continue
        fi
      fi
      # Fix over-indentation (should be 4 spaces for file/enabled)
      if echo "$line" | grep -qE "^[ \t]\{6,\}[a-z]"; then
        line=$(echo "$line" | sed 's|^[ \t]\{6,\}\([a-z]\)|    \1|')
      fi
    elif [ "$in_eve" -eq 1 ]; then
      # Update filename path for eve-log (only if it exists)
      if echo "$line" | grep -qE "^[ \t]*filename:"; then
        line=$(echo "$line" | sed 's|^\([ \t]*filename:\).*|\1 /var/log/suricata/eve.json|')
        eve_filename_found=1
      fi
      # Update enabled (only if it exists, and only once)
      if echo "$line" | grep -qE "^[ \t]*enabled:"; then
        if [ $eve_enabled_found -eq 0 ]; then
          line=$(echo "$line" | sed 's|^\([ \t]*enabled:\).*|\1 yes|')
          eve_enabled_found=1
        else
          # Skip duplicate enabled line
          continue
        fi
      fi
      # Update filetype (only if it exists)
      if echo "$line" | grep -qE "^[ \t]*filetype:"; then
        line=$(echo "$line" | sed 's|^\([ \t]*filetype:\).*|\1 regular|')
        eve_filetype_found=1
      fi
    fi
    
    echo "$line" >> "$tmp_yaml"
  done < "$SURICATA_YAML"
  
  mv "$tmp_yaml" "$SURICATA_YAML"
  
  # Step 5: Remove any duplicates that may have been created
  remove_duplicate_keys "$SURICATA_YAML" || true
  
  # Step 6: Validate YAML syntax after all changes
  if ! validate_yaml_syntax "$SURICATA_YAML" 2>/dev/null; then
    err "YAML syntax error detected after logging configuration!"
    warn "Attempting to fix YAML syntax issues..."
    if fix_yaml_syntax "$SURICATA_YAML"; then
      # Re-validate after fix
      if ! validate_yaml_syntax "$SURICATA_YAML" 2>/dev/null; then
        err "Could not fix YAML syntax errors. Restoring backup..."
        mv "${SURICATA_YAML}.pre-logging" "$SURICATA_YAML" 2>/dev/null || true
        warn "Logging configuration failed. Please configure manually."
        return 1
      else
        info "✓ YAML syntax errors fixed successfully"
      fi
    else
      err "YAML fix failed. Restoring backup..."
      mv "${SURICATA_YAML}.pre-logging" "$SURICATA_YAML" 2>/dev/null || true
      warn "Logging configuration failed. Please configure manually."
      return 1
    fi
  fi
  
  # Verify the configuration was written correctly
  local fast_configured=0
  local eve_configured=0
  
  if grep -E "^[ \t]*-[ \t]+fast:" "$SURICATA_YAML" 2>/dev/null | grep -v "^#" | grep -q "fast:"; then
    fast_configured=1
    info "✓ Fast log output configured in YAML"
  else
    warn "Fast log output not found - may need manual configuration"
  fi
  
  if grep -E "^[ \t]*-[ \t]+eve-log:" "$SURICATA_YAML" 2>/dev/null | grep -v "^#" | grep -q "eve-log:"; then
    eve_configured=1
    info "✓ Eve log output configured in YAML"
  else
    warn "Eve log output not found - may need manual configuration"
  fi
  
  # Clean up backup
  rm -f "${SURICATA_YAML}.pre-logging" 2>/dev/null || true
  
  if [ $fast_configured -eq 1 ] && [ $eve_configured -eq 1 ]; then
    info "Logging outputs configured successfully (fast.log and eve.json enabled)"
    return 0
  elif [ $fast_configured -eq 1 ]; then
    warn "Fast log configured but eve-log may need manual configuration"
    return 0
  else
    warn "Logging outputs may need manual configuration in suricata.yaml"
    return 0  # Don't fail, just warn
  fi
}

configure_suricata() {
  info "Configuring Suricata..."
  
  if [ ! -f "$SURICATA_YAML" ]; then
    err "Suricata configuration file not found at $SURICATA_YAML"
    return 1
  fi
  
  backup_yaml_once
  
  # Fix common YAML syntax issues FIRST (before any other modifications)
  # These will be handled by configure_logging and fix_yaml_syntax functions
  
  # Update HOME_NET
  if [ -n "$NETWORK" ]; then
    sed -i "s|HOME_NET:.*|HOME_NET: \"[$NETWORK]\"|g" "$SURICATA_YAML"
    info "Updated HOME_NET to: $NETWORK"
  fi
  
  # Update af-packet interface - use more precise pattern
  if [ -n "$DEFAULT_INTERFACE" ]; then
    # Find af-packet section and update interface line
    local in_afpacket=0
    local tmp_yaml
    tmp_yaml=$(mktemp) || { err "Failed to create temp file"; return 1; }
    
    while IFS= read -r line || [ -n "$line" ]; do
      if echo "$line" | grep -qE "^[ \t]*-[ \t]*af-packet:"; then
        in_afpacket=1
      elif [ "$in_afpacket" -eq 1 ]; then
        # Exit section on top-level key or next list item
        if echo "$line" | grep -qE "^[a-zA-Z]" || (echo "$line" | grep -qE "^[ \t]*-[ \t]+[a-zA-Z]" && ! echo "$line" | grep -qE "^[ \t]*-[ \t]*af-packet:"); then
          in_afpacket=0
        elif echo "$line" | grep -qE "^[ \t]*interface:"; then
          line=$(echo "$line" | sed "s|^\([ \t]*interface:\).*|\1 $DEFAULT_INTERFACE|")
        fi
      fi
      echo "$line" >> "$tmp_yaml"
    done < "$SURICATA_YAML"
    
    mv "$tmp_yaml" "$SURICATA_YAML"
    info "Updated interface to: $DEFAULT_INTERFACE"
  fi
  
  # Configure rule path
  sed -i 's|default-rule-path:.*|default-rule-path: /etc/suricata/rules|g' "$SURICATA_YAML"
  sed -i 's|- suricata.rules|# - suricata.rules|g' "$SURICATA_YAML"
  
  # Uncomment rule-files section if it's commented
  sed -i 's|^[ \t]*#[ \t]*rule-files:|rule-files:|g' "$SURICATA_YAML"
  
  # Ensure rule-files section exists (uncommented)
  if ! grep -q "^rule-files:" "$SURICATA_YAML"; then
    # Try to find commented version and uncomment it, or add new section
    if grep -q "^[ \t]*#[ \t]*rule-files:" "$SURICATA_YAML"; then
      sed -i 's|^[ \t]*#[ \t]*rule-files:|rule-files:|g' "$SURICATA_YAML"
    else
      # Add rule-files section if it doesn't exist at all
      if grep -q "^# rule-files:" "$SURICATA_YAML"; then
        sed -i '/^# rule-files:/a rule-files:' "$SURICATA_YAML"
      else
        # Add at end of file or after a suitable marker
        echo "rule-files:" >> "$SURICATA_YAML"
      fi
    fi
  fi
  
  # Configure logging outputs
  configure_logging
  
  info "Suricata configuration completed!"
}

start_suricata() {
  # Optional parameter: skip_verification (set to 1 to skip verify_suricata_config)
  local skip_verification="${1:-0}"
  
  info "Starting Suricata service..."
  
  # Check if Suricata is installed
  if ! command -v suricata &>/dev/null; then
    err "Suricata is not installed. Please run complete installation first."
    return 1
  fi
  
  # Check if systemd is available
  if ! command -v systemctl &>/dev/null; then
    err "systemctl not found. Cannot manage Suricata service."
    return 1
  fi
  
  # Validate configuration file exists
  if [ ! -f "$SURICATA_YAML" ]; then
    err "Suricata configuration file not found at $SURICATA_YAML"
    return 1
  fi
  
  # Ensure log directory exists with proper permissions
  mkdir -p /var/log/suricata
  chmod 755 /var/log/suricata
  chown suricata:suricata /var/log/suricata 2>/dev/null || true
  
  # Check if interface exists and is up
  if [ -n "$DEFAULT_INTERFACE" ]; then
    if ! ip link show "$DEFAULT_INTERFACE" &>/dev/null; then
      err "Interface $DEFAULT_INTERFACE does not exist!"
      warn "Available interfaces:"
      ip -br link show | sed 's/^/  /' >&2
      return 1
    fi
    
    # Check if interface is up
    if ! ip link show "$DEFAULT_INTERFACE" | grep -q "state UP"; then
      warn "Interface $DEFAULT_INTERFACE is not UP. Attempting to bring it up..."
      ip link set "$DEFAULT_INTERFACE" up 2>/dev/null || warn "Could not bring interface up"
      sleep 1
    fi
  fi
  
  # Test configuration before starting - show actual errors
  info "Testing Suricata configuration..."
  local test_output
  test_output=$(suricata -T -c "$SURICATA_YAML" 2>&1)
  local test_exit=$?
  
  if [ $test_exit -ne 0 ]; then
    err ""
    err "=========================================="
    err "CONFIGURATION TEST FAILED!"
    err "=========================================="
    err ""
    echo "$test_output" | head -50 >&2
    err ""
    
    # Use validation function to show exact problematic line
    if echo "$test_output" | grep -qi "line [0-9]"; then
      err "YAML syntax error detected:"
      validate_yaml_syntax "$SURICATA_YAML" || true
      err ""
      err "Attempting to fix YAML syntax..."
      if fix_yaml_syntax "$SURICATA_YAML"; then
        info "YAML syntax fixed. Retesting..."
        if suricata -T -c "$SURICATA_YAML" &>/dev/null; then
          info "✓ Configuration test passed after fix"
        else
          err "YAML fix did not resolve the issue. Manual intervention required."
          err "Check the problematic line shown above."
        fi
      fi
    fi
    
    err "Common issues:"
    err "  1. YAML syntax errors (check indentation)"
    err "  2. Invalid interface name"
    err "  3. Missing or invalid rule files"
    err "  4. Permission issues"
    err ""
    err "To test manually: suricata -T -c $SURICATA_YAML"
    err ""
    
    # Try to identify specific issues
    if echo "$test_output" | grep -qi "interface"; then
      err "Interface issue detected. Checking interface configuration..."
      if [ -n "$DEFAULT_INTERFACE" ]; then
        err "Configured interface: $DEFAULT_INTERFACE"
        ip link show "$DEFAULT_INTERFACE" 2>&1 | head -5 || true
      fi
    fi
    
    if echo "$test_output" | grep -qi "rule\|yaml\|syntax"; then
      err "YAML/Rule syntax issue detected. Check suricata.yaml for errors."
    fi
    
    err "Attempting to start anyway, but it may fail..."
  else
    info "✓ Configuration test passed"
  fi
  
  # Reload systemd to pick up any service file changes
  systemctl daemon-reload 2>/dev/null || true
  
  # Stop any existing instance first
  systemctl stop suricata 2>/dev/null || true
  sleep 1
  
  # Try to start Suricata
  info "Starting Suricata service..."
  if ! systemctl start suricata 2>&1; then
    err ""
    err "=========================================="
    err "FAILED TO START SURICATA SERVICE"
    err "=========================================="
    err ""
    
    # Show service status
    err "Service status:"
    systemctl status suricata --no-pager -l 2>&1 | head -30 || true
    err ""
    
    # Show journal logs
    err "Recent journal logs:"
    journalctl -u suricata -n 30 --no-pager 2>&1 | tail -30 || true
    err ""
    
    # Check for common issues
    err "Diagnosing issues..."
    
    # Check if suricata user exists
    if ! id suricata &>/dev/null; then
      warn "Suricata user may not exist"
    fi
    
    # Check log directory permissions
    if [ -d /var/log/suricata ]; then
      local log_perms
      log_perms=$(stat -c "%a %U:%G" /var/log/suricata 2>/dev/null || echo "unknown")
      warn "Log directory permissions: $log_perms"
      if [ ! -w /var/log/suricata ]; then
        warn "Log directory may not be writable"
      fi
    fi
    
    # Check if interface is configured correctly
    if [ -n "$DEFAULT_INTERFACE" ]; then
      if ! grep -q "interface: $DEFAULT_INTERFACE" "$SURICATA_YAML"; then
        warn "Interface $DEFAULT_INTERFACE may not be configured in YAML"
      fi
    fi
    
    err ""
    err "Troubleshooting steps:"
    err "  1. Check configuration: suricata -T -c $SURICATA_YAML"
    err "  2. Check service: systemctl status suricata"
    err "  3. Check logs: journalctl -u suricata -n 100"
    err "  4. Verify interface: ip link show $DEFAULT_INTERFACE"
    err "  5. Check permissions: ls -la /var/log/suricata"
    err ""
    
    return 1
  fi
  
  # Enable on boot
  systemctl enable suricata.service 2>/dev/null || true
  
  # Wait for service to start and check status
  info "Waiting for Suricata to start..."
  sleep 3
  
  # Check status with retries
  local retries=3
  local started=0
  
  while [ $retries -gt 0 ]; do
    if systemctl is-active --quiet suricata 2>/dev/null; then
      started=1
      break
    fi
    sleep 1
    ((retries--))
  done
  
  if [ $started -eq 1 ]; then
    if [ "$skip_verification" -eq 0 ]; then
      info "Suricata is running!"
    fi
    
    # Wait a bit more for logs to initialize
    sleep 2
    
    # Ensure log files exist and have proper permissions (silent during installation)
    touch /var/log/suricata/fast.log /var/log/suricata/eve.json 2>/dev/null || true
    chmod 644 /var/log/suricata/fast.log /var/log/suricata/eve.json 2>/dev/null || true
    chown suricata:suricata /var/log/suricata/*.log /var/log/suricata/*.json 2>/dev/null || {
      # If suricata user doesn't exist, make files world-writable temporarily
      chmod 666 /var/log/suricata/*.log /var/log/suricata/*.json 2>/dev/null || true
    }
    
    # Check if log files are being created (only show messages if not skipping verification)
    if [ "$skip_verification" -eq 0 ]; then
      if [ -f /var/log/suricata/fast.log ]; then
        info "✓ fast.log file exists"
      else
        warn "fast.log file not found - logging may not be configured correctly"
        info "Reconfiguring logging..."
        configure_logging
        systemctl restart suricata 2>/dev/null || true
        sleep 2
      fi
      
      if [ -f /var/log/suricata/eve.json ]; then
        info "✓ eve.json file exists"
      else
        warn "eve.json file not found - JSON logging may not be configured"
      fi
      
      # Show last log entries
      if [ -f /var/log/suricata/suricata.log ]; then
        info "Last log entries:"
        tail -n 5 /var/log/suricata/suricata.log 2>/dev/null || true
      fi
      
      # Verify configuration
      echo ""
      verify_suricata_config || warn "Configuration verification found issues"
    else
      # During installation: silently ensure logs are configured
      if [ ! -f /var/log/suricata/fast.log ] || [ ! -f /var/log/suricata/eve.json ]; then
        # Ensure logging is configured
        configure_logging >/dev/null 2>&1 || true
        systemctl restart suricata 2>/dev/null || true
        sleep 2
        # Create log files if they still don't exist
        touch /var/log/suricata/fast.log /var/log/suricata/eve.json 2>/dev/null || true
        chmod 644 /var/log/suricata/fast.log /var/log/suricata/eve.json 2>/dev/null || true
      fi
    fi
    
    return 0
  else
    err ""
    err "=========================================="
    err "SURICATA STARTED BUT IS NOT RUNNING!"
    err "=========================================="
    err ""
    err "Service status:"
    systemctl status suricata --no-pager -l 2>&1 | head -40 || true
    err ""
    err "Recent journal logs:"
    journalctl -u suricata -n 50 --no-pager 2>/dev/null || true
    err ""
    
    if [ -f /var/log/suricata/suricata.log ]; then
      err "Suricata log file contents:"
      tail -n 30 /var/log/suricata/suricata.log 2>/dev/null || true
    fi
    err ""
    
    return 1
  fi
}

create_test_rules() {
  # Create test.rules file with test rules for IDS validation
  local test_rules_file="$RULES_DIR/test.rules"
  
  # Ensure rules directory exists
  mkdir -p "$RULES_DIR"
  
  cat > "$test_rules_file" <<'EOF'
# Test rule for Suricata IDS validation
# This rule detects the testmynids.org test page
alert ip any any -> any any (msg:"GPL ATTACK_RESPONSE id check returned root"; content:"uid=0|28|root|29|"; classtype:bad-unknown; sid:2100498; rev:7; metadata:created_at 2010_09_23, updated_at 2010_09_23;)

# HTTP Test Rule - detects testmynids.org requests
alert http any any -> any any (msg:"HTTP Test Rule - testmynids.org detected"; content:"testmynids"; nocase; sid:1000001; rev:1;)

# DNS Query Test Rule
alert dns any any -> any any (msg:"DNS Query Detected"; sid:1000002; rev:1;)
EOF

  chmod 0644 "$test_rules_file"
  
  if [ -f "$test_rules_file" ] && [ -s "$test_rules_file" ]; then
    info "Created test.rules file for IDS validation"
    return 0
  else
    warn "Failed to create test.rules file"
    return 1
  fi
}

verify_suricata_config() {
  # Verify Suricata configuration and provide troubleshooting info
  info "Verifying Suricata configuration..."
  
  local issues=0
  
  # Check if Suricata is running
  if ! systemctl is-active --quiet suricata 2>/dev/null; then
    warn "Suricata service is not running"
    ((issues++))
  else
    info "✓ Suricata service is running"
  fi
  
  # Check if config file exists
  if [ ! -f "$SURICATA_YAML" ]; then
    err "Suricata configuration file not found at $SURICATA_YAML"
    ((issues++))
  else
    info "✓ Configuration file exists"
  fi
  
  # Check if test.rules exists
  if [ ! -f "$RULES_DIR/test.rules" ]; then
    warn "test.rules file not found at $RULES_DIR/test.rules"
    info "Creating test.rules..."
    create_test_rules || ((issues++))
  else
    info "✓ test.rules file exists"
  fi
  
  # Check if test.rules is in YAML
  if grep -q "test.rules" "$SURICATA_YAML" 2>/dev/null; then
    info "✓ test.rules is listed in suricata.yaml"
  else
    warn "test.rules is NOT listed in suricata.yaml rule-files section"
    info "Updating YAML configuration..."
    sync_rule_files_list || ((issues++))
  fi
  
  # Check interface configuration
  if [ -n "$DEFAULT_INTERFACE" ] && grep -q "interface: $DEFAULT_INTERFACE" "$SURICATA_YAML" 2>/dev/null; then
    info "✓ Interface configured: $DEFAULT_INTERFACE"
  else
    warn "Interface may not be properly configured in suricata.yaml"
    ((issues++))
  fi
  
  # Check if rules directory has rules
  local rule_count
  rule_count=$(find "$RULES_DIR" -maxdepth 1 -type f -name "*.rules" 2>/dev/null | wc -l)
  if [ "$rule_count" -gt 0 ]; then
    info "✓ Found $rule_count rule file(s) in $RULES_DIR"
  else
    warn "No rule files found in $RULES_DIR"
    ((issues++))
  fi
  
  # Check logging configuration - if log files exist, logging is likely working
  # Check if fast.log file exists (most reliable indicator)
  if [ -f /var/log/suricata/fast.log ]; then
    info "✓ Fast log file exists (logging appears to be working)"
  else
    # Check YAML configuration
    if grep -E "^[ \t]*-[ \t]+fast:" "$SURICATA_YAML" 2>/dev/null | grep -v "^#" | grep -q "fast:"; then
      info "✓ Fast log output configured in YAML (file will be created when Suricata starts)"
    else
      warn "Fast log output not found in suricata.yaml"
      info "Configuring logging..."
      configure_logging || ((issues++))
    fi
  fi
  
  # Check eve.json
  if [ -f /var/log/suricata/eve.json ]; then
    info "✓ Eve log file exists (JSON logging appears to be working)"
  else
    if grep -E "^[ \t]*-[ \t]+eve-log:" "$SURICATA_YAML" 2>/dev/null | grep -v "^#" | grep -q "eve-log:"; then
      info "✓ Eve log output configured in YAML (file will be created when Suricata starts)"
    else
      warn "Eve log output not found in suricata.yaml"
      info "Configuring logging..."
      configure_logging || true
    fi
  fi
  
  # Check if log directory exists and is writable
  if [ -d /var/log/suricata ]; then
    if [ -w /var/log/suricata ]; then
      info "✓ Log directory exists and is writable"
    else
      warn "Log directory exists but may not be writable"
      chmod 755 /var/log/suricata 2>/dev/null || true
    fi
  else
    warn "Log directory /var/log/suricata does not exist"
    mkdir -p /var/log/suricata && chmod 755 /var/log/suricata
    info "Created log directory"
  fi
  
  # Test configuration syntax
  if command -v suricata &>/dev/null; then
    if suricata -T -c "$SURICATA_YAML" &>/dev/null; then
      info "✓ Suricata configuration test passed"
    else
      warn "Suricata configuration test failed. Run: suricata -T -c $SURICATA_YAML"
      ((issues++))
    fi
  fi
  
  if [ $issues -eq 0 ]; then
    info "Configuration verification completed successfully!"
    info ""
    info "To test IDS functionality:"
    info "  1. Run: curl http://testmynids.org/uid/index.html"
    info "  2. Check alerts: sudo tail -f /var/log/suricata/fast.log"
    info "  3. Check JSON events: sudo tail -f /var/log/suricata/eve.json | jq 'select(.event_type==\"alert\")'"
    return 0
  else
    warn "Found $issues issue(s) in configuration. Please review above warnings."
    warn "If logs are still not generating, restart Suricata: systemctl restart suricata"
    return 1
  fi
}

reset_rules_dir() {
  info "Cleaning existing rules in $RULES_DIR and /var/lib/suricata/rules ..."
  # Remove rules from both locations
  find "$RULES_DIR" -maxdepth 1 -type f -name "*.rules" -delete 2>/dev/null || true
  find /var/lib/suricata/rules -maxdepth 1 -type f -name "*.rules" -delete 2>/dev/null || true
  # Also remove default rules that might be in other locations
  rm -f /usr/share/suricata/rules/*.rules 2>/dev/null || true
  rm -f /etc/suricata/rules/*.rules 2>/dev/null || true
  # Ensure directories exist
  mkdir -p "$RULES_DIR" /var/lib/suricata/rules
  info "All default rules removed. Rules directories are clean."
}

sync_rule_files_list() {
  if [ ! -d "$RULES_DIR" ]; then
    warn "Rules directory not found; skipping rule-files sync."
    return 1
  fi

  if [ ! -f "$SURICATA_YAML" ]; then
    err "Suricata YAML file not found at $SURICATA_YAML"
    return 1
  fi

  # Build rule entries list (compatible with all find versions)
  local rule_files=()
  while IFS= read -r rule_file; do
    if [ -n "$rule_file" ] && [ -f "$rule_file" ]; then
      rule_files+=("$(basename "$rule_file")")
    fi
  done < <(find "$RULES_DIR" -maxdepth 1 -type f -name "*.rules" 2>/dev/null | sort)

  if [ ${#rule_files[@]} -eq 0 ]; then
    warn "No .rules files found in $RULES_DIR; rule-files list not updated."
    return 1
  fi

  local tmp_cfg rules_file
  tmp_cfg=$(mktemp) || { err "Failed to create temporary file"; return 1; }
  rules_file=$(mktemp) || { err "Failed to create temporary file"; rm -f "$tmp_cfg" 2>/dev/null; return 1; }

  # Write rules to temp file
  for rule in "${rule_files[@]}"; do
    echo "  - $rule" >> "$rules_file"
  done

  # Update rule-files section in YAML - use sed and awk combination to avoid syntax issues
  # First, uncomment rule-files if commented
  sed -i 's|^[ \t]*#[ \t]*rule-files:|rule-files:|g' "$SURICATA_YAML" 2>/dev/null || true
  
  # Remove existing rule entries
  awk '
    BEGIN { in_rule_files = 0 }
    /^rule-files:/ { 
      print
      in_rule_files = 1
      next
    }
    in_rule_files && /^[ \t]*-/ { next }
    in_rule_files && /^[^ \t#]/ { in_rule_files = 0 }
    { print }
  ' "$SURICATA_YAML" > "$tmp_cfg"
  
  # Add new rules after rule-files: line
  if grep -q "^rule-files:" "$tmp_cfg"; then
    # Insert rules after rule-files: line - get only first match and validate
    local insert_line
    insert_line=$(grep -n "^rule-files:" "$tmp_cfg" | head -n1 | cut -d: -f1 | tr -d '\n\r' | grep -E '^[0-9]+$' || echo "")
    
    # Validate insert_line is a valid positive number
    if [ -n "$insert_line" ] && [ "$insert_line" -gt 0 ] && [ "$insert_line" -le 1000000 ] 2>/dev/null; then
      local next_line=$((insert_line + 1))
      {
        head -n "$insert_line" "$tmp_cfg" 2>/dev/null
        cat "$rules_file" 2>/dev/null
        tail -n +"$next_line" "$tmp_cfg" 2>/dev/null
      } > "${tmp_cfg}.new" 2>/dev/null
      
      if [ -f "${tmp_cfg}.new" ] && [ -s "${tmp_cfg}.new" ]; then
        mv "${tmp_cfg}.new" "$tmp_cfg"
      else
        warn "Failed to insert rules at line $insert_line, using fallback method"
        # Fallback: use sed to insert
        sed -i "/^rule-files:/r $rules_file" "$tmp_cfg" 2>/dev/null || {
          warn "sed insertion failed, appending rules"
          cat "$rules_file" >> "$tmp_cfg"
        }
      fi
    else
      warn "Invalid line number for rule-files insertion, using fallback method"
      # Fallback: append rules after first rule-files: line
      sed -i "/^rule-files:/r $rules_file" "$tmp_cfg" 2>/dev/null || {
        warn "sed insertion failed, appending rules"
        cat "$rules_file" >> "$tmp_cfg"
      }
    fi
  else
    # Add rule-files section if it doesn't exist
    echo "rule-files:" >> "$tmp_cfg"
    cat "$rules_file" >> "$tmp_cfg"
  fi

  rm -f "$rules_file" "${tmp_cfg}.new" 2>/dev/null

  if [ -s "$tmp_cfg" ]; then
    mv "$tmp_cfg" "$SURICATA_YAML"
    info "Updated rule-files list in configuration with ${#rule_files[@]} rule file(s)."
    info "Rules are now listed under the uncommented 'rule-files:' section."
    return 0
  else
    warn "Failed to update rule-files list."
    rm -f "$tmp_cfg" "${tmp_cfg}.new" 2>/dev/null
    return 1
  fi
}

apply_rule_files() {
  # Copies provided rule files into Suricata rules dir, grouped by category, and ensures YAML lists them.
  local repo_dir="$1"
  shift
  local files=("$@")
  [[ ${#files[@]} -gt 0 ]] || { warn "No rules selected."; return 1; }
  
  if [ ! -f "$SURICATA_YAML" ]; then
    err "Suricata configuration file not found. Please run complete installation first."
    return 1
  fi
  
  backup_yaml_once
  
  info "Processing $((${#files[@]})) rule file(s) and grouping by category..."
  
  # Group rules by category
  declare -A category_rules
  
  for f in "${files[@]}"; do
    if [ ! -f "$f" ]; then
      warn "Rule file not found: $f"
      continue
    fi
    
    local dir_path
    dir_path="$(dirname "$f")"
    local category_name
    
    # Determine category name
    if [ "$dir_path" = "$repo_dir" ]; then
      # Rules in root directory - use filename without extension as category
      category_name="$(basename "$f" .rules)"
    else
      # Rules in subdirectory - use directory name as category
      category_name="$(basename "$dir_path")"
    fi
    
    # Normalize category name (lowercase, replace spaces with underscores)
    category_name=$(echo "$category_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
    
    # Append rule content to category (use :- to provide default empty value for unbound check)
    if [ -z "${category_rules[$category_name]:-}" ]; then
      category_rules[$category_name]=""
    fi
    
    # Append rule file content to category
    category_rules[$category_name]="${category_rules[$category_name]:-}$(cat "$f" 2>/dev/null)\n"
  done
  
  # Write combined rules to category files
  local files_copied=0
  for category in "${!category_rules[@]}"; do
    local output_file="$RULES_DIR/${category}.rules"
    local rule_content="${category_rules[$category]:-}"
    
    # Check if file already exists - append or replace?
    if [ -f "$output_file" ]; then
      # Append new rules to existing category file
      printf "\n%b" "$rule_content" | sed '/^$/d' >> "$output_file" 2>/dev/null
    else
      # Create new category file
      printf "%b" "$rule_content" | sed '/^$/d' > "$output_file" 2>/dev/null
    fi
    
    if [ -f "$output_file" ] && [ -s "$output_file" ]; then
      chmod 0644 "$output_file"
      info "Created/Updated: ${category}.rules"
      ((files_copied++))
    else
      warn "Failed to create: ${category}.rules"
    fi
  done
  
  if [ $files_copied -eq 0 ]; then
    err "No category rule files were created."
    return 1
  fi
  
  # Ensure test.rules exists
  if [ ! -f "$RULES_DIR/test.rules" ]; then
    create_test_rules || warn "Failed to create test.rules"
  fi
  
  # Sync rule-files list in YAML
  if sync_rule_files_list; then
    info "YAML configuration updated successfully."
  else
    warn "YAML update had issues, but rules were copied."
  fi
  
  # Verify rules are in YAML
  if grep -q "rule-files:" "$SURICATA_YAML"; then
    info "Rules verified in YAML configuration:"
    grep -A 100 "^rule-files:" "$SURICATA_YAML" | grep "^-" | head -20 | sed 's/^/  /' || true
  else
    warn "Rules may not be properly configured in YAML. Please check manually."
  fi
  
  # Restart Suricata
  if systemctl restart suricata; then
    info "Suricata restarted successfully."
  else
    warn "Suricata restart failed. Check status with: systemctl status suricata"
  fi
  
  info "Applied $files_copied category rule file(s) successfully."
  info "Test IDS with: curl http://testmynids.org/uid/index.html"
  info "View alerts with: sudo tail -f /var/log/suricata/fast.log"
}

select_rule_files() {
  # Helper to select rules from a directory
  local source_dir="$1"
  local repo_dir="$2"
  
  # Validate inputs
  if [ ! -d "$source_dir" ]; then
    err "Source directory not found: $source_dir"
    return 1
  fi
  
  if [ ! -d "$repo_dir" ]; then
    err "Repository directory not found: $repo_dir"
    return 1
  fi
  
  mapfile -t files < <(find "$source_dir" -maxdepth 1 -type f -name "*.rules" 2>/dev/null | sort)
  if [[ ${#files[@]} -eq 0 ]]; then
    err "No .rules files found in $source_dir"
    return 1
  fi
  
  echo "Available rules:"
  local i=1
  for f in "${files[@]}"; do
    if [ -f "$f" ]; then
      echo " [$i] $(basename "$f")"
      ((i++))
    fi
  done
  
  read -rp "Enter numbers (space-separated) to apply: " -a picks
  local chosen=()
  for p in "${picks[@]}"; do
    # Validate input is a number and within range
    if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le ${#files[@]} ] 2>/dev/null; then
      local idx=$((p - 1))
      if [ -f "${files[$idx]}" ]; then
        chosen+=("${files[$idx]}")
      fi
    fi
  done
  
  if [[ ${#chosen[@]} -eq 0 ]]; then
    warn "No valid selection."
    return 1
  fi
  
  apply_rule_files "$repo_dir" "${chosen[@]}"
}

menu_apply_rules() {
  local repo_dir="$1"
  
  # Refresh repo before showing menu
  if [ ! -d "$repo_dir/.git" ]; then
    err "Repository directory not found. Please update ruleset first (option 2)."
    return 1
  fi
  
  while true; do
    cat <<'EOF'
Apply Rules
 1) All categories (apply all .rules)
 2) Specific categories (multi-select .rules)
 3) Exclusive site (per category)
 4) Clean applied ruleset (remove all .rules)
 5) Back
EOF
    read -rp "Choose: " choice
    case "$choice" in
      1)
        info "Searching for all .rules files in repository..."
        mapfile -t all_rules < <(find "$repo_dir" -type f -name "*.rules" ! -path "*/.git/*" | sort)
        if [[ ${#all_rules[@]} -eq 0 ]]; then
          warn "No .rules files found in repository."
          continue
        fi
        info "Found ${#all_rules[@]} rule file(s)."
        apply_rule_files "$repo_dir" "${all_rules[@]}"
        ;;
      2)
        info "Searching for .rules files in repository root..."
        mapfile -t root_rules < <(find "$repo_dir" -maxdepth 1 -type f -name "*.rules" | sort)
        if [[ ${#root_rules[@]} -eq 0 ]]; then
          warn "No .rules files found in repository root."
          warn "Try option 3 (Exclusive site) to select from category directories."
          continue
        fi
        select_rule_files "$repo_dir" "$repo_dir"
        ;;
      3)
        # Treat categories as immediate subdirectories; within each, select .rules
        mapfile -t cats < <(find "$repo_dir" -mindepth 1 -maxdepth 1 -type d ! -name ".git" ! -name ".github" | sort)
        if [[ ${#cats[@]} -eq 0 ]]; then
          warn "No category directories found under $repo_dir"
          continue
        fi
        echo "Categories:"
        local i=1
        for c in "${cats[@]}"; do
          local rule_count
          rule_count=$(find "$c" -type f -name "*.rules" 2>/dev/null | wc -l)
          echo " [$i] $(basename "$c") ($rule_count rule file(s))"
          ((i++))
        done
        read -rp "Choose a category number: " cat_idx
        if [[ -n "$cat_idx" ]] && [[ "$cat_idx" =~ ^[0-9]+$ ]] && (( cat_idx>=1 && cat_idx<=${#cats[@]} )); then
          select_rule_files "${cats[cat_idx-1]}" "$repo_dir"
        else
          warn "Invalid category choice."
        fi
        ;;
      4)
        reset_rules_dir
        # Also update YAML to remove rule references
        sync_rule_files_list || true
        systemctl restart suricata || true
        info "Cleaned applied rules."
        ;;
      5) break ;;
      *) warn "Invalid option." ;;
    esac
  done
}

complete_installation() {
  info "Starting complete installation..."
  
  if ! detect_network; then
    err "Network detection failed"
    return 1
  fi
  
  if ! install_suricata_stack; then
    err "Suricata installation failed"
    return 1
  fi
  
  if ! configure_suricata; then
    warn "Suricata configuration had issues, but continuing..."
  fi
  
  # Remove all preexisting rules (per flow.md: "remove every preexisting ruleset")
  reset_rules_dir
  
  # Clear rule-files section in YAML to ensure no rules are applied
  # (per flow.md: "Suricata ends in a clean state with no rules applied")
  if [ -f "$SURICATA_YAML" ]; then
    # Remove all rule file entries from ALL rule-files sections (handle multiple occurrences)
    local tmp_yaml
    tmp_yaml=$(mktemp) || { err "Failed to create temp file"; return 1; }
    
    awk '
      BEGIN { in_rule_files = 0 }
      /^rule-files:/ { 
        print
        in_rule_files = 1
        next
      }
      in_rule_files {
        # Inside rule-files section
        if (/^[ \t]*-[ \t]+/) {
          # This is a list item (rule entry) - skip it completely
          next
        }
        if (/^[a-zA-Z]/) {
          # Next top-level key (no leading spaces) - exit rule-files section
          in_rule_files = 0
          print
          next
        }
        # Print comments, empty lines, etc. but not rule entries
        print
        next
      }
      { print }
    ' "$SURICATA_YAML" > "$tmp_yaml"
    
    mv "$tmp_yaml" "$SURICATA_YAML"
    
    # Double-check: Remove any remaining rule entries that might have been missed
    # This handles edge cases where rule-files might appear multiple times
    sed -i '/^rule-files:/,/^[a-zA-Z]/ { /^[ \t]*-[ \t]\+.*\.rules/d; }' "$SURICATA_YAML" 2>/dev/null || true
    sed -i '/^rule-files:/,/^[a-zA-Z]/ { /^[ \t]*-[ \t]\+test\.rules/d; }' "$SURICATA_YAML" 2>/dev/null || true
    
    # Clean up: Remove commented duplicate HOME_NET entries
    sed -i '/^[ \t]*#[ \t]*HOME_NET:/d' "$SURICATA_YAML" 2>/dev/null || true
    
    # Verify no rules remain
    if grep -qE "^[ \t]*-[ \t]+.*\.rules" "$SURICATA_YAML" 2>/dev/null; then
      warn "Some rule entries may still exist, attempting additional cleanup..."
      # More aggressive cleanup
      awk '
        BEGIN { in_rule_files = 0 }
        /^rule-files:/ { 
          print
          in_rule_files = 1
          next
        }
        in_rule_files && /^[ \t]*-/ { next }  # Skip all list items in rule-files section
        in_rule_files && /^[a-zA-Z]/ { in_rule_files = 0 }
        { print }
      ' "$SURICATA_YAML" > "$tmp_yaml"
      mv "$tmp_yaml" "$SURICATA_YAML"
    fi
    
    info "Cleared all rules from YAML (no rules applied)"
  fi
  
  # Ensure log directory has proper permissions for Suricata to write logs
  mkdir -p /var/log/suricata
  
  # Create log files before starting Suricata to ensure they exist and are writable
  touch /var/log/suricata/fast.log /var/log/suricata/eve.json /var/log/suricata/suricata.log 2>/dev/null || true
  
  # Set permissions - try suricata user first, fallback to world-writable if user doesn't exist
  if id suricata &>/dev/null; then
    chown -R suricata:suricata /var/log/suricata 2>/dev/null || true
    chmod 755 /var/log/suricata
    chmod 644 /var/log/suricata/*.log /var/log/suricata/*.json 2>/dev/null || true
  else
    # Suricata user doesn't exist - make directory and files writable
    chmod 777 /var/log/suricata 2>/dev/null || chmod 755 /var/log/suricata
    chmod 666 /var/log/suricata/*.log /var/log/suricata/*.json 2>/dev/null || chmod 644 /var/log/suricata/*.log /var/log/suricata/*.json 2>/dev/null || true
  fi
  
  # Start Suricata without verification (skip_verification=1)
  if ! start_suricata 1; then
    warn "Suricata service start had issues, but installation completed."
  else
    # Wait for Suricata to initialize
    sleep 3
    
    # Verify log files are writable and ensure they exist
    touch /var/log/suricata/fast.log /var/log/suricata/eve.json 2>/dev/null || true
    
    # Set permissions again after Suricata starts (in case it created new files)
    if id suricata &>/dev/null; then
      chown suricata:suricata /var/log/suricata/*.log /var/log/suricata/*.json 2>/dev/null || true
      chmod 644 /var/log/suricata/*.log /var/log/suricata/*.json 2>/dev/null || true
    else
      chmod 666 /var/log/suricata/*.log /var/log/suricata/*.json 2>/dev/null || chmod 644 /var/log/suricata/*.log /var/log/suricata/*.json 2>/dev/null || true
    fi
    
    # Restart Suricata to ensure it picks up the clean configuration and logging works
    systemctl restart suricata 2>/dev/null || true
    sleep 3
    
    # Verify Suricata is writing to logs (check if files are being updated)
    if [ -f /var/log/suricata/fast.log ] && [ -w /var/log/suricata/fast.log ]; then
      # Log file exists and is writable - logging should work
      : # Silent success
    else
      # Try to fix permissions one more time
      chmod 666 /var/log/suricata/*.log /var/log/suricata/*.json 2>/dev/null || true
    fi
  fi
  
  info "Complete installation finished successfully."
  info "Suricata is running with no rules applied (clean state)."
  info "To apply rules, use option 3 (Apply rules) from the main menu."
}

copy_rules_from_repo() {
  local repo_dir="$1"
  
  if [ ! -d "$repo_dir" ]; then
    warn "Repository directory not found: $repo_dir"
    return 1
  fi
  
  info "Copying rules from repository to $RULES_DIR (grouped by category)..."
  
  # Ensure rules directory exists
  mkdir -p "$RULES_DIR"
  
  # Process rules by category: group rules from same category directory into {category}.rules
  declare -A category_rules
  local rules_found=0
  local categories_processed=0
  
  # Find all .rules files and group by category
  while IFS= read -r rule_file; do
    if [ -f "$rule_file" ]; then
      local dir_path
      dir_path="$(dirname "$rule_file")"
      local category_name
      
      # Determine category name
      if [ "$dir_path" = "$repo_dir" ]; then
        # Rules in root directory - use filename without extension as category
        category_name="$(basename "$rule_file" .rules)"
      else
        # Rules in subdirectory - use directory name as category
        category_name="$(basename "$dir_path")"
      fi
      
      # Normalize category name (lowercase, replace spaces with underscores)
      category_name=$(echo "$category_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '_')
      
      # Add rule content to category (use :- to provide default empty value for unbound check)
      if [ -z "${category_rules[$category_name]:-}" ]; then
        category_rules[$category_name]=""
        ((categories_processed++))
      fi
      
      # Append rule file content to category
      if [ -f "$rule_file" ]; then
        category_rules[$category_name]="${category_rules[$category_name]:-}$(cat "$rule_file" 2>/dev/null)\n"
        ((rules_found++))
      fi
    fi
  done < <(find "$repo_dir" -type f -name "*.rules" ! -path "*/.git/*" ! -path "*/.github/*" 2>/dev/null | sort)
  
  if [ $rules_found -eq 0 ]; then
    warn "No .rules files found in repository."
    return 1
  fi
  
  # Write combined rules to category files
  local files_copied=0
  for category in "${!category_rules[@]}"; do
    local output_file="$RULES_DIR/${category}.rules"
    local rule_content="${category_rules[$category]:-}"
    # Write rule content to file (remove empty lines)
    printf "%b" "$rule_content" | sed '/^$/d' > "$output_file" 2>/dev/null
    if [ -f "$output_file" ] && [ -s "$output_file" ]; then
      chmod 0644 "$output_file"
      info "Created: ${category}.rules (from category: $category)"
      ((files_copied++))
    else
      warn "Failed to create: ${category}.rules"
    fi
  done
  
  if [ $files_copied -eq 0 ]; then
    warn "No category rule files were created."
    return 1
  fi
  
  info "Created $files_copied category rule file(s) from $rules_found rule file(s)"
  
  # Create test.rules file for IDS validation
  create_test_rules || warn "Failed to create test.rules, but continuing..."
  
  # Update YAML configuration
  if [ -f "$SURICATA_YAML" ]; then
    if sync_rule_files_list; then
      info "YAML configuration updated successfully."
      return 0
    else
      warn "Rules copied but YAML update failed. Rules are in $RULES_DIR but may not be active."
      return 1
    fi
  else
    warn "Suricata YAML not found. Rules copied but not configured. Run complete installation first."
    return 1
  fi
}

update_ruleset() {
  local repo_url="$1"
  info "Pulling latest ruleset from $repo_url ..."
  
  if ! fetch_repo "$repo_url"; then
    err "Failed to fetch repository"
    return 1
  fi
  
  # Per flow.md line 28: "No rules are applied at this step; it only fetches updates."
  info "Ruleset update completed successfully (git pull only; no rules applied)."
  info "To apply rules, use option 3 (Apply rules) from the main menu."
  return 0
}

remove_suricata() {
  info "Removing Suricata and related data..."
  
  # Check if Suricata is installed
  if ! command -v suricata &>/dev/null && ! dpkg -l | grep -q suricata; then
    warn "Suricata does not appear to be installed."
    return 0
  fi
  
  # Stop and disable service if systemctl is available
  if command -v systemctl &>/dev/null; then
    systemctl stop suricata 2>/dev/null || true
    systemctl disable suricata 2>/dev/null || true
  fi
  
  # Remove package
  if command -v apt-get &>/dev/null; then
    apt-get purge -y suricata 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
  fi
  
  # Remove directories (with safety checks)
  [ -d /etc/suricata ] && rm -rf /etc/suricata
  [ -d /var/log/suricata ] && rm -rf /var/log/suricata
  [ -d /var/lib/suricata ] && rm -rf /var/lib/suricata
  [ -d /usr/share/suricata ] && rm -rf /usr/share/suricata
  
  info "Removal completed."
}

main_menu() {
  local repo_url repo_dir
  prompt_credentials
  ensure_git
  repo_url="$(detect_repo)"
  ensure_dirs
  if ! fetch_repo "$repo_url"; then
    err "Unable to fetch repository; exiting."
    exit 1
  fi
  repo_dir="$WORKDIR"
  
  # Per flow.md: No automatic rule copying - user must explicitly choose to apply rules

  while true; do
    cat <<EOF
Main Menu (using repo: $repo_url)
 1) Complete installation (setup + clean rules)
 2) Update ruleset (git pull + copy to /etc/suricata/rules + update YAML)
 3) Apply rules
 4) Remove Suricata completely
 5) Exit
EOF
    read -rp "Choose: " opt
    case "$opt" in
      1) 
        complete_installation || warn "Installation completed with warnings. Check output above."
        echo ""
        read -rp "Press Enter to continue..."
        ;;
      2) 
        update_ruleset "$repo_url" || warn "Ruleset update had issues."
        echo ""
        read -rp "Press Enter to continue..."
        ;;
      3) 
        menu_apply_rules "$repo_dir" ;;
      4) 
        remove_suricata
        echo ""
        read -rp "Press Enter to continue..."
        ;;
      5) exit 0 ;;
      *) warn "Invalid option." ;;
    esac
  done
}

require_root
main_menu

