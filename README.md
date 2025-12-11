# Suricata Automation Script - flow.sh

A comprehensive bash script for automating Suricata IDS/IPS installation, configuration, and rule management on Linux systems.

## 📋 Table of Contents

- [Overview](#overview)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Code Flow Diagram](#code-flow-diagram)
- [Usage Guide](#usage-guide)
- [Menu Options](#menu-options)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)
- [Examples](#examples)

## 🎯 Overview

`flow.sh` is an automated script that simplifies Suricata IDS/IPS setup and management. It handles:
- Complete Suricata installation with proper configuration
- Network interface detection and configuration
- Rule management from GitHub repositories
- YAML configuration management
- Logging setup and verification

The script automatically selects between primary and demo repositories based on provided Git credentials.

## 🔄 Code Flow Diagram

### Main Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    START: flow.sh                          │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  require_root()      │
              │  Check if root user  │
              └──────────┬────────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  main_menu()         │
              └──────────┬────────────┘
                         │
                         ▼
        ┌────────────────────────────────┐
        │  prompt_credentials()          │
        │  - Ask for Git username/PAT   │
        │  - Can be left blank           │
        └────────────┬───────────────────┘
                     │
                     ▼
        ┌────────────────────────────┐
        │  detect_repo()             │
        │  - Check credentials       │
        │  - Select primary or demo  │
        └────────────┬───────────────┘
                     │
                     ▼
        ┌────────────────────────────┐
        │  fetch_repo()              │
        │  - Clone/Pull repository   │
        └────────────┬───────────────┘
                     │
                     ▼
        ┌─────────────────────────────────────────────┐
        │           MAIN MENU                        │
        │                                             │
        │  1) Complete installation                   │
        │  2) Update ruleset                          │
        │  3) Apply rules                             │
        │  4) Remove Suricata completely              │
        │  5) Exit                                    │
        └─────────────────────────────────────────────┘
```

### Option 1: Complete Installation Flow

```
┌─────────────────────────────────────────────────────────────┐
│         Option 1: Complete Installation                     │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  detect_network()   │
              │  - Auto-detect       │
              │  - Ask confirmation │
              └──────────┬────────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │ install_suricata_     │
              │   stack()            │
              │  - Install deps      │
              │  - Install Suricata  │
              │  - Install template  │
              └──────────┬────────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │ configure_suricata() │
              │  - Update HOME_NET   │
              │  - Update interface  │
              │  - Configure logging │
              └──────────┬───────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  reset_rules_dir()   │
              │  - Remove all rules │
              └──────────┬───────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  Clear rule-files   │
              │  section in YAML    │
              └──────────┬───────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  start_suricata(1)   │
              │  - Skip verification │
              │  - Start service     │
              └──────────┬───────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  Setup log files     │
              │  - Create files      │
              │  - Set permissions   │
              └──────────────────────┘
```

### Option 2: Update Ruleset Flow

```
┌─────────────────────────────────────────────────────────────┐
│         Option 2: Update Ruleset                           │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  fetch_repo()        │
              │  - Git pull latest  │
              └──────────┬───────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  Repository updated  │
              │  (No rules applied) │
              └──────────────────────┘
```

### Option 3: Apply Rules Flow

```
┌─────────────────────────────────────────────────────────────┐
│         Option 3: Apply Rules                               │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
        ┌────────────────────────────────┐
        │     Apply Rules Sub-Menu       │
        │                                │
        │  1) All categories             │
        │  2) Specific categories         │
        │  3) Exclusive site (per cat)    │
        │  4) Clean applied ruleset       │
        │  5) Back                        │
        └────────────────────────────────┘
                         │
        ┌────────────────┼────────────────┐
        │                │                │
        ▼                ▼                ▼
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│ Option 3.1   │  │ Option 3.2   │  │ Option 3.3   │
│ All Rules    │  │ Specific     │  │ Site-specific│
└──────┬───────┘  └──────┬───────┘  └──────┬───────┘
       │                 │                  │
       └─────────────────┼──────────────────┘
                        │
                        ▼
              ┌──────────────────────┐
              │  apply_rule_files() │
              │  - Group by category│
              │  - Copy to rules dir│
              └──────────┬───────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │ sync_rule_files_    │
              │   list()            │
              │  - Update YAML       │
              └──────────┬───────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  Restart Suricata    │
              └──────────────────────┘
