#!/usr/bin/env python3
"""
JustOVPN - OpenVPN Config Manager
Auto-cert generation, real-time status, start/stop controls
"""
import os
import sys
import subprocess
import shutil
import time
import zipfile
import signal
from pathlib import Path
from datetime import datetime

# ===== AUTO-INSTALL =====
try:
    from flask import Flask, render_template_string, request, send_file, redirect, url_for
except ImportError:
    subprocess.check_call(["apt-get", "update"], stderr=subprocess.DEVNULL)
    subprocess.check_call(["apt-get", "install", "-y", "python3-flask", "python3-werkzeug", "openssl"])
    from flask import Flask, render_template_string, request, send_file, redirect, url_for

# ========== GET PUBLIC IP ==========
def get_public_ip():
    try:
        ip = subprocess.check_output(["curl", "-s", "ifconfig.me"], text=True).strip()
        if ip:
            return ip
    except:
        pass
    try:
        ip = subprocess.check_output(["hostname", "-I"], text=True).strip().split()[0]
        if ip:
            return ip
    except:
        pass
    return "vpn.example.com"

PUBLIC_IP = get_public_ip()

# ========== CONFIG ==========
BASE_DIR = Path("/opt/ovpn_forge")
CONFIG_DIR = BASE_DIR / "configs"
CERT_DIR = BASE_DIR / "certs"
PID_DIR = Path("/var/run/ovpn_manager")
LOG_DIR = Path("/var/log/ovpn_manager")

for d in [BASE_DIR, CONFIG_DIR, CERT_DIR, PID_DIR, LOG_DIR]:
    d.mkdir(parents=True, exist_ok=True)

HOST = "0.0.0.0"
PORT = 5000
OPENVPN_BIN = shutil.which("openvpn") or "/usr/sbin/openvpn"

# ========== CERTIFICATE GENERATION ==========
def ensure_ca():
    ca_key = CERT_DIR / "ca.key"
    ca_crt = CERT_DIR / "ca.crt"
    server_key = CERT_DIR / "server.key"
    server_crt = CERT_DIR / "server.crt"
    if ca_key.exists() and ca_crt.exists():
        return
    print("🔐 Generating CA and server certificates...", file=sys.stderr)
    subprocess.run([
        "openssl", "req", "-new", "-x509", "-days", "3650", "-nodes",
        "-newkey", "rsa:2048",
        "-keyout", str(ca_key),
        "-out", str(ca_crt),
        "-subj", "/C=XX/ST=State/L=City/O=Organization/CN=JustOVPN-CA"
    ], check=True, stderr=subprocess.DEVNULL)
    subprocess.run([
        "openssl", "req", "-new", "-nodes",
        "-newkey", "rsa:2048",
        "-keyout", str(server_key),
        "-out", str(CERT_DIR / "server.csr"),
        "-subj", "/C=XX/ST=State/L=City/O=Organization/CN=justovpn-server"
    ], check=True, stderr=subprocess.DEVNULL)
    subprocess.run([
        "openssl", "x509", "-req", "-days", "3650",
        "-in", str(CERT_DIR / "server.csr"),
        "-CA", str(ca_crt),
        "-CAkey", str(ca_key),
        "-set_serial", "01",
        "-out", str(server_crt)
    ], check=True, stderr=subprocess.DEVNULL)
    (CERT_DIR / "server.csr").unlink(missing_ok=True)

def generate_client_cert(common_name):
    client_key = CERT_DIR / f"{common_name}.key"
    client_crt = CERT_DIR / f"{common_name}.crt"
    if client_key.exists() and client_crt.exists():
        return client_crt.read_text(), client_key.read_text()
    subprocess.run([
        "openssl", "req", "-new", "-nodes",
        "-newkey", "rsa:2048",
        "-keyout", str(client_key),
        "-out", str(CERT_DIR / f"{common_name}.csr"),
        "-subj", f"/C=XX/ST=State/L=City/O=Organization/CN={common_name}"
    ], check=True, stderr=subprocess.DEVNULL)
    subprocess.run([
        "openssl", "x509", "-req", "-days", "3650",
        "-in", str(CERT_DIR / f"{common_name}.csr"),
        "-CA", str(CERT_DIR / "ca.crt"),
        "-CAkey", str(CERT_DIR / "ca.key"),
        "-set_serial", "02",
        "-out", str(client_crt)
    ], check=True, stderr=subprocess.DEVNULL)
    (CERT_DIR / f"{common_name}.csr").unlink(missing_ok=True)
    return client_crt.read_text(), client_key.read_text()

