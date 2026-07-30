#!/usr/bin/env python3
"""
OVPN Manager – Self‑Contained Venv Edition
ShadowCat v5.0 – immune to externally‑managed errors
"""
import os
import sys
import subprocess
import shutil
from pathlib import Path

# ========== VENV BOOTSTRAP ==========
VENV_DIR = Path("/opt/ovpn_manager_venv")
VENV_PYTHON = VENV_DIR / "bin" / "python"
VENV_PIP = VENV_DIR / "bin" / "pip"

def bootstrap_venv():
    """Create venv and install flask/werkzeug if missing"""
    if not VENV_DIR.exists():
        print("🐱 Creating virtual environment...", file=sys.stderr)
        subprocess.check_call([sys.executable, "-m", "venv", str(VENV_DIR)])
    # Check if flask is installed in venv
    try:
        subprocess.check_call([str(VENV_PYTHON), "-c", "import flask"], stderr=subprocess.DEVNULL)
    except subprocess.CalledProcessError:
        print("🐱 Installing Flask & Werkzeug in venv...", file=sys.stderr)
        subprocess.check_call([str(VENV_PIP), "install", "flask", "werkzeug"])

# If we are not running inside the venv, re-execute inside it
if sys.prefix != str(VENV_DIR):
    bootstrap_venv()
    print(f"🐱 Re‑executing inside venv: {VENV_PYTHON}", file=sys.stderr)
    os.execv(str(VENV_PYTHON), [str(VENV_PYTHON)] + sys.argv)

# Now we are in the venv – proceed with the actual app
from flask import Flask, render_template_string, request, send_file, jsonify, redirect, url_for
from werkzeug.utils import secure_filename
import json
import time
import signal

# ========== CONFIGURATION ==========
CONFIG_DIR = Path("/etc/openvpn/client")
UPLOAD_DIR = Path("/tmp/ovpn_uploads")
PID_DIR = Path("/var/run/ovpn_manager")
LOG_DIR = Path("/var/log/ovpn_manager")
OPENVPN_BIN = shutil.which("openvpn") or "/usr/sbin/openvpn"
HOST = "0.0.0.0"
PORT = 5000

for d in [CONFIG_DIR, UPLOAD_DIR, PID_DIR, LOG_DIR]:
    d.mkdir(parents=True, exist_ok=True)

# ========== STATE MANAGEMENT ==========
active_connections = {}

def load_state():
    global active_connections
    active_connections.clear()
    for pid_file in PID_DIR.glob("*.pid"):
        try:
            pid = int(pid_file.read_text().strip())
            if os.kill(pid, 0) == 0:
                active_connections[pid_file.stem] = pid
            else:
                pid_file.unlink(missing_ok=True)
        except (ProcessLookupError, ValueError, OSError):
            pid_file.unlink(missing_ok=True)

load_state()

def save_pid(name, pid):
    (PID_DIR / f"{name}.pid").write_text(str(pid))

def remove_pid(name):
    (PID_DIR / f"{name}.pid").unlink(missing_ok=True)

# ========== FLASK APP ==========
app = Flask(__name__)
app.config['UPLOAD_FOLDER'] = str(UPLOAD_DIR)
app.config['MAX_CONTENT_LENGTH'] = 16 * 1024 * 1024