```

### Option 4: Remove Suricata Flow

```
┌─────────────────────────────────────────────────────────────┐
│         Option 4: Remove Suricata                           │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  Stop & Disable      │
              │  Suricata service    │
              └──────────┬───────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  Uninstall Suricata │
              │  package            │
              └──────────┬──────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  Remove directories │
              │  - /etc/suricata    │
              │  - /var/log/suricata│
              │  - /var/lib/suricata│
              └──────────────────────┘
```

### YAML Configuration Flow

```
┌─────────────────────────────────────────────────────────────┐
│         YAML Configuration Process                          │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  Backup YAML         │
              │  (if not exists)    │
              └──────────┬────────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  Pre-validate YAML  │
              │  - Check syntax      │
              └──────────┬───────────┘
                         │
                    ┌────┴────┐
                    │ Valid?  │
                    └────┬────┘
                    No   │   Yes
                    │    │    │
                    ▼    │    │
        ┌──────────────┐ │    │
        │ fix_yaml_    │ │    │
        │  syntax()    │ │    │
        └──────┬───────┘ │    │
               │         │    │
               └─────────┘    │
                              │
                              ▼
              ┌──────────────────────┐
              │  Update Configuration│
              │  - HOME_NET          │
              │  - Interface         │
              │  - Logging           │
              └──────────┬───────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  Remove duplicates  │
              │  - enabled keys     │
              └──────────┬──────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  Validate YAML      │
              │  - Test syntax      │
              └──────────┬───────────┘
                         │
                    ┌────┴────┐
                    │ Valid?  │
                    └────┬────┘
                    No   │   Yes
                    │    │    │
                    ▼    │    │
        ┌──────────────┐ │    │
        │ Restore      │ │    │
        │ backup       │ │    │
        └──────────────┘ │    │
                         │    │
                         └────┘
                              │
                              ▼
              ┌──────────────────────┐
              │  Configuration      │
              │  Complete           │
              └──────────────────────┘
```

### Authentication & Repository Selection Flow

```
┌─────────────────────────────────────────────────────────────┐
│         Authentication Flow                                 │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  Check Environment   │
              │  Variables           │
              │  - GIT_USERNAME      │
              │  - GIT_PASSWORD      │
              │  - GIT_TOKEN         │
              └──────────┬────────────┘
                         │
                         ▼
              ┌──────────────────────┐
              │  Prompt Credentials │
              │  (if not set)       │
              └──────────┬──────────┘
                         │
                         ▼
        ┌────────────────────────────────┐
        │  Credentials Provided?         │
        └────────────┬───────────────────┘
                     │
            Yes      │      No
            │        │        │
            ▼        │        ▼
    ┌──────────────┐ │  ┌──────────────┐
    │ Test Primary │ │  │ Use Demo Repo │
    │ Repository   │ │  │ (Public)     │
    └──────┬───────┘ │  └──────┬───────┘
           │         │         │
           │         │         │
           └─────────┼─────────┘
                     │
                     ▼
        ┌──────────────────────┐
        │  build_auth_repo_   │
        │    url()            │
        │  - Add credentials  │
        │    to URL           │
        └──────────┬──────────┘
                   │
                   ▼
        ┌──────────────────────┐
        │  fetch_repo()        │
        │  - Clone/Pull        │
        └──────────────────────┘
```

## ✨ Features

- **Automatic Installation**: Complete Suricata setup with dependencies
- **Network Detection**: Auto-detects network interface and IP configuration
- **Repository Management**: Supports primary and demo repositories
- **Rule Management**: Apply rules by category or site-specific
- **YAML Configuration**: Automatic YAML syntax fixing and validation
- **Logging Setup**: Configures fast.log and eve.json outputs
- **Clean State**: Ensures no rules remain after complete installation
- **Error Recovery**: Automatic YAML backup and restoration on errors

## 📦 Prerequisites

- **Operating System**: Linux (Debian, Ubuntu, Kali Linux, or similar)
- **Permissions**: Root access (run with `sudo`)
- **Internet**: Active internet connection for package installation and repository access
- **Dependencies**: The script will install required packages automatically

## 🚀 Quick Start

### 1. Download the Script

```bash
# Make sure you have the flow.sh file in your current directory
ls -la flow.sh
```

### 2. Make it Executable

```bash
chmod +x flow.sh
```

### 3. Run the Script

```bash
sudo ./flow.sh
```

The script will:
1. Prompt for Git credentials (optional - leave blank for demo repository)
2. Detect your network configuration
3. Show the main menu

## 📖 Usage Guide

### Initial Setup

When you first run the script, you'll be prompted for Git credentials:

```
Enter git credentials (leave blank to use demo repository):
  Username: [your_username or leave blank]
  Password/PAT: [your_password/PAT or leave blank]