# ========== PROCESS DETECTION ==========
def get_active_configs():
    active = set()
    try:
        output = subprocess.check_output(["ps", "aux"]).decode()
        for line in output.splitlines():
            if "openvpn" in line and "--config" in line:
                parts = line.split()
                for i, part in enumerate(parts):
                    if part == "--config" and i+1 < len(parts):
                        config_path = parts[i+1]
                        config_name = Path(config_path).stem
                        active.add(config_name)
                        break
    except Exception:
        pass
    return active

# ========== START/STOP VPN ==========
def start_vpn(config_name):
    config_path = CONFIG_DIR / f"{config_name}.ovpn"
    if not config_path.exists():
        return False
    if config_name in get_active_configs():
        return True
    pid_file = PID_DIR / f"{config_name}.pid"
    log_file = LOG_DIR / f"{config_name}.log"
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
        return config_name in get_active_configs()
    except Exception:
        return False

def stop_vpn(config_name):
    pid_file = PID_DIR / f"{config_name}.pid"
    if pid_file.exists():
        try:
            pid = int(pid_file.read_text().strip())
            os.kill(pid, signal.SIGTERM)
            time.sleep(0.5)
            try:
                os.kill(pid, 0)
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            pid_file.unlink(missing_ok=True)
            return True
        except Exception:
            pass
    try:
        output = subprocess.check_output(["ps", "aux"]).decode()
        for line in output.splitlines():
            if "openvpn" in line and f"--config {CONFIG_DIR}/{config_name}.ovpn" in line:
                pid = int(line.split()[1])
                os.kill(pid, signal.SIGTERM)
                time.sleep(0.5)
                try:
                    os.kill(pid, 0)
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                return True
    except Exception:
        pass
    return False

# ========== TEMPLATE ==========
TEMPLATE = """# OpenVPN Client Config – {name}
client
dev tun
proto {proto}
remote {server} {port}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
cipher {cipher}
auth {auth}
comp-lzo {comp}
verb 3

<ca>
{ca_cert}
</ca>
<cert>
{client_cert}
</cert>
<key>
{client_key}
</key>
"""

# ========== FLASK APP ==========
app = Flask(__name__)
app.config['MAX_CONTENT_LENGTH'] = 16 * 1024 * 1024

def get_profiles():
    profiles = []
    active_set = get_active_configs()
    for ovpn in CONFIG_DIR.glob("*.ovpn"):
        name = ovpn.stem
        meta = {"name": name, "file": str(ovpn), "size": ovpn.stat().st_size}
        with open(ovpn) as f:
            content = f.read()
            for line in content.splitlines():
                if line.startswith("proto "):
                    meta["proto"] = line.split()[1]
                elif line.startswith("remote "):
                    parts = line.split()
                    if len(parts) >= 3:
                        meta["server"] = parts[1]
                        meta["port"] = parts[2]
        meta.setdefault("proto", "unknown")
        meta.setdefault("server", "unknown")
        meta.setdefault("port", "unknown")
        meta["active"] = name in active_set
        meta["created"] = datetime.fromtimestamp(ovpn.stat().st_ctime).strftime("%Y-%m-%d %H:%M")
        profiles.append(meta)
    return profiles

def generate_config(name, server, port, proto, cipher, auth, comp, ca_cert, client_cert, client_key):
    config = TEMPLATE.format(
        name=name,
        server=server,
        port=port,
        proto=proto,
        cipher=cipher,
        auth=auth,
        comp=comp,
        date=datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        ca_cert=ca_cert.strip(),
        client_cert=client_cert.strip(),
        client_key=client_key.strip()
    )
    out_file = CONFIG_DIR / f"{name}.ovpn"
    with open(out_file, "w") as f:
        f.write(config)
    return out_file

@app.route('/')
def index():
    profiles = get_profiles()
    return render_template_string(HTML, profiles=profiles, public_ip=PUBLIC_IP)

