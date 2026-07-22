#!/usr/bin/env bash
# Minimal Claude MCP connector for this VM. Exposes whoami + run_shell.
# Run:  sudo bash mini.sh
set -euo pipefail
CID="145944394390-b9kggba1469trq5b6lo69cafjctagmgb.apps.googleusercontent.com"
EMAIL="omargamal7@gmail.com"
PORT=8080
D=/opt/vm-mcp
E=/etc/vm-mcp.env
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }

command -v tailscale >/dev/null || { echo "install tailscale first"; exit 1; }
command -v jq >/dev/null || { apt-get update -qq; apt-get install -y -qq jq; }
FQDN="$(tailscale status --json | jq -r .Self.DNSName | sed 's/\.$//')"
[ -n "$FQDN" ] && [ "$FQDN" != null ] || { echo "run: sudo tailscale up"; exit 1; }
BASE="https://${FQDN}"
echo "==> hostname: $FQDN"

if [ ! -f "$E" ]; then
  echo "Paste Google OAuth CLIENT SECRET (GOCSPX-...), input is hidden:"
  read -rsp "  secret: " S; echo
  [ -n "$S" ] || { echo "empty"; exit 1; }
  printf 'GOOGLE_CLIENT_ID=%s\nGOOGLE_CLIENT_SECRET=%s\nMCP_BASE_URL=%s\nMCP_ALLOWED_EMAIL=%s\nMCP_PORT=%s\n' \
    "$CID" "$S" "$BASE" "$EMAIL" "$PORT" > "$E"
  chmod 600 "$E"; unset S
else
  sed -i "s|^MCP_BASE_URL=.*|MCP_BASE_URL=${BASE}|" "$E"
fi

echo "==> installing runtime"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3 python3-venv
mkdir -p "$D"
python3 -m venv "$D/venv" 2>/dev/null || true
"$D/venv/bin/pip" install -q --upgrade pip
"$D/venv/bin/pip" install -q "fastmcp>=2.12"

cat > "$D/server.py" <<'PY'
import asyncio, os
from fastmcp import FastMCP
from fastmcp.server.auth.providers.google import GoogleProvider
from fastmcp.server.dependencies import get_access_token

ALLOWED = os.environ["MCP_ALLOWED_EMAIL"].strip().lower()
auth = GoogleProvider(
    client_id=os.environ["GOOGLE_CLIENT_ID"],
    client_secret=os.environ["GOOGLE_CLIENT_SECRET"],
    base_url=os.environ["MCP_BASE_URL"],
    required_scopes=["openid", "https://www.googleapis.com/auth/userinfo.email"],
)
mcp = FastMCP(name="kernel-builder-vm", auth=auth)

def owner():
    t = get_access_token()
    e = (t.claims.get("email") or "").strip().lower()
    if e != ALLOWED or t.claims.get("email_verified") is False:
        raise PermissionError(f"account '{e or 'unknown'}' not authorized")
    return e

async def sh(cmd, timeout, cwd=None):
    p = await asyncio.create_subprocess_shell(
        cmd, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT, cwd=cwd)
    try:
        out, _ = await asyncio.wait_for(p.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        p.kill(); return {"exit_code": -1, "output": f"killed after {timeout}s"}
    t = out.decode("utf-8", "replace")
    if len(t) > 60000:
        t = t[:30000] + "\n...[truncated]...\n" + t[-30000:]
    return {"exit_code": p.returncode, "output": t}

@mcp.tool
async def whoami() -> dict:
    """Confirm auth works and report VM identity, cores, memory, disk."""
    e = owner()
    r = await sh("hostname; uptime; nproc; free -g|head -2; df -h /|tail -1", 20)
    return {"authenticated_as": e, "vm": r["output"]}

@mcp.tool
async def run_shell(command: str, timeout_seconds: int = 120, cwd: str = "/root") -> dict:
    """Run a shell command on the VM as root. Blocking; cap 900s.
    For long builds, launch detached with setsid/nohup and poll the log."""
    owner()
    return await sh(command, min(max(timeout_seconds, 1), 900), cwd)

if __name__ == "__main__":
    mcp.run(transport="http", host="127.0.0.1", port=int(os.environ.get("MCP_PORT", 8080)))
PY

cat > /etc/systemd/system/vm-mcp.service <<EOF
[Unit]
Description=Claude MCP server
After=network-online.target tailscaled.service
Wants=network-online.target
[Service]
Type=simple
EnvironmentFile=${E}
ExecStart=${D}/venv/bin/python ${D}/server.py
Restart=always
RestartSec=5
User=root
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now vm-mcp
sleep 4
systemctl is-active --quiet vm-mcp || { journalctl -u vm-mcp -n 30 --no-pager; exit 1; }

echo "==> exposing via funnel"
tailscale funnel --bg --https=443 "http://127.0.0.1:${PORT}" >/dev/null 2>&1 || \
tailscale funnel --bg "${PORT}" >/dev/null 2>&1 || true
sleep 2
tailscale funnel status || true

cat <<EOF

=====================================================
 DONE. Two browser steps:

 1) Google Console -> Credentials -> "claude" client
    Add authorised redirect URI:
        ${BASE}/auth/callback

 2) Claude -> Settings -> Connectors -> Add custom
        URL:       ${BASE}/mcp
        Client ID: ${CID}
        Secret:    (the GOCSPX- value)

 Then tell Claude: "test the VM connector"
=====================================================
EOF
