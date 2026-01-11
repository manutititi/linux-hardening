# Linux Hardening

This project provides a comprehensive automation suite for hardening Linux systems using Ansible. It includes various security roles to secure SSH, Auditd, install Fail2Ban, set up integrity scanning, and optionally deploy Cowrie (Honeypot) and Port Knocking.


> [!IMPORTANT]
> **Before running the playbook**, please ensure you update the inventory file [`inventories/lab/inventory.yml`](file:///home/manu/own/digi/bastionado/linux-hardening/inventories/lab/inventory.yml) with your own server details (IP address, SSH user, key path, etc.).

## Installation

To get started, clone the repository and run the installation script. This script handles the creation of a Python virtual environment and installs all necessary Ansible dependencies and collections.

```bash
git clone https://github.com/manutititi/linux-hardening.git
cd linux-hardening
./install.sh
source .venv-ansible/bin/activate
```

The `./install.sh` script will:
1.  Create a local `.venv-ansible` virtual environment.
2.  Install Ansible and required Python libraries.
3.  Install Ansible collections and roles defined in `requirements.yml`.

## Usage

You can run the hardening process in two ways: using the automated reporting script or directly with `ansible-playbook`.

### Option 1: Reporting Script (Recommended)

The project includes a helper script that runs the playbook and generates a PDF report detailing the actions taken and the state of the target system.

```bash
./scripts/reportharden.sh
```

This script will:
1.  Gather facts from the target hosts.
2.  Execute the `playbooks/harden.yml` playbook.
3.  Generate a JSON and PDF report in the `reports/` directory.

### Option 2: Direct Ansible Execution

If you prefer to run Ansible directly or want to pass specific flags:

```bash
ansible-playbook playbooks/harden.yml -i inventories/lab/inventory.yml
```

*(Note: Ensure you update the inventory file path to match your environment)*

## Features

The playbook applies the following security measures:

*   **Base Prep**: Basic system preparation and package updates.
*   **OS Hardening**: Applies general OS-level security configurations (kernel parameters, etc.).
*   **SSH Hardening**: Secures simple SSH configuration (disabling root login, strong ciphers, etc.).
*   **Fail2Ban**: Installs and configures Fail2Ban to protect against brute-force attacks.
*   **Auditd**: Configures the Linux Audit daemon for system monitoring.
*   **Integrity Scanning**: Sets up file integrity monitoring tools.
*   **System Banners**: Configures legal/warning banners on login.
*   **Cowrie (Optional)**: Deploys a Cowrie SSH/Telnet honeypot to trap attackers.
*   **Port Knocking (Optional)**: Hides SSH behind a port knocking sequence.
*   **SL**: Just for fun (Steam Locomotive).

## Configuration

### Disabling Optional Roles

By default, the playbook includes **Cowrie** and **Port Knocking**. If you do not wish to install these components, you can simply comment them out in the hardening playbook file.

Edit `playbooks/harden.yml`:

```yaml
    # - role: cowrie
    #   tags: cowrie

    # - role: port-knock
    #   tags: port-knock
```

### Default Options

Most configuration variables are defined in the `defaults/main.yml` file of each role. You can override these variables in your `group_vars` or `inventory` files.

Key locations for defaults:
*   **SSH**: `roles/devsec.hardening.ssh_hardening/defaults/main.yml`
*   **Cowrie**: `roles/cowrie/defaults/main.yml` (e.g., honeypot port, data directory)
*   **Port Knocking**: `roles/port-knock/defaults/main.yml` (e.g., knock sequence, interface)
*   **Fail2Ban**: `roles/fail2ban_hardening/defaults/main.yml`

Feel free to explore the `roles/` directory to see all available configuration options.
