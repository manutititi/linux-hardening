#!/bin/bash
set -e

# Configuration
PLAYBOOK="playbooks/harden.yml"
REPORTS_DIR="reports"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
REPORT_PATH="${REPORTS_DIR}/${TIMESTAMP}"

# Activate virtual environment if it exists
if [ -d ".venv-ansible" ]; then
    source .venv-ansible/bin/activate
fi

# Ensure reports dir exists
mkdir -p "$REPORT_PATH"

echo "Starting Ansible Execution..."
echo "Reports location: $REPORT_PATH"

# 1. Gather Target Info (Facts)
# We run this separately to get a clean set of facts for the report header, 
# although the playbook also gathers facts, this is getting raw setup data to a file.
echo "Gathering target info..."
# -m setup returns a JSON per host like host | SUCCESS => { "ansible_facts": ... }
# We use --tree to save clean JSON per host.
ANSIBLE_STDOUT_CALLBACK=json ansible all -m setup --tree "$REPORT_PATH/facts" -i inventories/lab/inventory.yml > /dev/null 2>&1 || true

# Pick the first fact file as target info source
TARGET_INFO_FILE=$(find "$REPORT_PATH/facts" -type f | head -n 1)
if [ -z "$TARGET_INFO_FILE" ]; then
    echo "Warning: No fact file found."
    TARGET_INFO_FILE="none"
fi

# 2. Run Ansible Playbook using JSON callback
# ...

# 2. Run Ansible Playbook using JSON callback
echo "Running Playbook..."
# We capture both stdout and stderr (though JSON callback should be stdout)
export ANSIBLE_DEPRECATION_WARNINGS=False
ANSIBLE_STDOUT_CALLBACK=json ansible-playbook "$PLAYBOOK" > "$REPORT_PATH/playbook_output.json"

# 3. Generate PDF Report
echo "Generating PDF Report..."
PYTHON_CMD="python3"
if [ -f ".venv-ansible/bin/python" ]; then
    PYTHON_CMD=".venv-ansible/bin/python"
fi
$PYTHON_CMD scripts/generate_pdf.py "$REPORT_PATH/playbook_output.json" "$TARGET_INFO_FILE" "$REPORT_PATH"

# 4. Display Quick Summary to Console (using jq)
echo "---------------------------------------------------"
echo "Execution Complete."
echo "---------------------------------------------------"
if command -v jq >/dev/null; then
    cat "$REPORT_PATH/playbook_output.json" | jq -r '
    ["Host", "Task", "Status", "Changed"],
    ["----", "----", "------", "-------"],
    (.plays[0].tasks[] | . as $task | .hosts | to_entries[] | 
    [$task.task.name, .key, (if .value.failed then "FAILED" elif .value.skipped then "SKIPPED" elif .value.unreachable then "UNREACHABLE" else "OK" end), .value.changed]) | @tsv' | column -t -s $'\t'
else
    echo "Install 'jq' to see a summary table here."
fi

echo ""
echo "Files generated:"
echo "- JSON Output: $REPORT_PATH/playbook_output.json"
echo "- Unified JSON: $REPORT_PATH/final_report.json"
echo "- PDF Report:  $REPORT_PATH/report.pdf"
