#!/usr/bin/env bash
# Claude MCP connector for this VM. Exposes whoami + run_shell (with user=)
# + interactive PTY session tools (session_open/send/read/list/kill).
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
apt-get install -y -qq python3 python3-venv screen sudo
mkdir -p "$D"
python3 -m venv "$D/venv" 2>/dev/null || true
"$D/venv/bin/pip" install -q --upgrade pip
"$D/venv/bin/pip" install -q "fastmcp>=2.12"

cat > "$D/server.py" <<'PY'
import asyncio, os, time, pathlib
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

DEFAULT_USER = "omargamal7"

KEYS = {
    "enter": "\r", "tab": "\t", "esc": "\x1b", "space": " ",
    "backspace": "\x7f",
    "up": "\x1b[A", "down": "\x1b[B", "right": "\x1b[C", "left": "\x1b[D",
    "ctrl_c": "\x03", "ctrl_d": "\x04",
}

def owner():
    try:
        _f = pathlib.Path("/var/lib/vm-mcp/last-activity")
        _f.parent.mkdir(parents=True, exist_ok=True)
        _f.touch()
    except Exception:
        pass
    t = get_access_token()
    e = (t.claims.get("email") or "").strip().lower()
    if e != ALLOWED or t.claims.get("email_verified") is False:
        raise PermissionError(f"account '{e or 'unknown'}' not authorized")
    return e