HTML_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
    <title>🐱 OVPN Manager – Shadow</title>
    <style>
        body { font-family: 'Courier New', monospace; background: #0a0a0a; color: #0f0; padding: 20px; }
        .container { max-width: 900px; margin: auto; }
        h1 { color: #0f0; border-bottom: 2px solid #0f0; padding-bottom: 10px; }
        .card { background: #1a1a1a; padding: 15px; margin: 15px 0; border: 1px solid #0f0; border-radius: 5px; }
        .btn { background: #0f0; color: #000; border: none; padding: 8px 16px; cursor: pointer; font-weight: bold; }
        .btn:hover { background: #0a0; }
        .btn-danger { background: #f00; color: #fff; }
        .btn-danger:hover { background: #c00; }
        .file-list { list-style: none; padding: 0; }
        .file-list li { padding: 8px; border-bottom: 1px solid #333; display: flex; justify-content: space-between; align-items: center; }
        .status { color: #ff0; }
        .status.active { color: #0f0; }
        .status.inactive { color: #f00; }
        .upload-form { display: flex; gap: 10px; align-items: center; flex-wrap: wrap; }
        input[type="file"] { background: #222; color: #0f0; border: 1px solid #0f0; padding: 5px; }
        .actions { display: flex; gap: 8px; }
        .footer { margin-top: 30px; color: #666; font-size: 0.8em; }
    </style>
</head>
<body>
<div class="container">
    <h1>🐱 OVPN Manager – Shadow Edition</h1>
    <div class="card">
        <h2>📤 Upload New Config</h2>
        <form class="upload-form" action="/upload" method="post" enctype="multipart/form-data">
            <input type="file" name="file" accept=".ovpn" required>
            <button class="btn" type="submit">Upload & Start</button>
        </form>
    </div>
    <div class="card">
        <h2>📋 Available Configs</h2>
        <ul class="file-list">
            {% for name, pid in connections.items() %}
            <li>
                <span><strong>{{ name }}</strong> 
                    <span class="status active">● ACTIVE (PID {{ pid }})</span>
                </span>
                <div class="actions">
                    <a href="/download/{{ name }}" class="btn">⬇ Download</a>
                    <a href="/stop/{{ name }}" class="btn btn-danger" onclick="return confirm('Stop?')">⏹ Stop</a>
                </div>
            </li>
            {% endfor %}
            {% for name in configs %}
            <li>
                <span><strong>{{ name }}</strong> 
                    <span class="status inactive">● INACTIVE</span>
                </span>
                <div class="actions">
                    <a href="/download/{{ name }}" class="btn">⬇ Download</a>
                    <a href="/start/{{ name }}" class="btn">▶ Start</a>
                    <a href="/delete/{{ name }}" class="btn btn-danger" onclick="return confirm('Delete config?')">🗑 Delete</a>
                </div>
            </li>
            {% endfor %}
        </ul>
        {% if not configs and not connections %}
            <p>No configs found. Upload one!</p>
        {% endif %}
    </div>
    <div class="footer">🐱 ShadowCat – root@universe | uptime ∞</div>
</div>
</body>
</html>
"""

def get_config_names():
    return [f.stem for f in CONFIG_DIR.glob("*.ovpn")]

def get_active_connections():
    return active_connections

@app.route('/')
def index():
    configs = get_config_names()
    active = get_active_connections()
    inactive = [c for c in configs if c not in active]
    return render_template_string(HTML_TEMPLATE, connections=active, configs=inactive)

@app.route('/upload', methods=['POST'])
def upload_file():
    if 'file' not in request.files:
        return "No file", 400
    file = request.files['file']
    if file.filename == '':
        return "No file selected", 400
    if not file.filename.endswith('.ovpn'):
        return "Only .ovpn files allowed", 400
    filename = secure_filename(file.filename)
    save_path = CONFIG_DIR / filename
    file.save(str(save_path))
    name = Path(filename).stem
    start_vpn(name)
    return redirect(url_for('index'))

@app.route('/download/<name>')
def download(name):
    config_path = CONFIG_DIR / f"{name}.ovpn"
    if not config_path.exists():
        return "Config not found", 404
    return send_file(config_path, as_attachment=True)

@app.route('/start/<name>')
def start_route(name):
    start_vpn(name)
    return redirect(url_for('index'))

@app.route('/stop/<name>')
def stop_route(name):
    stop_vpn(name)
    return redirect(url_for('index'))

@app.route('/delete/<name>')
def delete_route(name):
    config_path = CONFIG_DIR / f"{name}.ovpn"
    if config_path.exists():
        config_path.unlink()
    if name in active_connections:
        stop_vpn(name)
    return redirect(url_for('index'))

# ========== OPENVPN CONTROL ==========
def start_vpn(name):
    config_path = CONFIG_DIR / f"{name}.ovpn"
    if not config_path.exists():
        return False
    if name in active_connections:
        return True
    pid_file = PID_DIR / f"{name}.pid"
    log_file = LOG_DIR / f"{name}.log"
    cmd = [
        OPENVPN_BIN,
        "--config", str(config_path),
        "--daemon",
        "--writepid", str(pid_file),
        "--log", str(log_file),
        "--redirect-gateway", "def1",
        "--verb", "3"
    ]
    try:
        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1)
        if pid_file.exists():
            pid = int(pid_file.read_text().strip())
            active_connections[name] = pid
            return True
        return False
    except Exception:
        return False

def stop_vpn(name):
    if name not in active_connections:
        return False
    pid = active_connections[name]
    try:
        os.kill(pid, signal.SIGTERM)
        time.sleep(0.5)
        try:
            os.kill(pid, 0)
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    except Exception:
        pass
    remove_pid(name)
    del active_connections[name]
    return True

# ========== MAIN ==========
if __name__ == "__main__":
    if os.geteuid() != 0:
        print("⚠️  WARNING: OpenVPN requires root. Run with sudo.", file=sys.stderr)
    if not shutil.which("openvpn"):
        print("❌ OpenVPN not found. Install it: sudo apt install openvpn", file=sys.stderr)
        sys.exit(1)
    load_state()
    print(f"🐱 OVPN Manager started on http://{HOST}:{PORT}")
    app.run(host=HOST, port=PORT, debug=False, threaded=True)