@app.route('/generate', methods=['POST'])
def generate():
    server = request.form.get('server', '').strip()
    proto = request.form.get('protocol', 'udp')
    ports_raw = request.form.get('ports', '1194').strip()
    cipher = request.form.get('cipher', 'AES-256-CBC')
    auth = request.form.get('auth', 'SHA256')
    comp = request.form.get('comp', 'yes')
    client_name = request.form.get('client_name', 'client').strip()
    if not server:
        server = PUBLIC_IP
    ports = [p.strip() for p in ports_raw.split(',') if p.strip().isdigit()]
    if not ports:
        ports = ["1194"]
    ensure_ca()
    ca_cert = (CERT_DIR / "ca.crt").read_text()
    for port in ports:
        name = f"{client_name}_{proto}_{port}"
        client_cert_pem, client_key_pem = generate_client_cert(name)
        generate_config(
            name=name,
            server=server,
            port=port,
            proto=proto,
            cipher=cipher,
            auth=auth,
            comp=comp,
            ca_cert=ca_cert,
            client_cert=client_cert_pem,
            client_key=client_key_pem
        )
    return redirect(url_for('index'))

@app.route('/start/<name>')
def start_route(name):
    start_vpn(name)
    return redirect(url_for('index'))

@app.route('/stop/<name>')
def stop_route(name):
    stop_vpn(name)
    return redirect(url_for('index'))

@app.route('/download/<name>')
def download(name):
    file_path = CONFIG_DIR / f"{name}.ovpn"
    if not file_path.exists():
        return "File not found", 404
    return send_file(file_path, as_attachment=True)

@app.route('/download_all')
def download_all():
    zip_path = BASE_DIR / "all_configs.zip"
    with zipfile.ZipFile(zip_path, 'w') as zipf:
        for ovpn in CONFIG_DIR.glob("*.ovpn"):
            zipf.write(ovpn, ovpn.name)
    return send_file(zip_path, as_attachment=True, download_name="ovpn_configs.zip")

@app.route('/delete/<name>', methods=['POST'])
def delete(name):
    if name in get_active_configs():
        stop_vpn(name)
    file_path = CONFIG_DIR / f"{name}.ovpn"
    if file_path.exists():
        file_path.unlink()
    return redirect(url_for('index'))