```

**Options:**
- **With Credentials**: Access to primary repository (`Suricata_Automation`)
- **Without Credentials**: Uses demo repository (`Demo_Rules`) - read-only access

### Environment Variables (Optional)

You can also set credentials as environment variables:

```bash
export GIT_USERNAME="your_username"
export GIT_PASSWORD="your_password_or_pat"
sudo ./flow.sh
```

Or use a Git token:

```bash
export GIT_TOKEN="your_personal_access_token"
sudo ./flow.sh
```

## 🎮 Menu Options

### Main Menu

```
Main Menu (using repo: https://github.com/...)
 1) Complete installation (setup + clean rules)
 2) Update ruleset (git pull + copy to /etc/suricata/rules + update YAML)
 3) Apply rules
 4) Remove Suricata completely
 5) Exit
```

### Option 1: Complete Installation

**What it does:**
- Detects network interface and IP configuration
- Installs Suricata and all dependencies
- Configures Suricata YAML with detected network settings
- Sets up logging (fast.log and eve.json)
- **Removes all existing rules** (clean state)
- Starts Suricata service

**When to use:**
- First-time installation
- Fresh setup on a new system
- Reset to clean state

**Result:**
- Suricata installed and running
- No rules applied (clean state)
- Ready to apply rules via Option 3

### Option 2: Update Ruleset

**What it does:**
- Pulls latest rules from selected repository (git pull)
- **Does NOT apply rules** - only fetches updates
- Updates local repository copy

**When to use:**
- After rules have been updated in the repository
- Before applying new rules

**Result:**
- Repository updated with latest rules
- Rules ready to be applied via Option 3

### Option 3: Apply Rules

**Sub-menu options:**

```
Apply Rules
 1) All categories (apply all .rules)
 2) Specific categories (multi-select .rules)
 3) Exclusive site (per category)
 4) Clean applied ruleset (remove all .rules)
 5) Back
```

#### 3.1 All Categories
- Applies **all** `.rules` files from the repository
- Groups rules by category automatically
- Updates YAML configuration
- Restarts Suricata

#### 3.2 Specific Categories
- Shows list of available rule files
- Select multiple files by entering numbers (e.g., `1 3 5`)
- Applies only selected rules
- Updates YAML automatically

#### 3.3 Exclusive Site (per category)
- Lists category directories
- Select a category
- Shows site-specific rules within that category
- Multi-select site rules
- Rules are grouped into category files (e.g., `games.rules`)

#### 3.4 Clean Applied Ruleset
- Removes all applied rules
- Clears rule-files section in YAML
- **Does NOT uninstall Suricata**
- Restarts Suricata with no rules

### Option 4: Remove Suricata Completely

**What it does:**
- Stops and disables Suricata service
- Uninstalls Suricata package
- Removes all configuration files
- Removes all log files
- Removes all rules
- Complete cleanup

**Warning:** This is irreversible. All Suricata data will be lost.

## ⚙️ Configuration

### Network Configuration

The script automatically detects:
- Default network interface (e.g., `eth0`, `ens33`)
- IP address
- Network CIDR (e.g., `192.168.75.0/24`)

You can accept the detected values or manually specify an interface.

### YAML Configuration

The script automatically:
- Updates `HOME_NET` with detected network
- Configures `af-packet` interface
- Sets up logging outputs
- Manages `rule-files` section
- Fixes YAML syntax errors

**Configuration file location:** `/etc/suricata/suricata.yaml`

### Log Files

Logs are stored in `/var/log/suricata/`:
- **fast.log**: Alert log (similar to Snort's fast.log)
- **eve.json**: JSON event log (structured data)
- **suricata.log**: Suricata daemon log

**View logs:**
```bash
# View alerts
sudo tail -f /var/log/suricata/fast.log

# View JSON events
sudo tail -f /var/log/suricata/eve.json | jq 'select(.event_type=="alert")'

