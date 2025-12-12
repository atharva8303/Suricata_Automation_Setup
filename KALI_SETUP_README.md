# Suricata Automation Setup for Kali Linux

A comprehensive bash script for automating Suricata IDS/IPS installation, configuration, and rule management on Kali Linux systems.

## Overview

This script provides an automated solution for setting up and managing Suricata on Kali Linux. It handles installation, configuration, network detection, rule management, and service management through an interactive menu system.

## Features

- **Automated Installation**: Installs Suricata and all required dependencies
- **Network Detection**: Automatically detects network interface and IP configuration
- **Repository Management**: Handles Kali Linux repository setup (skips Debian backports)
- **Rule Management**: Provides flexible options for applying, updating, and managing IDS rules
- **YAML Configuration**: Automatically configures Suricata YAML with proper syntax
- **Service Management**: Handles Suricata service startup, restart, and status checks
- **Git Integration**: Supports both primary and demo rule repositories with credential management
- **Error Handling**: Comprehensive error detection and troubleshooting assistance

## Requirements

- **Operating System**: Kali Linux
- **Privileges**: Root access (run with `sudo`)
- **Network**: Active network connection
- **Dependencies**: The script will automatically install required packages:
  - `git`
  - `software-properties-common`
  - `apt-transport-https`
  - `curl`
  - `jq`
  - `lsb-release`

## Installation

1. **Download the script**:
   ```bash
   # Make sure you have the Kali_setup.sh file
   ```

2. **Make it executable**:
   ```bash
   chmod +x Kali_setup.sh
   ```

3. **Run as root**:
   ```bash
   sudo ./Kali_setup.sh
   ```

## Usage

### Main Menu Options

When you run the script, you'll see the following menu:

```
Main Menu (using repo: <repository_url>)
 1) Complete installation (setup + clean rules)
 2) Update ruleset (git pull + copy to /etc/suricata/rules + update YAML)
 3) Apply rules
 4) Remove Suricata completely
 5) Exit
```

#### Option 1: Complete Installation

Performs a full installation of Suricata:
- Detects network configuration (interface, IP, network)
- Installs Suricata and dependencies
- Configures Suricata YAML file
- Sets up logging outputs
- Starts Suricata service
- Removes all default rules (clean state)

**Note**: After complete installation, Suricata runs with no rules applied. Use Option 3 to apply rules.

#### Option 2: Update Ruleset

Updates the rule repository:
- Pulls latest changes from the configured repository
- Does NOT apply rules automatically
- Use Option 3 to apply updated rules

#### Option 3: Apply Rules

Provides sub-menu for rule management:
- **Option 1**: Apply all categories (all .rules files)
- **Option 2**: Apply specific categories (multi-select)
- **Option 3**: Apply rules from exclusive site (per category)
- **Option 4**: Clean applied ruleset (remove all .rules)
- **Option 5**: Back to main menu

#### Option 4: Remove Suricata

Completely removes Suricata:
- Stops and disables service
- Removes package
- Deletes configuration and log directories

#### Option 5: Exit

Exits the script.

## Git Repository Configuration

The script supports two repository modes:

### Primary Repository
- URL: `https://github.com/atharva8303/Suricata_Automation`
- Requires Git credentials (username/password or PAT)
- Set via environment variables or prompted during execution

### Demo Repository
- URL: `https://github.com/atharva8303/Demo_Rules`
- Public repository, no credentials required
- Used as fallback if primary repository is inaccessible

### Setting Credentials

**Method 1: Environment Variables**
```bash
export GIT_USERNAME="your_username"
export GIT_PASSWORD="your_password_or_pat"
sudo ./Kali_setup.sh
```

**Method 2: Interactive Prompt**
```bash
sudo ./Kali_setup.sh
# Script will prompt for credentials
# Leave blank to use demo repository
```

## Configuration Details

### Network Detection

The script automatically detects:
- Default network interface (from routing table)
- IP address of the interface
- Network CIDR notation

You can accept the detected values or manually specify an interface.

### Suricata Configuration

The script configures:
- **HOME_NET**: Detected network CIDR
- **Interface**: Detected or specified network interface
- **Logging**: Fast log and EVE JSON log outputs
- **Rule Path**: `/etc/suricata/rules`
- **YAML Compatibility**: Compatible with Suricata versions available in Kali repositories

### Rule Management

Rules are organized by category:
- Rules from the same category directory are grouped into `{category}.rules`
- Rules are copied to `/etc/suricata/rules/`
- YAML `rule-files` section is automatically updated
- Suricata service is restarted after rule changes

## File Locations

- **Configuration**: `/etc/suricata/suricata.yaml`
- **Rules Directory**: `/etc/suricata/rules/`
- **Log Directory**: `/var/log/suricata/`
- **Work Directory**: `/tmp/suricata_rules/` (temporary repository clone)
- **Backup**: `/etc/suricata/suricata.yaml.bak`

## Log Files

- **Fast Log**: `/var/log/suricata/fast.log` - Alert log (similar to Snort fast.log)
- **EVE JSON Log**: `/var/log/suricata/eve.json` - Structured JSON event log
- **Suricata Log**: `/var/log/suricata/suricata.log` - Suricata daemon log

## Troubleshooting

### Suricata Won't Start

1. **Check configuration syntax**:
   ```bash
   suricata -T -c /etc/suricata/suricata.yaml
   ```

2. **Check service status**:
   ```bash
   systemctl status suricata
   ```

3. **Check logs**:
   ```bash
   journalctl -u suricata -n 100
   tail -f /var/log/suricata/suricata.log
   ```

### Configuration Errors

Common issues:
- **YAML syntax errors**: The script attempts to fix these automatically
- **Interface not found**: Verify interface name with `ip link show`
- **Permission issues**: Ensure `/var/log/suricata` is writable by suricata user