# ---------------- HTML (Clean UI) ----------------
HTML = """
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>JustOVPN Manager</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #f4f6f9; margin: 0; padding: 20px; color: #333; }
        .container { max-width: 1200px; margin: auto; background: white; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); padding: 25px; }
        h1 { color: #2c3e50; border-bottom: 3px solid #3498db; padding-bottom: 10px; margin-top: 0; }
        h2 { color: #34495e; }
        .row { display: flex; gap: 30px; flex-wrap: wrap; }
        .col { flex: 1; min-width: 300px; }
        .form-group { margin-bottom: 15px; }
        label { display: block; font-weight: 600; margin-bottom: 5px; color: #2c3e50; }
        input, select { width: 100%; padding: 8px; border: 1px solid #ddd; border-radius: 4px; box-sizing: border-box; }
        .btn { background: #3498db; color: white; border: none; padding: 8px 14px; border-radius: 4px; cursor: pointer; font-weight: 600; text-decoration: none; display: inline-block; }
        .btn:hover { background: #2980b9; }
        .btn-danger { background: #e74c3c; }
        .btn-danger:hover { background: #c0392b; }
        .btn-success { background: #2ecc71; }
        .btn-success:hover { background: #27ae60; }
        .btn-warning { background: #f39c12; }
        .btn-warning:hover { background: #e67e22; }
        .file-list { list-style: none; padding: 0; }
        .file-list li { padding: 12px; border-bottom: 1px solid #ecf0f1; display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; }
        .file-info { font-size: 0.9em; color: #7f8c8d; }
        .actions { display: flex; gap: 8px; flex-wrap: wrap; align-items: center; }
        .badge { background: #2ecc71; color: white; padding: 3px 8px; border-radius: 12px; font-size: 0.8em; }
        .badge.inactive { background: #e74c3c; }
        .footer { margin-top: 30px; color: #95a5a6; font-size: 0.9em; border-top: 1px solid #ecf0f1; padding-top: 15px; }
        .note { background: #f9f9f9; padding: 10px; border-left: 4px solid #3498db; margin: 10px 0; }
    </style>
</head>
<body>
<div class="container">
    <h1>📡 JustOVPN Manager</h1>
    <div class="row">
        <div class="col">
            <div style="background:#f9f9f9;padding:15px;border-radius:6px;">
                <h2>⚙️ Generate Config</h2>
                <form method="post" action="/generate">
                    <div class="form-group">
                        <label>Server IP / Hostname</label>
                        <input type="text" name="server" placeholder="e.g., vpn.example.com" value="{{ public_ip }}">
                    </div>
                    <div class="form-group">
                        <label>Protocol</label>
                        <select name="protocol">
                            <option value="udp">UDP</option>
                            <option value="tcp">TCP</option>
                        </select>
                    </div>
                    <div class="form-group">
                        <label>Ports (comma-separated)</label>
                        <input type="text" name="ports" value="1194,443" placeholder="1194,443">
                    </div>
                    <div class="form-group">
                        <label>Cipher</label>
                        <select name="cipher">
                            <option value="AES-256-CBC">AES-256-CBC</option>
                            <option value="AES-256-GCM">AES-256-GCM</option>
                            <option value="BF-CBC">BF-CBC</option>
                        </select>
                    </div>
                    <div class="form-group">
                        <label>Auth</label>
                        <select name="auth">
                            <option value="SHA256">SHA256</option>
                            <option value="SHA512">SHA512</option>
                            <option value="SHA1">SHA1</option>
                        </select>
                    </div>
                    <div class="form-group">
                        <label>Compression</label>
                        <select name="comp">
                            <option value="yes">yes</option>
                            <option value="no">no</option>
                            <option value="lzo">lzo</option>
                        </select>
                    </div>
                    <div class="form-group">
                        <label>Client Name (prefix)</label>
                        <input type="text" name="client_name" value="client">
                    </div>
                    <button class="btn" type="submit">🚀 Generate</button>
                </form>
                <div class="note">Certificates are auto‑generated with OpenSSL.</div>
            </div>
        </div>
        <div class="col">
            <div style="background:#f9f9f9;padding:15px;border-radius:6px;">
                <h2>📋 Profiles ({{ profiles|length }})</h2>
                <div style="margin-bottom:10px;">
                    <a href="/download_all" class="btn btn-success">⬇ Download All (ZIP)</a>
                </div>
                <ul class="file-list">
                    {% for p in profiles %}
                    <li>
                        <span>
                            <strong>{{ p.name }}</strong><br>
                            <span class="file-info">{{ p.server }}:{{ p.port }} ({{ p.proto }}) – {{ p.created }} – {{ p.size }} bytes</span>
                            <span class="badge {% if p.active %}active{% else %}inactive{% endif %}">
                                {% if p.active %}● ACTIVE{% else %}● INACTIVE{% endif %}
                            </span>
                        </span>
                        <div class="actions">
                            {% if p.active %}
                                <a href="/stop/{{ p.name }}" class="btn btn-danger">⏹ Stop</a>
                            {% else %}
                                <a href="/start/{{ p.name }}" class="btn btn-success">▶ Start</a>
                            {% endif %}
                            <a href="/download/{{ p.name }}" class="btn">⬇</a>
                            <form method="post" action="/delete/{{ p.name }}" style="display:inline;">
                                <button class="btn btn-danger" onclick="return confirm('Delete config?')">🗑</button>
                            </form>
                        </div>
                    </li>
                    {% else %}
                    <li>No configs yet.</li>
                    {% endfor %}
                </ul>
            </div>
        </div>
    </div>
    <div class="footer">JustOVPN - OpenVPN Config Manager – auto-cert + start/stop</div>
</div>
</body>
</html>
"""

# ========== MAIN ==========
if __name__ == "__main__":
    if not shutil.which("openssl"):
        subprocess.check_call(["apt-get", "install", "-y", "openssl"])
    ensure_ca()
    print(f"📡 JustOVPN Manager running on http://{HOST}:{PORT}")
    app.run(host=HOST, port=PORT, debug=False, threaded=True)