# View daemon log
sudo tail -f /var/log/suricata/suricata.log
```

## 🔧 Troubleshooting

### Suricata Won't Start

**Check service status:**
```bash
sudo systemctl status suricata
```

**Check configuration:**
```bash
sudo suricata -T -c /etc/suricata/suricata.yaml
```

**Common issues:**
1. **YAML syntax errors**: Script automatically fixes these, but check logs if issues persist
2. **Interface not found**: Verify interface exists with `ip link show`
3. **Permission issues**: Ensure log directory is writable

### Logs Not Appearing

**Check log file permissions:**
```bash
ls -la /var/log/suricata/
```

**Ensure Suricata is running:**
```bash
sudo systemctl status suricata
```

**Check if logs are configured:**
```bash
grep -A 5 "fast:" /etc/suricata/suricata.yaml
grep -A 5 "eve-log:" /etc/suricata/suricata.yaml
```

### Rules Not Applied

**Verify rules exist:**
```bash
ls -la /etc/suricata/rules/
```

**Check YAML rule-files section:**
```bash
grep -A 10 "rule-files:" /etc/suricata/suricata.yaml
```

**Restart Suricata:**
```bash
sudo systemctl restart suricata
```

### Repository Access Issues

**If using credentials:**
- Verify username and password/PAT are correct
- Check if repository is accessible: `git ls-remote <repo_url>`

**If using demo repository:**
- Demo repository is public, no credentials needed
- If access fails, check internet connection

## 📝 Examples

### Example 1: First-Time Installation

```bash
# Run the script
sudo ./flow.sh

# Enter credentials (or leave blank for demo)
Username: [leave blank]
Password: [leave blank]

# Select option 1 (Complete installation)
Choose: 1

# Accept detected network interface
Use detected interface 'eth0'? (y/n): y

# Installation completes with no rules applied
# Now apply rules via option 3
```

### Example 2: Apply Specific Rules

```bash
# Run script
sudo ./flow.sh

# Select option 3 (Apply rules)
Choose: 3

# Select option 2 (Specific categories)
Choose: 2

# Select rules (e.g., rules 1 and 3)
Enter numbers (space-separated) to apply: 1 3

# Rules are applied and Suricata restarts
```

### Example 3: Update and Apply New Rules

```bash
# Run script
sudo ./flow.sh

# Select option 2 (Update ruleset)
Choose: 2
# Latest rules are pulled from repository

# Select option 3 (Apply rules)
Choose: 3

# Select option 1 (All categories)
Choose: 1
# All rules are applied
```

### Example 4: Clean Ruleset

```bash
# Run script
sudo ./flow.sh

# Select option 3 (Apply rules)
Choose: 3

# Select option 4 (Clean applied ruleset)
Choose: 4
# All rules removed, Suricata restarts with no rules
```

## 📁 File Locations

| Item | Location |
|------|----------|
| Suricata Config | `/etc/suricata/suricata.yaml` |
| Rules Directory | `/etc/suricata/rules/` |
| Log Directory | `/var/log/suricata/` |
| Fast Log | `/var/log/suricata/fast.log` |
| Eve JSON Log | `/var/log/suricata/eve.json` |
| Daemon Log | `/var/log/suricata/suricata.log` |
| Repository Cache | `/tmp/suricata_rules/` |
| Config Backup | `/etc/suricata/suricata.yaml.bak` |

## 🔍 Testing IDS Functionality

After applying rules, test your IDS:

```bash
# Test with known malicious content
curl http://testmynids.org/uid/index.html

# Check for alerts
sudo tail -f /var/log/suricata/fast.log

# View JSON alerts
sudo tail -f /var/log/suricata/eve.json | jq 'select(.event_type=="alert")'
```

## 📚 Additional Commands

### Check Suricata Status
```bash
sudo systemctl status suricata
```

### Restart Suricata
```bash
sudo systemctl restart suricata
```

### Stop Suricata
```bash
sudo systemctl stop suricata
```

### View Recent Alerts
```bash
sudo tail -n 50 /var/log/suricata/fast.log
```

### Count Total Alerts
```bash
sudo wc -l /var/log/suricata/fast.log
```

### Test Configuration
```bash
sudo suricata -T -c /etc/suricata/suricata.yaml
```

## 🛡️ Security Notes

- **Credentials**: Git credentials are not logged or displayed
- **Permissions**: Script requires root access for system configuration
- **Backups**: YAML files are automatically backed up before modifications
- **Validation**: All YAML changes are validated before applying

## 📞 Support

For issues or questions:
1. Check the troubleshooting section above
2. Review Suricata logs: `/var/log/suricata/suricata.log`
3. Test configuration: `suricata -T -c /etc/suricata/suricata.yaml`

## 📄 License

This script is provided as-is for Suricata automation and management.

## 🔄 Version Information

- **Script Version**: Based on flow.md specifications
- **Suricata Compatibility**: Suricata 8.0+
- **Tested On**: Kali Linux, Ubuntu, Debian

---

## Quick Reference Card

```
┌─────────────────────────────────────────┐
│         SURICATA AUTOMATION             │
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

