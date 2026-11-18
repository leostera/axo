#!/usr/bin/env python3
"""Private browser/profile + loopback form; records only a synthetic-input digest."""
import hashlib
import http.server
import os
from pathlib import Path
import signal
import subprocess
import threading
import time

root = Path(os.environ["XDG_RUNTIME_DIR"])
page = b'''<!doctype html><html><head><title>Axo secure browser fixture</title></head><body>
<form onsubmit="event.preventDefault(); fetch('/verify',{method:'POST',body:document.querySelector('#email').value+'\\n'+document.querySelector('#password').value})">
<label>Email<input id="email" type="email" autocomplete="username"></label>
<label>Password<input id="password" type="password" autocomplete="current-password"></label>
<button type="submit">Verify input</button></form>
<button onclick="location.href='/changed'">Change page</button></body></html>'''


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(page)

    def do_POST(self):
        value = self.rfile.read(min(int(self.headers.get("Content-Length", "0")), 8192))
        (root / "gui-browser-digest").write_text(hashlib.sha256(value).hexdigest())
        self.send_response(204)
        self.end_headers()


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
profile = root / "browser-profile"
profile.mkdir()
prefs = {
    "toolkit.telemetry.enabled": False,
    "datareporting.healthreport.uploadEnabled": False,
    "datareporting.policy.dataSubmissionEnabled": False,
    "app.update.enabled": False,
    "browser.shell.checkDefaultBrowser": False,
    "browser.startup.homepage_override.mstone": "ignore",
    "browser.safebrowsing.downloads.enabled": False,
    "browser.safebrowsing.malware.enabled": False,
    "browser.safebrowsing.phishing.enabled": False,
    "network.captive-portal-service.enabled": False,
    "network.connectivity-service.enabled": False,
    "accessibility.force_disabled": -1,
    "browser.aboutwelcome.enabled": False,
    "browser.newtabpage.enabled": False,
}
import json
(profile / "user.js").write_text("\n".join(f"user_pref({json.dumps(k)}, {json.dumps(v)});" for k, v in prefs.items()))
url = f"http://127.0.0.1:{server.server_port}/"
(root / "gui-browser-url").write_text(url)
browser = os.environ.get("AXO_GUI_FIXTURE_BROWSER", "/snap/firefox/current/usr/lib/firefox/firefox")
child = subprocess.Popen([browser, "--no-remote", "--new-instance", "--profile", str(profile), url], start_new_session=True)
(root / "gui-browser-pid").write_text(str(child.pid))


def stop(*_):
    raise SystemExit()


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
try:
    while child.poll() is None:
        time.sleep(0.1)
finally:
    if child.poll() is None:
        os.killpg(child.pid, signal.SIGTERM)
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
    server.shutdown()
