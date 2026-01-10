
import json
import sys
import os
from fpdf import FPDF
from fpdf.enums import XPos, YPos
from datetime import datetime

# A4 width is 210mm.
# Margins approx 10mm each side => ~190mm writable.
MARGIN_LEFT = 10
MARGIN_RIGHT = 10
PAGE_WIDTH = 210
WRITABLE_WIDTH = PAGE_WIDTH - MARGIN_LEFT - MARGIN_RIGHT

# Task Table Columns
COL_WIDTH_STATUS = 30
COL_WIDTH_CHANGED = 20
COL_WIDTH_TASK = WRITABLE_WIDTH - COL_WIDTH_STATUS - COL_WIDTH_CHANGED

def clean_task_name(task_name):
    if ' : ' in task_name:
        parts = task_name.split(' : ', 1)
        return parts[1]
    return task_name

def generate_report(playbook_json_file, facts_file, report_dir):
    # 1. READ PLAYBOOK OUTPUT
    try:
        with open(playbook_json_file, 'r') as f:
            playbook_data = json.load(f)
    except Exception as e:
        print(f"Error loading playbook json: {e}")
        return

    # 2. READ FACTS
    facts_data = {}
    fact_error = None
    if facts_file and facts_file != "none" and os.path.exists(facts_file):
        try:
             with open(facts_file, 'r') as f:
                raw_facts = json.load(f)
                if 'ansible_facts' in raw_facts:
                    facts_data = raw_facts['ansible_facts']
                elif raw_facts.get('unreachable'):
                    fact_error = f"UNREACHABLE: {raw_facts.get('msg', 'Unknown Error')}"
                elif raw_facts.get('failed'):
                    fact_error = f"FAILED: {raw_facts.get('msg', 'Unknown Error')}"
        except Exception as e:
            print(f"Error loading facts file: {e}")

    # FALLBACK: Try to find facts in playbook execution if setup failed
    if (not facts_data) and ('plays' in playbook_data):
        print("Using fallback facts from playbook output...")
        for play in playbook_data['plays']:
            for task in play['tasks']:
                 # We want the 'gather_facts' task results
                if task['task']['name'] == 'Gathering Facts' or task['task']['action'] == 'gather_facts':
                    for host, res in task['hosts'].items():
                        if 'ansible_facts' in res:
                            facts_data = res['ansible_facts']
                            fact_error = None
                            break
                if facts_data: break
            if facts_data: break

    # 3. EXTRACTION for Report
    mem_total_mb = facts_data.get('ansible_memtotal_mb', 0)
    mem_total_gb = round(mem_total_mb / 1024, 2)
    
    processor_list = facts_data.get('ansible_processor', [])
    cpu_model = "Unknown"
    if len(processor_list) > 2:
         cpu_model = processor_list[2]
    elif len(processor_list) > 0:
        cpu_model = processor_list[0]
        
    cpu_cores = facts_data.get('ansible_processor_vcpus', 1)

    mounts = facts_data.get('ansible_mounts', [])
    storage_info = []
    for m in mounts:
        if m.get('size_total', 0) > 1073741824: # > 1GB
            size_gb = round(m['size_total'] / (1024**3), 2)
            storage_info.append(f"{m['mount']} ({size_gb} GB)")
    storage_str = ", ".join(storage_info)

    interfaces = []
    for iface in facts_data.get('ansible_interfaces', []):
        if iface == 'lo': continue
        key = f"ansible_{iface}"
        if key in facts_data:
            details = facts_data[key]
            ipv4 = details.get('ipv4', {})
            addr = ipv4.get('address', 'N/A')
            mac = details.get('macaddress', 'N/A')
            interfaces.append(f"{iface}: {addr} ({mac})")
            
    net_str = "\n".join(interfaces)

    net_str = "\n".join(interfaces)

    hostname_val = facts_data.get('ansible_hostname') or "N/A"
    if fact_error and not facts_data:
        hostname_val = f"ERROR: {fact_error}"

    system_info = {
        "Hostname": hostname_val,
        "OS": f"{facts_data.get('ansible_distribution')} {facts_data.get('ansible_distribution_version')}",
        "Architecture": facts_data.get('ansible_architecture', 'N/A'),
        "Kernel": facts_data.get('ansible_kernel', 'N/A'),
        "CPU": f"{cpu_model} ({cpu_cores} vCPUs)",
        "RAM": f"{mem_total_gb} GB",
        "Storage": storage_str,
        "Network": net_str
    }

    # Tasks Processing - SEQUENTIAL
    sequential_tasks = []
    if 'plays' in playbook_data:
        for play in playbook_data['plays']:
            for task in play['tasks']:
                task_name_raw = task['task']['name']
                task_name_clean = clean_task_name(task_name_raw)
                
                hosts_res = task['hosts']
                status = "SKIPPED"
                changed = "No"
                
                for h, res in hosts_res.items():
                    if res.get('failed'): status = "FAILED"
                    elif res.get('unreachable'): status = "UNREACHABLE"
                    elif res.get('skipped') and status != "FAILED": status = "SKIPPED"
                    else: status = "OK" 
                    
                    if res.get('changed'): changed = "Yes"
                
                if task_name_raw == "Gathering Facts": continue 
                
                sequential_tasks.append({
                    "task": task_name_clean,
                    "status": status,
                    "changed": changed
                })

    # 4. MERGE JSON
    final_json = {
        "timestamp": datetime.now().isoformat(),
        "system_info": system_info,
        "playbook_execution": sequential_tasks
    }
    
    final_json_path = os.path.join(report_dir, "final_report.json")
    with open(final_json_path, 'w') as f:
        json.dump(final_json, f, indent=4)
    print(f"Unified JSON Report: {final_json_path}")

    # 5. GENERATE PDF
    class PDF(FPDF):
        def header(self):
            # Bold title
            self.set_font('Helvetica', 'B', 16)
            self.cell(0, 10, 'Hardening Report', border=0, new_x=XPos.LMARGIN, new_y=YPos.NEXT, align='C')
            self.line(MARGIN_LEFT, 20, PAGE_WIDTH - MARGIN_RIGHT, 20)
            self.ln(10)

        def footer(self):
            self.set_y(-15)
            self.set_font('Helvetica', 'I', 8)
            self.cell(0, 10, f'Page {self.page_no()}/{{nb}}', border=0, new_x=XPos.RIGHT, new_y=YPos.TOP, align='C')
            
        def chapter_title(self, label):
            self.set_font('Helvetica', 'B', 12)
            # Light grey background
            self.set_fill_color(240, 240, 240)
            self.cell(0, 8, f"  {label}", border=0, new_x=XPos.LMARGIN, new_y=YPos.NEXT, align='L', fill=True)
            self.ln(2)

    pdf_file = os.path.join(report_dir, "report.pdf")
    pdf = PDF()
    pdf.alias_nb_pages()
    pdf.add_page()
    
    # -- METADATA --
    pdf.set_font('Helvetica', '', 10)
    pdf.cell(0, 6, f"Date: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}", border=0, new_x=XPos.LMARGIN, new_y=YPos.NEXT, align='R')
    pdf.ln(5)

    # -- SYSTEM INFO TABLE --
    pdf.chapter_title('System Information')
    
    pdf.set_font('Helvetica', '', 10)
    
    key_width = 40
    val_width = WRITABLE_WIDTH - key_width
    
    for k, v in system_info.items():
        pdf.set_font('Helvetica', 'B', 10)
        
        # Save positions
        x_start = pdf.get_x()
        y_start = pdf.get_y()
        
        # Print Key (Left Column)
        pdf.cell(key_width, 6, k, border=0)
        
        # Move to Value Position (Right Column)
        pdf.set_xy(x_start + key_width, y_start)
        
        pdf.set_font('Helvetica', '', 10)
        
        formatted_v = v if k == "Network" else v.replace('\n', ', ')
        
        # Use MultiCell for Value (handles wrapping)
        pdf.multi_cell(val_width, 6, formatted_v)
        
        # Reset X
        pdf.set_x(MARGIN_LEFT)

    pdf.ln(8)

    # -- TASKS TABLE (Sequential) --
    pdf.chapter_title('Task Execution Details')
    
    # Table Header
    pdf.set_fill_color(220, 220, 220)
    pdf.set_font('Helvetica', 'B', 10)
    
    pdf.cell(COL_WIDTH_TASK, 8, "Task", border=1, new_x=XPos.RIGHT, new_y=YPos.TOP, align='C', fill=True)
    pdf.cell(COL_WIDTH_STATUS, 8, "Status", border=1, new_x=XPos.RIGHT, new_y=YPos.TOP, align='C', fill=True)
    pdf.cell(COL_WIDTH_CHANGED, 8, "Chg", border=1, new_x=XPos.LMARGIN, new_y=YPos.NEXT, align='C', fill=True)
    
    pdf.set_font('Helvetica', '', 9)
    # Ensure black text for all
    pdf.set_text_color(0, 0, 0)
    
    for t in sequential_tasks:
        task_name = t['task']
        status = t['status']
        changed = t['changed']
        
        # Truncate very long task names
        if len(task_name) > 90: 
            task_name = task_name[:87] + "..."
        
        pdf.cell(COL_WIDTH_TASK, 7, f"  {task_name}", border=1, new_x=XPos.RIGHT, new_y=YPos.TOP, align='L')
        pdf.cell(COL_WIDTH_STATUS, 7, status, border=1, new_x=XPos.RIGHT, new_y=YPos.TOP, align='C')
        pdf.cell(COL_WIDTH_CHANGED, 7, changed, border=1, new_x=XPos.LMARGIN, new_y=YPos.NEXT, align='C')
            
    pdf.output(pdf_file)
    print(f"PDF Report Generated: {pdf_file}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python generate_pdf.py <playbook_json> <facts_json> <report_dir>")
        sys.exit(1)
        
    generate_report(sys.argv[1], sys.argv[2], sys.argv[3])