### Rule Application Issues

- **Rules not loading**: Check `rule-files` section in YAML
- **No alerts**: Verify rules are in `/etc/suricata/rules/` and listed in YAML
- **Test rules**: Use `curl http://testmynids.org/uid/index.html` to trigger test alerts

## Testing IDS Functionality

After applying rules, test with:

```bash
# Trigger test alert
curl http://testmynids.org/uid/index.html

# View alerts
sudo tail -f /var/log/suricata/fast.log

# View JSON events
sudo tail -f /var/log/suricata/eve.json | jq 'select(.event_type=="alert")'
```

## Kali Linux-Specific Notes

### Repository Handling

- **Kali Linux**: Uses default Kali repositories (skips Debian backports)
- Suricata should be available in Kali's default repositories
- The script detects Kali and skips backports repository setup

### Suricata Version

- Uses Suricata version available in Kali repositories
- YAML configuration is compatible with standard Suricata versions
- Size formats use standard units (MiB, KiB, etc.)

## Script Functions

### Core Functions

- `require_root()` - Checks for root privileges
- `detect_network()` - Detects network configuration
- `install_suricata_stack()` - Installs Suricata and dependencies
- `configure_suricata()` - Configures Suricata YAML
- `start_suricata()` - Starts Suricata service
- `verify_suricata_config()` - Verifies configuration

### Rule Management Functions

- `apply_rule_files()` - Applies selected rule files
- `sync_rule_files_list()` - Updates YAML rule-files section
- `reset_rules_dir()` - Cleans rule directory
- `menu_apply_rules()` - Interactive rule application menu

### YAML Management Functions

- `install_corrected_yaml_template()` - Installs compatible YAML template
- `fix_yaml_syntax()` - Fixes YAML syntax issues
- `validate_yaml_syntax()` - Validates YAML configuration
- `configure_logging()` - Configures logging outputs
- `remove_duplicate_keys()` - Removes duplicate YAML keys
- `fix_yaml_structure_issues()` - Fixes YAML structure problems

## Environment Variables

- `GIT_USERNAME` - Git username for repository access
- `GIT_PASSWORD` - Git password or Personal Access Token
- `GIT_TOKEN` - Alternative to username/password (token-based auth)

## Exit Codes

- `0` - Success
- `1` - Error (installation failure, configuration error, etc.)

## Security Considerations

- Script requires root privileges
- Git credentials are handled securely (not echoed)
- Log files may contain sensitive network information
- Ensure proper file permissions on configuration and log files

## Code Flow

### Main Flow

1. **Root Check**: Verifies script is run as root
2. **Main Menu**: Displays interactive menu
3. **Credential Prompt**: Asks for Git credentials (optional)
4. **Repository Detection**: Selects primary or demo repository
5. **Repository Fetch**: Clones or updates repository
6. **Menu Options**: User selects operation

### Installation Flow

1. **Network Detection**: Detects interface and network
2. **Package Installation**: Installs Suricata and dependencies
3. **YAML Configuration**: Configures Suricata YAML
4. **Rule Cleanup**: Removes default rules
5. **Service Start**: Starts Suricata service

### Rule Application Flow

1. **Rule Selection**: User selects rules to apply
2. **Category Grouping**: Rules grouped by category
3. **File Creation**: Creates category rule files
4. **YAML Update**: Updates rule-files section
5. **Service Restart**: Restarts Suricata

## YAML Template Features

The script installs a comprehensive YAML template with:

- **Network Configuration**: HOME_NET and EXTERNAL_NET variables
- **Logging Outputs**: Fast log and EVE JSON log configured
- **App Layer Protocols**: HTTP, DNS, TLS, SMTP, FTP, RDP, SSH, etc.
- **Performance Tuning**: Memory caps, flow timeouts, threading
- **Capture Methods**: af-packet, pcap, pfring, netmap support
- **Rule Management**: Empty rule-files section ready for rules

## Differences from Debian Setup

Key differences in Kali setup:

1. **Repository**: Uses Kali default repos (no backports)
2. **OS Detection**: Specifically detects Kali and skips backports
3. **YAML Format**: Uses MiB/KiB format (compatible with newer Suricata)
4. **Protocol Support**: Includes additional protocols (mdns, websocket, doh2, quic, ldap, pop3, ike, bittorrent-dht)

## Support

For issues or questions:
1. Check the troubleshooting section
2. Review Suricata logs
3. Verify configuration with `suricata -T -c /etc/suricata/suricata.yaml`

## License

This script is provided as-is for Suricata automation on Kali Linux systems.

## Version

Compatible with:
- Kali Linux (all recent versions)
- Suricata (version available in Kali repos)
- Systemd service manager

## Author Notes

This script was specifically adapted for Kali Linux systems, with:
- Kali-specific repository handling
- YAML syntax validation and correction
- Network interface detection
- Rule management and organization
- Comprehensive error handling

## Quick Reference

```
┌─────────────────────────────────────────┐
│      KALI SURICATA AUTOMATION            │
├─────────────────────────────────────────┤
│ 1. Complete Installation                 │
│    → Setup + Clean Rules                 │
│                                         │
│ 2. Update Ruleset                        │
│    → Git Pull Only                      │
│                                         │
│ 3. Apply Rules                           │
│    → All / Specific / Site-specific     │
│                                         │
│ 4. Remove Suricata                       │
│    → Complete Uninstall                 │
│                                         │
│ 5. Exit                                  │
└─────────────────────────────────────────┘

Logs: /var/log/suricata/
Config: /etc/suricata/suricata.yaml
Rules: /etc/suricata/rules/
```

---

**Happy Hunting! 🎯**