async def _exec(argv, timeout=20, cwd=None):
    p = await asyncio.create_subprocess_exec(
        *argv, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT, cwd=cwd)
    try:
        out, _ = await asyncio.wait_for(p.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        p.kill()
        return -1, f"killed after {timeout}s"
    return p.returncode, out.decode("utf-8", "replace")

async def sh(cmd, timeout, cwd=None, user="root"):
    if user == "root":
        p = await asyncio.create_subprocess_shell(
            cmd, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT, cwd=cwd)
        try:
            out, _ = await asyncio.wait_for(p.communicate(), timeout=timeout)
        except asyncio.TimeoutError:
            p.kill()
            return {"exit_code": -1, "output": f"killed after {timeout}s"}
        rc, t = p.returncode, out.decode("utf-8", "replace")
    else:
        rc, t = await _exec(["sudo", "-u", user, "-H", "bash", "-lc", cmd],
                            timeout=timeout, cwd=cwd)
    if len(t) > 60000:
        t = t[:30000] + "\n...[truncated]...\n" + t[-30000:]
    return {"exit_code": rc, "output": t}

def _sname(name):
    if not name or not name.replace("-", "").replace("_", "").isalnum():
        raise ValueError("session name must be alphanumeric plus - or _")
    return f"mcp-{name}"

async def _screen(user, *args, timeout=15):
    return await _exec(["sudo", "-u", user, "-H", "screen", *args], timeout=timeout)

async def _grab(user, sess, history=False):
    tmp = f"/tmp/.vmmcp-{sess}-{time.time_ns()}"
    args = ["-S", sess, "-X", "hardcopy"]
    if history:
        args.append("-h")
    args.append(tmp)
    rc, out = await _screen(user, *args)
    if rc != 0:
        return rc, out
    await asyncio.sleep(0.3)
    try:
        txt = pathlib.Path(tmp).read_text(errors="replace")
    except FileNotFoundError:
        return 1, "hardcopy produced no file (session dead?)"
    finally:
        try:
            pathlib.Path(tmp).unlink()
        except Exception:
            pass
    return 0, txt.rstrip("\n") + "\n"

@mcp.tool
async def whoami() -> dict:
    """Confirm auth works and report VM identity, cores, memory, disk."""
    e = owner()
    r = await sh("hostname; uptime; nproc; free -g|head -2; df -h /|tail -1", 20)
    return {"authenticated_as": e, "vm": r["output"]}

@mcp.tool
async def run_shell(command: str, timeout_seconds: int = 120, cwd: str = "/root",
                    user: str = "root") -> dict:
    """Run a one-shot shell command on the VM and return its output.
    Default user is root; pass user="omargamal7" to run as Omar's account under a
    login shell (PATH includes ~/.local/bin) with no sudo/quoting gymnastics.
    Blocking; cap 900s. For interactive/TUI programs (login wizards, agy, claude,
    codex, hermes) use session_open instead. For long builds, launch detached with
    setsid/nohup and poll the log."""
    owner()
    if user != "root" and cwd == "/root":
        home = f"/home/{user}"
        if os.path.isdir(home):
            cwd = home
    return await sh(command, min(max(timeout_seconds, 1), 900), cwd, user)

@mcp.tool
async def session_open(name: str, command: str, user: str = DEFAULT_USER) -> dict:
    """Open a persistent interactive terminal session (real PTY via GNU screen)
    and run `command` in it under a login shell. Use this for TUIs and auth
    wizards (agy, claude, codex, gh auth login, hermes setup). The session
    survives between tool calls AND vm-mcp restarts (runs as its own transient
    systemd unit): drive it with session_send, inspect it with session_read,
    terminate it with session_kill. Returns the initial screen."""
    owner()
    sess = _sname(name)
    unit = f"vmmcp-sess-{name}"
    await _exec(["systemctl", "reset-failed", unit + ".service"], timeout=5)
    rc, out = await _exec([
        "systemd-run", "--collect", "--unit=" + unit,
        "--uid=" + user, "--gid=" + user,
        "--setenv=HOME=/home/" + user,
        "--property=WorkingDirectory=/home/" + user,
        "screen", "-DmS", sess, "bash", "-lc", command,
    ], timeout=15)
    if rc != 0:
        return {"ok": False, "detail": out}
    await asyncio.sleep(1.0)
    rc2, scr = await _grab(user, sess)
    return {"ok": True, "session": name, "user": user,
            "screen": scr if rc2 == 0 else out}

@mcp.tool
async def session_send(name: str, text: str = "", key: str = "", enter: bool = False,
                       user: str = DEFAULT_USER, read_after_ms: int = 800) -> dict:
    """Type into an open session. `text` is delivered verbatim (no shell quoting
    needed). `key` optionally appends one special key after the text: enter, tab,
    esc, space, backspace, up, down, left, right, ctrl_c, ctrl_d. enter=True
    appends a carriage return last. Returns the screen as it looks read_after_ms
    later (0 to skip reading)."""
    owner()
    sess = _sname(name)
    if key and key not in KEYS:
        return {"ok": False, "detail": f"unknown key '{key}'; valid: {sorted(KEYS)}"}
    payload = text + (KEYS[key] if key else "") + ("\r" if enter else "")
    if not payload:
        return {"ok": False, "detail": "nothing to send"}
    rc, out = await _screen(user, "-S", sess, "-X", "stuff", payload)
    if rc != 0:
        return {"ok": False, "detail": out}
    scr = ""
    if read_after_ms > 0:
        await asyncio.sleep(min(read_after_ms, 10000) / 1000)
        rc2, scr = await _grab(user, sess)
        if rc2 != 0:
            scr = out
    return {"ok": True, "screen": scr}

@mcp.tool
async def session_read(name: str, history: bool = False,
                       user: str = DEFAULT_USER) -> dict:
    """Read the current visible screen of an open session. history=True includes
    scrollback above the visible area."""
    owner()
    rc, txt = await _grab(user, _sname(name), history)
    return {"ok": rc == 0, "screen": txt}

@mcp.tool
async def session_list(user: str = DEFAULT_USER) -> dict:
    """List open interactive sessions for a user (names shown as mcp-<name>)."""
    owner()
    rc, out = await _exec(["sudo", "-u", user, "-H", "screen", "-ls"], timeout=10)
    return {"output": out}

@mcp.tool
async def session_kill(name: str, user: str = DEFAULT_USER) -> dict:
    """Terminate a session and everything running inside it."""
    owner()
    rc, out = await _screen(user, "-S", _sname(name), "-X", "quit")
    await _exec(["systemctl", "stop", f"vmmcp-sess-{name}.service"], timeout=10)
    return {"ok": True, "detail": out.strip() or "killed"}

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
