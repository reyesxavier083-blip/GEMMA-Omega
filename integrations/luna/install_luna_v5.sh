#!/usr/bin/env bash
# L.U.N.A. v5.0 — Instalador unificado para Termux
# Uso: bash install_luna_v5.sh
set -euo pipefail
IFS=$'\n\t'

C_RST=$'\033[0m'; C_CYN=$'\033[1;36m'; C_GRN=$'\033[1;32m'
C_YEL=$'\033[1;33m'; C_RED=$'\033[1;31m'
LOG()  { printf '%s[LUNA]%s %s\n' "$C_CYN" "$C_RST" "$*"; }
OK()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }
WARN() { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_RST" "$*"; }
die()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; exit 1; }
trap 'die "abortado en línea $LINENO"' ERR

LUNA_HOME="$HOME/.termux/tasker"
CORE="$LUNA_HOME/luna_core.py"
CFG="$LUNA_HOME/config.json"
CLI="$PREFIX/bin/luna"
PLUGINS="$LUNA_HOME/plugins"
STATIC="$LUNA_HOME/static"
DATA="$LUNA_HOME/data"

command -v pkg >/dev/null 2>&1 || die "requiere Termux."
[ -n "${PREFIX:-}" ] || die "PREFIX no definido."

# ============================================================
# 1. DEPENDENCIAS
# ============================================================
LOG "Instalando dependencias…"
pkg update -y >/dev/null 2>&1 || WARN "pkg update con errores; sigo."
pkg install -y python python-pip jq curl termux-api openssl-tool >/dev/null 2>&1 \
  || die "fallo en pkg install."
pip install --upgrade --quiet flask waitress >/dev/null 2>&1 || die "pip falló."
python -c 'import flask, waitress' 2>/dev/null || die "imports fallidos."
OK "Python $(python -V 2>&1 | awk '{print $2}') listo."

command -v termux-battery-status >/dev/null 2>&1 \
  || WARN "instala la app 'Termux:API' desde F-Droid para telemetría."

# ============================================================
# 2. ESTRUCTURA
# ============================================================
mkdir -p "$LUNA_HOME" "$PLUGINS" "$STATIC" "$DATA/licenses" "$DATA/tasks" "$DATA/arena"
OK "Estructura creada en $LUNA_HOME"

# ============================================================
# 3. CONFIG — JSON VÁLIDO (bug corregido: sin [-y])
# ============================================================
if [ ! -f "$CFG" ]; then
cat > "$CFG" <<'JSON'
{
  "host": "127.0.0.1",
  "port": 7070,
  "port_auto": true,
  "server": "auto",
  "debug": false,
  "log_level": "INFO",
  "log_format": "text",
  "cors": "none",
  "cache_ttl": { "battery": 2, "wifi": 2, "location": 10, "telephony": 30 },
  "rate_limit": { "window_s": 60, "max": 240 },
  "tokens": { "full": [], "ro": [] },
  "plugins_dir": "plugins",
  "ai": {
    "default_provider": "gemini",
    "models": {
      "gemini": "gemini-2.0-flash",
      "openai": "gpt-4o-mini",
      "anthropic": "claude-3-5-sonnet-latest"
    }
  },
  "tasks": {
    "enabled": true,
    "commands": [],
    "max_concurrent": 3,
    "max_runtime_s": 3600,
    "max_output_bytes": 524288,
    "cleanup_after_s": 604800,
    "max_history": 100
  }
}
JSON
OK "config.json creado (JSON válido)."
fi

# Asegura autenticación desde la primera ejecución; nunca deja endpoints de escritura abiertos.
TOKEN_RESULT="$(python - "$CFG" <<'TOKENPY'
import json, secrets, sys
from pathlib import Path
p = Path(sys.argv[1])
c = json.loads(p.read_text())
t = c.setdefault("tokens", {})
t.setdefault("full", []); t.setdefault("ro", [])
if not t["full"] and not t["ro"]:
    token = secrets.token_urlsafe(32)
    t["full"].append(token)
    p.write_text(json.dumps(c, indent=2) + "\n")
    print("CREATED:" + token)
else:
    print("EXISTS")
TOKENPY
)" || die "no se pudo configurar la autenticación."
if [[ "$TOKEN_RESULT" == CREATED:* ]]; then
  printf '\n%s[SEGURIDAD]%s Token inicial de administrador (guárdalo):\n%s\n\n' "$C_YEL" "$C_RST" "${TOKEN_RESULT#CREATED:}"
fi

# ============================================================
# 4. CORE — PYTHON VÁLIDO (bugs: true→True, gen("ro"), X-Accel)
# ============================================================
LOG "Escribiendo luna_core.py…"
cat > "$CORE" <<'PYEOF'
#!/usr/bin/env python3
"""L.U.N.A. v5.0 — Core unificado."""
from __future__ import annotations
import hmac, json, logging, os, platform, secrets, signal, socket, sys, threading, time, uuid
from collections import OrderedDict
from datetime import datetime, timezone
from functools import wraps
from pathlib import Path
from shutil import which
import subprocess
from flask import Flask, Response, jsonify, render_template_string, request, stream_with_context

VERSION = "5.0.0"
HOME    = Path(os.environ.get("LUNA_HOME", Path.home() / ".termux" / "tasker"))
CFG_FP  = HOME / "config.json"
STATIC  = HOME / "static"

_DEFAULT = {
    "host": "127.0.0.1", "port": 7070, "port_auto": True,
    "server": "auto", "debug": False, "log_level": "INFO", "log_format": "text",
    "cors": "none",
    "cache_ttl": {"battery": 2, "wifi": 2, "location": 10, "telephony": 30},
    "rate_limit": {"window_s": 60, "max": 240},
    "tokens": {"full": [], "ro": []},
    "plugins_dir": "plugins",
    "ai": {"default_provider": "gemini",
           "models": {"gemini": "gemini-2.0-flash",
                      "openai": "gpt-4o-mini",
                      "anthropic": "claude-3-5-sonnet-latest"}},
    "tasks": {"enabled": True, "commands": [], "max_concurrent": 3,
              "max_runtime_s": 3600, "max_output_bytes": 524288,
              "cleanup_after_s": 604800, "max_history": 100},
}

def _load_config():
    cfg = json.loads(json.dumps(_DEFAULT))
    if CFG_FP.exists():
        try:
            user = json.loads(CFG_FP.read_text())
            for k, v in user.items():
                if isinstance(v, dict) and isinstance(cfg.get(k), dict):
                    cfg[k] = {**cfg[k], **v}
                else:
                    cfg[k] = v
        except Exception as e:
            print(f"[WARN] config: {e}", file=sys.stderr)
    for env_k, (dst, cast) in {
        "LUNA_HOST": ("host", str),
        "LUNA_PORT": ("port", int),
        "LUNA_DEBUG": ("debug", lambda v: v in ("1", "true", "True")),
        "LUNA_LOG_LEVEL": ("log_level", str),
        "LUNA_CORS": ("cors", str),
    }.items():
        if env_k in os.environ:
            try:
                cfg[dst] = cast(os.environ[env_k])
            except Exception:
                pass
    for env_k, role in (("LUNA_TOKEN", "full"), ("LUNA_TOKEN_RO", "ro")):
        tok = os.environ.get(env_k)
        if tok and tok not in cfg["tokens"][role]:
            cfg["tokens"][role].append(tok)
    return cfg

CFG = _load_config()

# ---------- logging ----------
class _JsonFmt(logging.Formatter):
    def format(self, r):
        d = {"ts": datetime.fromtimestamp(r.created, timezone.utc).isoformat(),
             "lvl": r.levelname, "msg": r.getMessage(), "logger": r.name}
        if r.exc_info:
            d["exc"] = f"{r.exc_info[0].__name__}: {r.exc_info[1]}"
        return json.dumps(d, ensure_ascii=False)

_h = logging.StreamHandler(sys.stdout)
_h.setFormatter(_JsonFmt() if CFG["log_format"] == "json"
                else logging.Formatter("%(asctime)s | %(levelname)-7s | %(message)s", "%H:%M:%S"))
logging.basicConfig(level=CFG["log_level"], handlers=[_h])
log = logging.getLogger("luna")

# ---------- caches ----------
class _TTLCache:
    def __init__(self):
        self._d = OrderedDict(); self._lk = threading.Lock()
    def _ttl(self, k):
        return CFG["cache_ttl"].get(k.split(":", 1)[-1], 5)
    def get(self, k):
        with self._lk:
            e = self._d.get(k)
            if not e or time.time() - e[0] > self._ttl(k):
                return None
            return e[1]
    def set(self, k, v):
        with self._lk:
            self._d[k] = (time.time(), v)
            while len(self._d) > 256:
                self._d.popitem(last=False)

CACHE = _TTLCache()

class _RateLimiter:
    def __init__(self):
        self._h = {}; self._lk = threading.Lock()
    def allow(self, ip):
        win, mx = int(CFG["rate_limit"]["window_s"]), int(CFG["rate_limit"]["max"])
        if mx <= 0:
            return True
        now = time.time()
        with self._lk:
            hits = [t for t in self._h.get(ip, []) if now - t < win]
            if len(hits) >= mx:
                return False
            hits.append(now); self._h[ip] = hits; return True

RL = _RateLimiter()

app = Flask(__name__)
app.config["JSON_SORT_KEYS"] = False
_METRICS = {"req": 0, "err": 0, "start": time.time()}

# ---------- helpers ----------
def ok(data=None, **extra):
    b = {"ok": True, "request_id": getattr(request, "rid", None)}
    if isinstance(data, dict):
        b.update(data)
    elif data is not None:
        b["data"] = data
    b.update(extra); return jsonify(b)

def fail(msg, code=400, err_code=None):
    b = {"ok": False, "error": str(msg), "request_id": getattr(request, "rid", None)}
    if err_code:
        b["code"] = err_code
    return jsonify(b), code

def _tokens(role):
    return CFG.get("tokens", {}).get(role, []) or []

def _check(given):
    if not given:
        return None
    for role in ("full", "ro"):
        for t in _tokens(role):
            if hmac.compare_digest(str(t), given):
                return role
    return None

def auth(require="full"):
    def deco(fn):
        @wraps(fn)
        def wrapper(*a, **kw):
            if not _tokens("full") and not _tokens("ro"):
                return fail("autenticación sin configurar; ejecuta: luna token generate full", 503,
                            "auth.not_configured")
            given = (request.headers.get("X-Luna-Token")
                     or request.args.get("token")
                     or request.cookies.get("luna_token"))
            role = _check(given)
            if role is None:
                return fail("unauthorized", 401, "auth.required")
            if require == "full" and role != "full":
                return fail("full token required", 403, "auth.forbidden")
            return fn(*a, **kw)
        return wrapper
    return deco

# ---------- termux helpers ----------
def _termux(binary, args=None, timeout=8):
    if not which(binary):
        return 127, "", f"binario ausente: {binary} (instala Termux:API)"
    try:
        r = subprocess.run([binary, *(args or [])],
                           capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"

def _termux_json(binary, args=None, cache_key=None, timeout=6):
    if cache_key:
        v = CACHE.get(cache_key)
        if v is not None:
            return v
    rc, out, _ = _termux(binary, args, timeout)
    if rc != 0 or not out:
        return None
    try:
        v = json.loads(out)
    except json.JSONDecodeError:
        return None
    if cache_key:
        CACHE.set(cache_key, v)
    return v

# ---------- system info ----------
def _read(p):
    try:
        return Path(p).read_text()
    except Exception:
        return ""

def _meminfo():
    d = {}
    for line in _read("/proc/meminfo").splitlines():
        if ":" in line:
            k, v = line.split(":", 1); n = v.strip().split()
            if n and n[0].isdigit():
                d[k.strip()] = int(n[0])
    return d

def _storage():
    try:
        s = os.statvfs("/data")
        tot = s.f_frsize * s.f_blocks; free = s.f_frsize * s.f_bavail
        return {"total_gb": round(tot / 1e9, 2), "free_gb": round(free / 1e9, 2),
                "used_pct": round((tot - free) / tot * 100, 1) if tot else 0}
    except Exception:
        return {}

def _loadavg():
    p = _read("/proc/loadavg").split()
    return {"1m": float(p[0]), "5m": float(p[1]), "15m": float(p[2])} if len(p) >= 3 else {}

def _uptime():
    p = _read("/proc/uptime").split()
    return int(float(p[0])) if p else None

def collect_telemetry():
    bat = _termux_json("termux-battery-status", cache_key="battery:status") or {}
    wifi = _termux_json("termux-wifi-connectioninfo", cache_key="wifi:conn") or {}
    m = _meminfo(); tot = m.get("MemTotal", 0); avail = m.get("MemAvailable", m.get("MemFree", 0))
    used = tot - avail
    return {
        "ts": datetime.now(timezone.utc).isoformat(),
        "version": VERSION,
        "host": platform.node() or "termux",
        "python": platform.python_version(),
        "battery": {"pct": bat.get("percentage", 0),
                    "plugged": bat.get("plugged", "UNKNOWN"),
                    "temp_c": bat.get("temperature", 0),
                    "health": bat.get("health", "")},
        "memory": {"total_kb": tot, "used_kb": used,
                   "used_pct": round(used / tot * 100, 1) if tot else 0},
        "storage": _storage(),
        "cpu": _loadavg(),
        "uptime_s": _uptime(),
        "wifi": {"ssid": wifi.get("ssid", ""), "ip": wifi.get("ip", ""),
                 "rssi": wifi.get("rssi", 0),
                 "link_speed_mbps": wifi.get("link_speed_mbps", 0)},
    }

# ---------- hooks ----------
@app.before_request
def _before():
    request.rid = uuid.uuid4().hex[:12]
    _METRICS["req"] += 1
    if request.path.startswith("/api/") and not RL.allow(request.remote_addr or "?"):
        _METRICS["err"] += 1
        return fail("rate limit exceeded", 429, "rate.limit")

@app.after_request
def _after(resp):
    o = CFG.get("cors") or ""
    if o and o != "none":
        resp.headers["Access-Control-Allow-Origin"] = o
        resp.headers["Access-Control-Allow-Headers"] = "Content-Type, X-Luna-Token"
        resp.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
    resp.headers["X-Request-ID"] = getattr(request, "rid", "")
    if resp.status_code >= 400:
        _METRICS["err"] += 1
    return resp

# ---------- HUD ----------
_HUD_FP = STATIC / "hud.html"
@app.get("/")
def home():
    if _HUD_FP.exists():
        return render_template_string(_HUD_FP.read_text())
    return "<h1>L.U.N.A.</h1><p>HUD no instalado. Ejecuta patch_hud.sh o reinstala.</p>"

@app.get("/api/health")
def health():
    return ok(status="healthy", version=VERSION,
              uptime_s=int(time.time() - _METRICS["start"]),
              time=datetime.now(timezone.utc).isoformat())

@app.get("/api/telemetry")
@auth("ro")
def telemetry():
    try:
        return ok(collect_telemetry())
    except Exception as e:
        log.exception("telemetry")
        return fail(e, 500, "telemetry.error")

@app.get("/api/stream")
@auth("ro")
def stream():
    try:
        interval = min(max(int(request.args.get("interval", 2)), 1), 60)
    except ValueError:
        interval = 2
    def gen():
        try:
            while True:
                try:
                    yield f"event: telemetry\ndata: {json.dumps({'ok': True, **collect_telemetry()})}\n\n"
                except Exception as e:
                    yield f"event: error\ndata: {json.dumps({'ok': False, 'error': str(e)})}\n\n"
                time.sleep(interval)
        except GeneratorExit:
            return
    return Response(stream_with_context(gen()), mimetype="text/event-stream",
                    headers={"Cache-Control": "no-cache",
                             "X-Accel-Buffering": "no",
                             "Connection": "keep-alive"})

@app.get("/api/metrics")
@auth("ro")
def metrics():
    body = "\n".join([
        "# HELP luna_requests_total Peticiones HTTP",
        "# TYPE luna_requests_total counter",
        f"luna_requests_total {_METRICS['req']}",
        f"luna_errors_total {_METRICS['err']}",
        f"luna_uptime_seconds {int(time.time() - _METRICS['start'])}", ""
    ])
    return Response(body, mimetype="text/plain")

@app.get("/api/doctor")
@auth("ro")
def doctor():
    bins = ["termux-battery-status", "termux-wifi-connectioninfo", "termux-tts-speak",
            "termux-notification", "termux-vibrate", "termux-torch",
            "termux-clipboard-get", "termux-clipboard-set",
            "termux-location", "termux-telephony-deviceinfo", "termux-screenshot"]
    return ok(
        binaries={b: which(b) is not None for b in bins},
        platform=platform.platform(),
        python=platform.python_version(),
        config_file=str(CFG_FP),
        config_exists=CFG_FP.exists(),
        tokens_configured={"full": len(_tokens("full")), "ro": len(_tokens("ro"))},
        plugins_dir=str(HOME / CFG.get("plugins_dir", "plugins")),
        rate_limit=CFG["rate_limit"],
        cache_ttl=CFG["cache_ttl"],
    )

# ---------- Termux actions ----------
@app.route("/api/speech", methods=["GET", "POST"])
@auth("full")
def speech():
    if request.method == "POST":
        text = (request.get_json(silent=True) or {}).get("text", "")
    else:
        text = request.args.get("text", "")
    text = str(text or "Sistema L.U.N.A. operativo.")[:1000]
    rc, _, err = _termux("termux-tts-speak", [text], timeout=30)
    return ok(text=text) if rc == 0 else fail(err or "tts falló", 500, "speech.error")

@app.post("/api/notify")
@auth("full")
def notify():
    b = request.get_json(silent=True) or {}
    argv = ["--title", str(b.get("title", "L.U.N.A."))[:100],
            "--content", str(b.get("body", ""))[:500]]
    if b.get("sound"):
        argv.append("--sound")
    if b.get("vibrate"):
        argv.append("--vibrate")
    rc, _, err = _termux("termux-notification", argv)
    return ok() if rc == 0 else fail(err or "notify falló", 500, "notify.error")

@app.post("/api/vibrate")
@auth("full")
def vibrate():
    try:
        ms = int((request.get_json(silent=True) or {}).get("ms", 300))
    except (TypeError, ValueError):
        return fail("ms inválido")
    ms = max(50, min(ms, 5000))
    rc, _, err = _termux("termux-vibrate", ["-d", str(ms)])
    return ok(ms=ms) if rc == 0 else fail(err or "vibrate falló", 500, "vibrate.error")

_TORCH_STATE = {"on": False}
@app.post("/api/torch")
@auth("full")
def torch():
    b = request.get_json(silent=True) or {}
    target = bool(b["on"]) if "on" in b else not _TORCH_STATE["on"]
    rc, _, err = _termux("termux-torch", ["on" if target else "off"])
    if rc == 0:
        _TORCH_STATE["on"] = target
        return ok(on=target)
    return fail(err or "torch falló", 500, "torch.error")

@app.route("/api/clipboard", methods=["GET", "POST"])
@auth("full")
def clipboard():
    if request.method == "GET":
        rc, out, err = _termux("termux-clipboard-get")
        return ok(text=out) if rc == 0 else fail(err, 500, "clipboard.error")
    text = str((request.get_json(silent=True) or {}).get("text", ""))[:10000]
    rc, _, err = _termux("termux-clipboard-set", [text])
    return ok() if rc == 0 else fail(err or "clipboard falló", 500, "clipboard.error")

@app.get("/api/location")
@auth("ro")
def location():
    d = _termux_json("termux-location", cache_key="location:now", timeout=15)
    return ok(d) if d else fail("location no disponible", 503, "location.unavailable")

@app.get("/api/device")
@auth("ro")
def device():
    d = _termux_json("termux-telephony-deviceinfo", cache_key="telephony:info") or {}
    d.setdefault("platform", platform.platform())
    d.setdefault("hostname", platform.node())
    return ok(d)

@app.post("/api/screenshot")
@auth("full")
def screenshot():
    path = str((request.get_json(silent=True) or {}).get("path", "/sdcard/luna_shot.png"))
    rc, _, err = _termux("termux-screenshot", ["-f", path], timeout=15)
    return ok(path=path) if rc == 0 else fail(err or "screenshot falló", 500, "screenshot.error")

# ---------- plugins ----------
def load_plugins():
    pdir = HOME / CFG.get("plugins_dir", "plugins")
    if not pdir.is_dir():
        return
    sys.path.insert(0, str(pdir))
    for fp in sorted(pdir.glob("*.py")):
        if fp.name.startswith("_"):
            continue
        try:
            mod = __import__(fp.stem)
            if hasattr(mod, "register"):
                mod.register(app, CACHE=CACHE, log=log, config=CFG,
                             helpers={"termux": _termux, "termux_json": _termux_json,
                                      "ok": ok, "fail": fail, "auth": auth})
                log.info("plugin cargado: %s", fp.name)
            else:
                log.warning("plugin sin register(): %s", fp.name)
        except Exception:
            log.exception("error cargando plugin %s", fp.name)

# ---------- error handlers ----------
@app.errorhandler(404)
def _404(_):
    return fail("not found", 404, "http.notfound")

@app.errorhandler(405)
def _405(_):
    return fail("method not allowed", 405, "http.method")

@app.errorhandler(Exception)
def _500(e):
    log.exception("unhandled")
    return fail(str(e), 500, "internal.error")

# ---------- server ----------
def _pick_port(p, host):
    if not CFG.get("port_auto"):
        return p
    for cand in range(p, p + 10):
        with socket.socket() as s:
            try:
                s.bind((host, cand)); return cand
            except OSError:
                continue
    raise SystemExit(f"sin puerto libre cerca de {p}")

def _serve():
    mode = CFG.get("server", "auto")
    host, port = CFG["host"], CFG["port"]
    if mode in ("auto", "waitress"):
        try:
            from waitress import serve
            log.info("L.U.N.A. v%s (waitress) http://%s:%d", VERSION, host, port)
            serve(app, host=host, port=port, threads=8, connection_limit=100)
            return
        except ImportError:
            if mode == "waitress":
                log.error("waitress no instalado"); sys.exit(1)
    log.info("L.U.N.A. v%s (werkzeug) http://%s:%d", VERSION, host, port)
    app.run(host=host, port=port, threaded=True, debug=CFG["debug"])

if __name__ == "__main__":
    load_plugins()
    CFG["port"] = _pick_port(CFG["port"], CFG["host"])
    if _tokens("full") or _tokens("ro"):
        log.info("auth ACTIVA — full=%d ro=%d",
                 len(_tokens("full")), len(_tokens("ro")))
    else:
        log.warning("SIN tokens: endpoints de escritura abiertos")
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt))
    try:
        _serve()
    except KeyboardInterrupt:
        log.info("detenida"); sys.exit(0)
PYEOF

chmod +x "$CORE"
python -m py_compile "$CORE" || die "error de sintaxis en luna_core.py"
OK "Core escrito y compilado."

# ============================================================
# 5. HUD — completa (patch_hud.sh + tablas + arena)
# ============================================================
LOG "Escribiendo HUD…"
cat > "$STATIC/hud.html" <<'HTMLEOF'
<!DOCTYPE html>
<html lang="es"><head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>L.U.N.A. — Command Center</title>
<style>
:root{--bg:#080b10;--fg:#00f3ff;--ac:#00ff88;--mut:#5a6b7a;--err:#ff4466;--warn:#ffcc44;--line:rgba(0,243,255,.22)}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html,body{margin:0;padding:0;background:var(--bg);color:var(--fg);font-family:ui-monospace,Menlo,monospace;font-size:14px;min-height:100vh}
body{display:flex;flex-direction:column}
header{padding:10px 14px;display:flex;justify-content:space-between;align-items:center;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--bg);z-index:10}
h1{margin:0;font-size:1em;letter-spacing:3px}
#conn{font-size:.78em;color:var(--mut);display:flex;align-items:center;gap:6px}
#conn-dot{width:8px;height:8px;border-radius:50%;background:var(--err);transition:background .3s,box-shadow .3s}
#conn-dot.on{background:var(--ac);box-shadow:0 0 8px var(--ac)}
nav{display:flex;overflow-x:auto;border-bottom:1px solid var(--line);scrollbar-width:none}
nav::-webkit-scrollbar{display:none}
.tab{flex:0 0 auto;background:transparent;color:var(--mut);border:0;padding:10px 14px;font-family:inherit;font-size:.82em;cursor:pointer;border-bottom:2px solid transparent;white-space:nowrap}
.tab.active{color:var(--fg);border-bottom-color:var(--ac)}
main{flex:1;padding:14px;padding-bottom:60px}
.section{display:none}
.section.active{display:block;animation:fade .2s}
@keyframes fade{from{opacity:0;transform:translateY(4px)}to{opacity:1;transform:none}}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px}
.card{border:1px solid var(--line);border-radius:10px;padding:12px;background:rgba(0,243,255,.04)}
.card h3{font-size:.68em;color:var(--mut);margin:0 0 6px;text-transform:uppercase;letter-spacing:1px}
.card .v{color:var(--ac);font-size:1.25em;font-weight:700}
.card .s{color:var(--mut);font-size:.72em;margin-top:4px}
.bar{height:4px;background:rgba(0,243,255,.08);border-radius:2px;margin-top:8px;overflow:hidden}
.bar>i{display:block;height:100%;background:var(--ac);width:0;transition:width .4s}
.actions{display:flex;flex-wrap:wrap;gap:8px;margin-top:14px}
button,.btn{background:transparent;color:var(--fg);border:1px solid var(--fg);border-radius:6px;padding:10px 14px;font-family:inherit;font-size:.88em;cursor:pointer;min-height:40px;transition:background .15s,transform .05s}
button:hover,.btn:hover{background:rgba(0,243,255,.1)}
button:active{transform:scale(.97)}
button.accent{color:var(--ac);border-color:var(--ac)}
button.accent:hover{background:rgba(0,255,136,.1)}
button.danger{color:var(--err);border-color:var(--err)}
button.danger:hover{background:rgba(255,68,102,.1)}
button:disabled{opacity:.4;cursor:not-allowed}
input,textarea,select{width:100%;background:rgba(0,243,255,.03);color:var(--fg);border:1px solid var(--line);border-radius:6px;padding:10px;font-family:inherit;font-size:.92em;min-height:40px}
input:focus,textarea:focus,select:focus{outline:none;border-color:var(--ac)}
textarea{min-height:80px;resize:vertical}
.row{display:flex;gap:8px;margin-bottom:10px;flex-wrap:wrap}
.row>*{flex:1;min-width:120px}
.list{display:flex;flex-direction:column;gap:6px;margin-top:10px}
.item{border:1px solid var(--line);border-radius:8px;padding:10px 12px;background:rgba(0,243,255,.03);display:flex;justify-content:space-between;align-items:center;gap:8px}
.item-info{flex:1;min-width:0}
.item-title{font-size:.9em;word-break:break-word}
.item-sub{font-size:.72em;color:var(--mut);margin-top:3px;word-break:break-word}
.item-actions{display:flex;gap:6px;flex-wrap:wrap;justify-content:flex-end}
.item-actions button{min-height:32px;padding:6px 10px;font-size:.78em}
.badge{display:inline-block;font-size:.68em;padding:2px 7px;border-radius:10px;background:rgba(0,243,255,.12);color:var(--fg);text-transform:uppercase;letter-spacing:.5px}
.badge.ok{background:rgba(0,255,136,.15);color:var(--ac)}
.badge.err{background:rgba(255,68,102,.15);color:var(--err)}
.badge.warn{background:rgba(255,204,68,.15);color:var(--warn)}
.hint{color:var(--mut);font-size:.78em;margin:4px 0 10px}
pre.out{background:rgba(0,243,255,.03);border:1px solid var(--line);border-radius:8px;padding:12px;font-size:.82em;overflow-x:auto;max-height:50vh;overflow-y:auto;white-space:pre-wrap;word-break:break-word;margin:8px 0 0;color:var(--ac)}
.toast{position:fixed;bottom:20px;left:50%;transform:translateX(-50%) translateY(20px);background:var(--ac);color:#000;padding:10px 18px;border-radius:20px;font-size:.85em;opacity:0;pointer-events:none;transition:.3s;z-index:100;max-width:90vw;text-align:center}
.toast.show{opacity:1;transform:translateX(-50%) translateY(0)}
.toast.err{background:var(--err);color:#fff}
.modal{position:fixed;inset:0;background:rgba(0,0,0,.85);display:none;z-index:50;padding:20px;overflow-y:auto}
.modal.show{display:flex;flex-direction:column;align-items:center;justify-content:center}
.modal-content{width:100%;max-width:800px;background:var(--bg);border:1px solid var(--line);border-radius:12px;padding:16px;max-height:90vh;display:flex;flex-direction:column}
.modal-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:10px}
.modal-close{background:transparent;border:1px solid var(--err);color:var(--err);border-radius:50%;width:36px;height:36px;padding:0;font-size:1.1em}
.modal-body{flex:1;overflow-y:auto;min-height:0}
.pair-box{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin:12px 0}
.pair-card{border:1px solid var(--line);border-radius:10px;padding:16px;background:rgba(0,243,255,.04)}
.pair-card .name{font-size:1em;color:var(--ac);font-weight:700;margin-bottom:6px;word-break:break-word}
.pair-card .meta{font-size:.72em;color:var(--mut)}
.pair-card pre{background:rgba(0,0,0,.3);border-radius:6px;padding:10px;font-size:.78em;max-height:200px;overflow-y:auto;color:var(--fg);white-space:pre-wrap;word-break:break-word}
.vote-btns{display:grid;grid-template-columns:1fr 1fr 1fr;gap:8px;margin:12px 0}
table{width:100%;border-collapse:collapse;margin-top:10px;font-size:.85em}
th,td{border-bottom:1px solid var(--line);padding:8px 6px;text-align:left}
th{color:var(--mut);font-size:.72em;text-transform:uppercase;letter-spacing:1px;font-weight:400}
td.rank{color:var(--ac);font-weight:700;width:40px}
.empty{color:var(--mut);text-align:center;padding:20px;font-size:.85em}
.spinner{display:inline-block;width:14px;height:14px;border:2px solid var(--mut);border-top-color:var(--ac);border-radius:50%;animation:spin .8s linear infinite;vertical-align:middle;margin-right:6px}
@keyframes spin{to{transform:rotate(360deg)}}
</style>
</head><body>

<header>
  <h1>L.U.N.A.</h1>
  <div id="conn"><span id="conn-dot"></span><span id="conn-text">conectando…</span></div>
</header>
<nav>
  <button class="tab active" data-tab="dashboard">📊 Dashboard</button>
  <button class="tab" data-tab="apps">📱 Apps</button>
  <button class="tab" data-tab="tasks">⚙️ Tareas</button>
  <button class="tab" data-tab="ai">🤖 IA</button>
  <button class="tab" data-tab="arena">⚔️ Arena</button>
  <button class="tab" data-tab="tools">🔧 Herramientas</button>
  <button class="tab" data-tab="licenses">📜 Licencias</button>
  <button class="tab" data-tab="system">💻 Sistema</button>
</nav>
<main>

<section id="section-dashboard" class="section active">
  <div class="grid">
    <div class="card"><h3>Batería</h3><div class="v" id="bat">--</div><div class="s" id="bat_s"></div><div class="bar"><i id="bat_b"></i></div></div>
    <div class="card"><h3>Memoria</h3><div class="v" id="mem">--</div><div class="s" id="mem_s"></div><div class="bar"><i id="mem_b"></i></div></div>
    <div class="card"><h3>Almacenamiento</h3><div class="v" id="sto">--</div><div class="s" id="sto_s"></div><div class="bar"><i id="sto_b"></i></div></div>
    <div class="card"><h3>CPU (1m)</h3><div class="v" id="cpu">--</div><div class="s" id="cpu_s"></div></div>
    <div class="card"><h3>WiFi</h3><div class="v" id="wifi">--</div><div class="s" id="wifi_s"></div></div>
    <div class="card"><h3>Uptime</h3><div class="v" id="upt">--</div><div class="s" id="upt_s"></div></div>
  </div>
  <div class="actions">
    <button onclick="quickAct('speak')">🔊 Hablar</button>
    <button onclick="quickAct('notify')">📣 Notificar</button>
    <button onclick="quickAct('vibrate')">📳 Vibrar</button>
    <button onclick="quickAct('torch')">🔦 Linterna</button>
    <button onclick="quickAct('clipboard')">📋 Portapapeles</button>
    <button onclick="quickAct('screenshot')">📸 Captura</button>
  </div>
</section>

<section id="section-apps" class="section">
  <div class="row">
    <input id="apps-search" placeholder="buscar paquete…" oninput="filterApps()" style="flex:2">
    <select id="apps-scope" onchange="loadApps()">
      <option value="user">Usuario</option>
      <option value="system">Sistema</option>
      <option value="all">Todos</option>
    </select>
    <button onclick="loadApps()" class="accent">↻</button>
  </div>
  <div class="hint" id="apps-hint">Pulsa una app para lanzarla.</div>
  <div class="list" id="apps-list"></div>
</section>

<section id="section-tasks" class="section">
  <div class="card" style="margin-bottom:12px">
    <h3>Nueva tarea</h3>
    <div class="row">
      <input id="task-cmd" placeholder="comando (ej: ffmpeg)">
      <input id="task-args" placeholder="argumentos separados por espacio" style="flex:3">
    </div>
    <div class="row">
      <input id="task-timeout" type="number" value="3600" placeholder="timeout (s)">
      <button onclick="createTask()" class="accent">▶ Crear tarea</button>
    </div>
  </div>
  <div class="row"><button onclick="loadTasks()" class="accent">↻ Actualizar</button></div>
  <div class="list" id="tasks-list"></div>
</section>

<section id="section-ai" class="section">
  <textarea id="ai-prompt" placeholder="Escribe tu pregunta o tarea…"></textarea>
  <div class="row" style="margin-top:10px">
    <select id="ai-provider">
      <option value="">Auto (por tarea)</option>
      <option value="gemini">Gemini 2.0 Flash</option>
      <option value="openai">OpenAI GPT-4o-mini</option>
      <option value="anthropic">Claude 3.5 Sonnet</option>
    </select>
    <button onclick="sendAI()" class="accent" id="ai-send">✨ Enviar</button>
  </div>
  <pre class="out" id="ai-response" style="display:none"></pre>
</section>

<section id="section-arena" class="section">
  <div class="row">
    <input id="arena-prompt" placeholder="Pregunta para comparar modelos…">
    <button onclick="newPair()" class="accent">⚔️ Nuevo par</button>
    <button onclick="showBoard()">🏆 Leaderboard</button>
  </div>
  <div id="arena-pair" class="empty">Escribe una pregunta y pulsa "Nuevo par".</div>
  <div class="card" style="margin-top:14px">
    <h3>Añadir modelo</h3>
    <div class="row">
      <input id="arena-new-model" placeholder="nombre del modelo">
      <button onclick="addModel()" class="accent">Añadir</button>
    </div>
  </div>
  <div id="arena-board-container" style="display:none">
    <h3 style="margin-top:16px">🏆 Leaderboard</h3>
    <div id="arena-board"></div>
  </div>
</section>

<section id="section-tools" class="section">
  <div class="row"><button onclick="loadTools()" class="accent">↻ Recargar</button></div>
  <div class="list" id="tools-list"></div>
</section>

<section id="section-licenses" class="section">
  <div class="row">
    <input id="lic-search" placeholder="buscar: MIT, GPL, Apache…" oninput="filterLicenses()">
    <button onclick="loadLicenses()" class="accent">↻</button>
  </div>
  <div class="hint" id="lic-hint">Catálogo SPDX (~600 licencias, cacheado).</div>
  <div class="list" id="lic-list"></div>
</section>

<section id="section-system" class="section">
  <div class="card" style="margin-bottom:12px">
    <h3>Root</h3>
    <div id="root-status" class="hint">Consultando…</div>
    <div class="row" style="margin-top:10px">
      <input id="root-cmd" placeholder="comando root (ej: ls /data/data)">
      <button onclick="runRoot()" class="danger">⚡ Ejecutar</button>
    </div>
    <pre class="out" id="root-output" style="display:none"></pre>
  </div>
  <div class="card">
    <h3>Diagnóstico</h3>
    <button onclick="loadDoctor()" class="accent">↻ Doctor</button>
    <pre class="out" id="doctor-output" style="display:none"></pre>
  </div>
</section>
</main>

<div id="toast" class="toast"></div>
<div id="modal" class="modal">
  <div class="modal-content">
    <div class="modal-header">
      <strong id="modal-title">Salida</strong>
      <button class="modal-close" onclick="closeModal()">×</button>
    </div>
    <div class="modal-body"><pre class="out" id="modal-output"></pre></div>
  </div>
</div>

<script>
"use strict";
const TOKEN = new URLSearchParams(location.search).get("token") || localStorage.getItem("luna_token") || "";
if (TOKEN) localStorage.setItem("luna_token", TOKEN);
const AUTH_H = TOKEN ? { "X-Luna-Token": TOKEN } : {};

async function api(path, opts) {
  opts = opts || {};
  const h = Object.assign({}, AUTH_H, opts.headers || {});
  const o = { method: opts.method || "GET", headers: h };
  if (opts.body !== undefined) {
    h["Content-Type"] = "application/json";
    o.body = JSON.stringify(opts.body);
  }
  try {
    const r = await fetch(path, o);
    return await r.json();
  } catch (e) {
    return { ok: false, error: e.message || String(e) };
  }
}

const $ = id => document.getElementById(id);
function toast(msg, err) {
  const t = $("toast");
  t.textContent = msg;
  t.className = "toast show" + (err ? " err" : "");
  setTimeout(() => { t.className = "toast"; }, 2200);
}
function esc(s) {
  return String(s == null ? "" : s).replace(/[&<>"']/g, c =>
    ({ "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c]));
}
function openModal(title) {
  $("modal-title").textContent = title;
  $("modal-output").textContent = "";
  $("modal").classList.add("show");
}
function closeModal() {
  $("modal").classList.remove("show");
  if (window._taskES) { window._taskES.close(); window._taskES = null; }
}

const TABS = ["dashboard","apps","tasks","ai","arena","tools","licenses","system"];
const LOADED = {};
function showTab(name) {
  TABS.forEach(t => {
    const sec = $("section-" + t);
    const tab = document.querySelector('.tab[data-tab="' + t + '"]');
    if (sec) sec.classList.toggle("active", t === name);
    if (tab) tab.classList.toggle("active", t === name);
  });
  location.hash = name;
  if (LOADED[name]) return;
  LOADED[name] = true;
  if (name === "apps") loadApps();
  else if (name === "tasks") loadTasks();
  else if (name === "arena") loadBoard();
  else if (name === "tools") loadTools();
  else if (name === "licenses") loadLicenses();
  else if (name === "system") loadSystem();
}
document.querySelectorAll(".tab").forEach(b =>
  b.addEventListener("click", () => showTab(b.dataset.tab)));

// ---------- SSE ----------
let es = null;
function connectSSE() {
  if (es) { try { es.close(); } catch(_) {} }
  const url = "/api/stream?interval=2" + (TOKEN ? "&token=" + encodeURIComponent(TOKEN) : "");
  es = new EventSource(url);
  es.addEventListener("telemetry", e => {
    $("conn-dot").className = "on";
    $("conn-text").textContent = "conectado";
    try { renderTelemetry(JSON.parse(e.data)); } catch(_) {}
  });
  es.onerror = () => {
    $("conn-dot").className = "";
    $("conn-text").textContent = "reconectando…";
  };
}
function fmtTime(s) {
  if (s == null) return "--";
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
  return h + "h " + m + "m";
}
function gb(kb) { return ((kb || 0) / 1048576).toFixed(1); }
function renderTelemetry(d) {
  const b = d.battery || {}, m = d.memory || {}, st = d.storage || {}, c = d.cpu || {}, w = d.wifi || {};
  $("bat").textContent = (b.pct || 0) + "%";
  $("bat_s").textContent = (b.plugged || "--") + " · " + (b.temp_c || 0) + "°C";
  $("bat_b").style.width = Math.min(100, Math.max(0, b.pct || 0)) + "%";
  $("mem").textContent = (m.used_pct || 0) + "%";
  $("mem_s").textContent = gb(m.used_kb) + " / " + gb(m.total_kb) + " GB";
  $("mem_b").style.width = (m.used_pct || 0) + "%";
  $("sto").textContent = (st.used_pct || 0) + "%";
  $("sto_s").textContent = (st.free_gb || 0) + " GB libres";
  $("sto_b").style.width = (st.used_pct || 0) + "%";
  $("cpu").textContent = (c["1m"] || 0).toFixed(2);
  $("cpu_s").textContent = "5m " + (c["5m"] || 0).toFixed(2) + " · 15m " + (c["15m"] || 0).toFixed(2);
  $("wifi").textContent = w.ssid || "(sin wifi)";
  $("wifi_s").textContent = w.ip ? (w.ip + " · " + w.rssi + "dBm") : "--";
  $("upt").textContent = fmtTime(d.uptime_s);
  $("upt_s").textContent = d.host || "";
}

// ---------- Quick actions ----------
const QUICK = {
  speak:      { url: "/api/speech",     body: { text: "Hola señor Javier, todos los sistemas operativos." } },
  notify:     { url: "/api/notify",     body: { title: "L.U.N.A.", body: "Prueba", sound: true, vibrate: true } },
  vibrate:    { url: "/api/vibrate",    body: { ms: 300 } },
  torch:      { url: "/api/torch",      body: {} },
  clipboard:  { url: "/api/clipboard",  body: { text: "L.U.N.A. " + new Date().toISOString() } },
  screenshot: { url: "/api/screenshot", body: {} },
};
async function quickAct(kind) {
  const m = QUICK[kind];
  if (!m) return;
  const j = await api(m.url, { method: "POST", body: m.body });
  toast(j.ok ? "✔ " + kind : "✘ " + (j.error || "error"), !j.ok);
}

// ---------- Apps ----------
let ALL_APPS = [];
async function loadApps() {
  const scope = $("apps-scope").value;
  $("apps-hint").innerHTML = '<span class="spinner"></span>cargando…';
  const j = await api("/api/apps?scope=" + scope);
  if (!j.ok) { $("apps-hint").textContent = "Error: " + (j.error || "?"); return; }
  ALL_APPS = j.packages || [];
  $("apps-hint").textContent = ALL_APPS.length + " apps (" + scope + "). Pulsa para lanzar.";
  filterApps();
}
function filterApps() {
  const q = ($("apps-search").value || "").toLowerCase().trim();
  const list = q ? ALL_APPS.filter(p => p.toLowerCase().includes(q)) : ALL_APPS;
  const el = $("apps-list");
  if (!list.length) { el.innerHTML = '<div class="empty">(sin resultados)</div>'; return; }
  el.innerHTML = list.slice(0, 300).map(p =>
    '<div class="item"><div class="item-info"><div class="item-title">' + esc(p) + '</div></div>' +
    '<div class="item-actions"><button onclick="launchApp(\'' + esc(p) + '\')">▶</button></div></div>'
  ).join("") + (list.length > 300 ? '<div class="empty">+' + (list.length - 300) + ' más (refina búsqueda)</div>' : "");
}
async function launchApp(pkg) {
  const j = await api("/api/apps/launch", { method: "POST", body: { package: pkg } });
  toast(j.ok ? "▶ " + pkg.split(".").pop() : "✘ " + (j.error || "no se pudo lanzar"), !j.ok);
}

// ---------- Tasks ----------
async function loadTasks() {
  const j = await api("/api/tasks");
  const el = $("tasks-list");
  if (!j.ok) {
    el.innerHTML = '<div class="empty">Tareas no habilitadas.<br><small>' + esc(j.error || "") + '</small></div>';
    return;
  }
  const list = j.tasks || [];
  if (!list.length) { el.innerHTML = '<div class="empty">Sin tareas</div>'; return; }
  el.innerHTML = list.map(t => {
    const badge = t.status === "done" ? "ok"
      : ["failed", "timeout", "killed"].includes(t.status) ? "err" : "warn";
    const cmdline = esc(t.cmd + " " + (t.args || []).join(" "));
    return '<div class="item"><div class="item-info">' +
      '<div class="item-title">' + cmdline + '</div>' +
      '<div class="item-sub"><span class="badge ' + badge + '">' + esc(t.status) + '</span> ' +
      'rc=' + (t.exit_code != null ? t.exit_code : '-') + ' · ' + Math.round(t.duration_s) + 's · ' + esc(t.id) + '</div>' +
      '</div><div class="item-actions">' +
      '<button onclick="followTask(\'' + esc(t.id) + '\')">📺</button>' +
      (["queued", "running"].includes(t.status)
        ? '<button class="danger" onclick="killTask(\'' + esc(t.id) + '\')">■</button>' : '') +
      '</div></div>';
  }).join("");
}
async function createTask() {
  const cmd = $("task-cmd").value.trim();
  const argsRaw = $("task-args").value.trim();
  const timeout = parseInt($("task-timeout").value || "3600", 10);
  if (!cmd) { toast("Falta el comando", true); return; }
  const args = argsRaw ? argsRaw.split(/\s+/) : [];
  const j = await api("/api/tasks", { method: "POST", body: { cmd, args, timeout, notify: true } });
  if (j.ok) { toast("✔ tarea creada: " + j.task_id); loadTasks(); }
  else toast("✘ " + (j.error || "error"), true);
}
function followTask(tid) {
  openModal("Tarea " + tid);
  const url = "/api/tasks/" + tid + "/stream" + (TOKEN ? "?token=" + encodeURIComponent(TOKEN) : "");
  const es2 = new EventSource(url);
  window._taskES = es2;
  const out = $("modal-output");
  out.textContent = "";
  es2.addEventListener("line", e => {
    try {
      const d = JSON.parse(e.data);
      out.textContent += (d.text || "") + "\n";
      out.scrollTop = out.scrollHeight;
    } catch(_) {}
  });
  es2.addEventListener("end", e => {
    try {
      const d = JSON.parse(e.data);
      out.textContent += "\n[FIN] " + d.status + " rc=" + d.exit_code;
    } catch(_) {}
    es2.close();
  });
  es2.onerror = () => { out.textContent += "\n[conexión cerrada]"; es2.close(); };
}
async function killTask(tid) {
  const j = await api("/api/tasks/" + tid + "/kill", { method: "POST", body: {} });
  toast(j.ok ? "■ " + tid : "✘ " + (j.error || "error"), !j.ok);
  loadTasks();
}

// ---------- AI ----------
async function sendAI() {
  const prompt = $("ai-prompt").value.trim();
  if (!prompt) { toast("Escribe algo primero", true); return; }
  const provider = $("ai-provider").value || undefined;
  $("ai-send").disabled = true;
  $("ai-response").style.display = "block";
  $("ai-response").textContent = "⏳ consultando…";
  const j = await api("/api/ai", { method: "POST", body: { prompt, provider } });
  $("ai-send").disabled = false;
  if (j.ok) {
    $("ai-response").textContent = "[" + j.provider + " / " + j.model + "]\n\n" + j.text;
  } else {
    $("ai-response").textContent = "✘ " + (j.error || "error");
  }
}

// ---------- Arena ----------
async function newPair() {
  const prompt = $("arena-prompt").value.trim();
  if (!prompt) { toast("Escribe una pregunta", true); return; }
  $("arena-pair").innerHTML = '<span class="spinner"></span>consultando modelos…';
  const j = await api("/api/arena/pair", { method: "POST", body: { prompt } });
  if (!j.ok) { $("arena-pair").textContent = "✘ " + (j.error || "error"); return; }
  const p = j.pair;
  $("arena-pair").innerHTML =
    '<div class="pair-box">' +
      '<div class="pair-card"><div class="name">' + esc(p.a.model) + '</div>' +
        '<pre>' + esc(p.a.text) + '</pre>' +
        '<button onclick="vote(\'' + p.id + '\',\'a\')" class="accent">A mejor</button></div>' +
      '<div class="pair-card"><div class="name">' + esc(p.b.model) + '</div>' +
        '<pre>' + esc(p.b.text) + '</pre>' +
        '<button onclick="vote(\'' + p.id + '\',\'b\')" class="accent">B mejor</button></div>' +
    '</div>' +
    '<div class="vote-btns">' +
      '<button onclick="vote(\'' + p.id + '\',\'tie\')">🤝 Empate</button>' +
      '<button onclick="vote(\'' + p.id + '\',\'a\')">A mejor</button>' +
      '<button onclick="vote(\'' + p.id + '\',\'b\')">B mejor</button>' +
    '</div>';
}
async function vote(pairId, choice) {
  const j = await api("/api/arena/vote", { method: "POST", body: { id: pairId, choice } });
  toast(j.ok ? "✔ voto registrado" : "✘ " + (j.error || "error"), !j.ok);
  if (j.ok) newPair();
}
async function showBoard() {
  $("arena-board-container").style.display = "block";
  $("arena-board").innerHTML = '<span class="spinner"></span>cargando…';
  const j = await api("/api/arena/leaderboard");
  if (!j.ok) { $("arena-board").textContent = "✘ " + (j.error || "error"); return; }
  const rows = (j.leaderboard || []).map((m, i) =>
    '<tr><td class="rank">' + (i + 1) + '</td><td>' + esc(m.model) +
    '</td><td>' + Math.round(m.elo) + '</td><td>' + m.wins + '/' + m.losses +
    ' (' + m.games + ')</td></tr>').join("");
  $("arena-board").innerHTML =
    '<table><thead><tr><th>#</th><th>Modelo</th><th>ELO</th><th>W/L (juegos)</th></tr></thead>' +
    '<tbody>' + (rows || '<tr><td colspan="4" class="empty">Sin datos aún</td></tr>') + '</tbody></table>';
}
async function loadBoard() { /* lazy */ }
async function addModel() {
  const name = $("arena-new-model").value.trim();
  if (!name) return;
  const j = await api("/api/arena/models", { method: "POST", body: { name } });
  if (j.ok) { toast("✔ modelo añadido"); $("arena-new-model").value = ""; }
  else toast("✘ " + (j.error || "error"), true);
}

// ---------- Tools ----------
async function loadTools() {
  $("tools-list").innerHTML = '<span class="spinner"></span>cargando…';
  const j = await api("/api/tools");
  if (!j.ok) { $("tools-list").textContent = "✘ " + (j.error || "error"); return; }
  $("tools-list").innerHTML = (j.tools || []).map(t =>
    '<div class="item"><div class="item-info"><div class="item-title">' + esc(t.name) + '</div>' +
    '<div class="item-sub">' + esc(t.desc) + '</div></div>' +
    '<div class="item-actions"><span class="badge ' + (t.installed ? 'ok' : 'warn') + '">' +
    (t.installed ? 'instalado' : 'no instalado') + '</span>' +
    (t.installed ? '' : '<button onclick="installTool(\'' + esc(t.name) + '\')">⬇</button>') +
    '</div></div>'
  ).join("");
}
async function installTool(name) {
  toast("⏳ instalando " + name + "…");
  const j = await api("/api/tools/install", { method: "POST", body: { name } });
  toast(j.ok ? "✔ " + name : "✘ " + (j.error || "error"), !j.ok);
  loadTools();
}

// ---------- Licenses ----------
let ALL_LIC = [];
async function loadLicenses() {
  $("lic-hint").innerHTML = '<span class="spinner"></span>descargando catálogo SPDX…';
  const j = await api("/api/licenses");
  if (!j.ok) { $("lic-hint").textContent = "✘ " + (j.error || "error"); return; }
  ALL_LIC = j.licenses || [];
  $("lic-hint").textContent = ALL_LIC.length + " licencias SPDX.";
  filterLicenses();
}
function filterLicenses() {
  const q = ($("lic-search").value || "").toLowerCase().trim();
  const list = q ? ALL_LIC.filter(l => (l.id + " " + l.name).toLowerCase().includes(q)) : ALL_LIC;
  $("lic-list").innerHTML = list.slice(0, 200).map(l =>
    '<div class="item"><div class="item-info"><div class="item-title">' + esc(l.id) + '</div>' +
    '<div class="item-sub">' + esc(l.name) + ' · OSI=' + (l.osi ? 'sí' : 'no') + '</div></div>' +
    '</div>'
  ).join("") + (list.length > 200 ? '<div class="empty">+' + (list.length - 200) + ' más</div>' : "");
}

// ---------- System ----------
async function loadSystem() {
  const j = await api("/api/root/status");
  $("root-status").innerHTML = j.ok
    ? (j.rooted ? '✅ root detectado (' + esc(j.su_path) + ')' : '❌ sin root · su=' + esc(j.su_path || 'no'))
    : '✘ ' + esc(j.error || 'error');
}
async function runRoot() {
  const cmd = $("root-cmd").value.trim();
  if (!cmd) return;
  $("root-output").style.display = "block";
  $("root-output").textContent = "⏳ ejecutando…";
  const j = await api("/api/root/exec", { method: "POST", body: { cmd } });
  $("root-output").textContent = j.ok
    ? (j.output || "(sin salida)")
    : "✘ " + (j.error || "error");
}
async function loadDoctor() {
  $("doctor-output").style.display = "block";
  $("doctor-output").textContent = "⏳ consultando…";
  const j = await api("/api/doctor");
  $("doctor-output").textContent = JSON.stringify(j, null, 2);
}

connectSSE();
const startTab = (location.hash || "#dashboard").slice(1);
if (TABS.includes(startTab)) showTab(startTab);
</script>
</body></html>
HTMLEOF
OK "HUD instalado en $STATIC/hud.html"

# ============================================================
# 6. PLUGINS
# ============================================================
LOG "Escribiendo plugins…"

# ---------- apps ----------
cat > "$PLUGINS/apps.py" <<'PYEOF'
"""plugins/apps.py — apps Android: listar, buscar, lanzar, intents."""
import subprocess

def _run(argv, timeout=10):
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except Exception as e:
        return 1, "", str(e)

def _packages(scope="user"):
    args = ["pm", "list", "packages"]
    if scope == "user":
        args.append("-3")
    elif scope == "system":
        args.append("-s")
    rc, out, _ = _run(args)
    return [l.split("package:", 1)[1].strip()
            for l in out.splitlines() if l.startswith("package:")]

def register(app, **ctx):
    ok, fail, auth = ctx["helpers"]["ok"], ctx["helpers"]["fail"], ctx["helpers"]["auth"]
    from flask import request

    @app.get("/api/apps")
    @auth("ro")
    def _list():
        scope = request.args.get("scope", "user")
        if scope not in ("user", "system", "all"):
            scope = "user"
        pkgs = _packages(scope)
        return ok(count=len(pkgs), packages=pkgs, scope=scope)

    @app.get("/api/apps/search")
    @auth("ro")
    def _search():
        q = (request.args.get("q") or "").lower()
        hits = [p for p in _packages("all") if q in p.lower()]
        return ok(query=q, results=hits[:50])

    @app.post("/api/apps/launch")
    @auth("full")
    def _launch():
        pkg = (request.get_json(silent=True) or {}).get("package", "").strip()
        if not pkg:
            return fail("falta 'package'")
        rc, out, err = _run(["monkey", "-p", pkg,
                             "-c", "android.intent.category.LAUNCHER", "1"])
        if rc != 0:
            rc, out, err = _run(["am", "start", "--user", "0",
                                 "-a", "android.intent.action.MAIN",
                                 "-c", "android.intent.category.LAUNCHER", pkg])
        return ok(package=pkg) if rc == 0 else fail(err or out, 500)

    @app.post("/api/apps/intent")
    @auth("full")
    def _intent():
        b = request.get_json(silent=True) or {}
        action = b.get("action", "android.intent.action.VIEW")
        argv = ["am", "start", "--user", "0", "-a", action]
        if b.get("data"):
            argv += ["-d", b["data"]]
        if b.get("type"):
            argv += ["-t", b["type"]]
        for k, v in (b.get("extras") or {}).items():
            argv += ["--es", k, str(v)]
        rc, out, err = _run(argv)
        return ok(action=action, output=out) if rc == 0 else fail(err or out, 500)

    @app.post("/api/apps/broadcast")
    @auth("full")
    def _broadcast():
        b = request.get_json(silent=True) or {}
        action = b.get("action", "")
        if not action:
            return fail("falta 'action'")
        argv = ["am", "broadcast", "-a", action]
        for k, v in (b.get("extras") or {}).items():
            argv += ["--es", k, str(v)]
        rc, out, err = _run(argv)
        return ok(action=action, output=out) if rc == 0 else fail(err or out, 500)
PYEOF

# ---------- root ----------
cat > "$PLUGINS/root.py" <<'PYEOF'
"""plugins/root.py — su opcional."""
import os, shutil, subprocess

SU = ["/debug_ramdisk/su", "/sbin/su", "/system/bin/su",
      "/system/xbin/su", "/su/bin/su", "/magisk/.core/bin/su"]

def _su():
    for p in SU:
        if shutil.which(p) or os.path.exists(p):
            return p
    return shutil.which("su")

def _root(cmd, timeout=20):
    su = _su()
    if not su:
        return 127, "", "sin binario su"
    try:
        r = subprocess.run([su, "-c", cmd], capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout.strip(), r.stderr.strip()
    except Exception as e:
        return 1, "", str(e)

def register(app, **ctx):
    ok, fail, auth = ctx["helpers"]["ok"], ctx["helpers"]["fail"], ctx["helpers"]["auth"]
    from flask import request

    @app.get("/api/root/status")
    @auth("ro")
    def _status():
        su = _su(); rc, out, _ = _root("id")
        return ok(rooted=(rc == 0 and "uid=0" in out), su_path=su,
                  whoami=out if rc == 0 else None)

    @app.post("/api/root/exec")
    @auth("full")
    def _exec():
        cmd = (request.get_json(silent=True) or {}).get("cmd", "").strip()
        if not cmd:
            return fail("falta 'cmd'")
        rc, out, err = _root(cmd)
        return ok(rc=rc, output=out) if rc == 0 else fail(err or out, 500, "root.exec_failed")

    @app.get("/api/root/packages")
    @auth("full")
    def _sys():
        rc, out, err = _root("pm list packages -s")
        return ok(packages=out.splitlines()) if rc == 0 else fail(err, 500)
PYEOF

# ---------- licenses (SPDX completo + índice detallado del MANIFEST) ----------
cat > "$PLUGINS/licenses.py" <<'PYEOF'
"""plugins/licenses.py — SPDX + índice de compatibilidad (del MANIFEST.json)."""
import json, os, urllib.request
from pathlib import Path

SPDX_URL = "https://raw.githubusercontent.com/spdx/license-list-data/main/json/licenses.json"

# Índice compacto: metadatos legales (inspirado en LICENSES/MANIFEST.json)
SPDX_INDEX = {
    "Apache-2.0":      {"osi": True, "fsf": True, "copyleft": "none",    "commercial": True,  "notice": True},
    "MIT":             {"osi": True, "fsf": True, "copyleft": "none",    "commercial": True},
    "BSD-2-Clause":    {"osi": True, "fsf": True, "copyleft": "none",    "commercial": True},
    "BSD-3-Clause":    {"osi": True, "fsf": True, "copyleft": "none",    "commercial": True, "notice": True, "no_promotion": True},
    "ISC":             {"osi": True, "fsf": True, "copyleft": "none",    "commercial": True},
    "Zlib":            {"osi": True, "fsf": True, "copyleft": "none",    "commercial": True},
    "BSL-1.0":         {"osi": True, "fsf": True, "copyleft": "none",    "commercial": True},
    "MPL-2.0":         {"osi": True, "fsf": True, "copyleft": "weak",    "commercial": True},
    "LGPL-3.0":        {"osi": True, "fsf": True, "copyleft": "weak",    "commercial": True, "dynamic_link_ok": True},
    "GPL-3.0":         {"osi": True, "fsf": True, "copyleft": "strong",  "commercial": True, "incompatible_proprietary": True},
    "AGPL-3.0":        {"osi": True, "fsf": True, "copyleft": "network", "commercial": True, "incompatible_proprietary": True},
    "CC0-1.0":         {"osi": True, "fsf": True, "copyleft": "none",    "commercial": True},
    "CC-BY-4.0":       {"osi": True, "fsf": True, "copyleft": "none",    "commercial": True, "attribution": True},
    "Unlicense":       {"osi": True, "fsf": True, "copyleft": "none",    "commercial": True},
    "Google-APIs-ToS": {"osi": True, "fsf": True, "copyleft": "none",    "commercial": "conditional"},
    "Khronos-Free":    {"osi": True, "fsf": True, "copyleft": "none",    "commercial": True, "attribution": True},
}

def register(app, **ctx):
    ok, fail, auth = ctx["helpers"]["ok"], ctx["helpers"]["fail"], ctx["helpers"]["auth"]
    from flask import request
    home = Path(os.environ.get("LUNA_HOME", Path.home() / ".termux" / "tasker"))
    d = home / "data" / "licenses"
    d.mkdir(parents=True, exist_ok=True)
    cache = d / "licenses.json"

    def _load():
        if cache.exists():
            try:
                return json.loads(cache.read_text())
            except Exception:
                pass
        try:
            with urllib.request.urlopen(SPDX_URL, timeout=20) as r:
                data = json.load(r)
            cache.write_text(json.dumps(data))
            return data
        except Exception as e:
            ctx["log"].warning("SPDX download failed: %s", e)
            return {"licenses": []}

    def _enrich(x):
        lid = x.get("licenseId", "")
        meta = SPDX_INDEX.get(lid, {})
        return {
            "id": lid,
            "name": x.get("name", ""),
            "osi": x.get("isOsiApproved", meta.get("osi", False)),
            "fsf": x.get("isFsfLibre", meta.get("fsf", False)),
            "copyleft": meta.get("copyleft", "unknown"),
            "commercial": meta.get("commercial", "unknown"),
            "url": (x.get("seeAlso") or [""])[0],
        }

    @app.get("/api/licenses")
    @auth("ro")
    def _list():
        data = _load().get("licenses", [])
        return ok(count=len(data), licenses=[_enrich(x) for x in data],
                  spdx_index=SPDX_INDEX)

    @app.get("/api/licenses/<lid>")
    @auth("ro")
    def _get(lid):
        for x in _load().get("licenses", []):
            if x.get("licenseId") == lid:
                return ok(_enrich(x), details=x)
        return fail("licencia no encontrada", 404)

    @app.get("/api/licenses/index")
    @auth("ro")
    def _idx():
        return ok(index=SPDX_INDEX)
PYEOF

# ---------- tools ----------
cat > "$PLUGINS/tools.py" <<'PYEOF'
"""plugins/tools.py — catálogo e instalador de herramientas."""
import shutil, subprocess

CATALOG = {
    "ffmpeg":      "Vídeo/audio: cortar, convertir, comprimir",
    "imagemagick": "Imágenes: convertir, redimensionar, filtros",
    "sox":         "Audio CLI: efectos, normalización",
    "yt-dlp":      "Descarga de vídeo/audio",
    "pandoc":      "Conversión de documentos",
    "jq":          "Procesado JSON",
    "ripgrep":     "Búsqueda ultrarrápida",
    "fzf":         "Selector difuso",
    "htop":        "Monitor de procesos",
    "neovim":      "Editor de código",
}
PKG_MAP = {
    "imagemagick": "imagemagick", "ffmpeg": "ffmpeg", "sox": "sox",
    "yt-dlp": "python-pip", "pandoc": "pandoc", "jq": "jq",
    "ripgrep": "ripgrep", "fzf": "fzf", "htop": "htop", "neovim": "neovim",
}

def register(app, **ctx):
    ok, fail, auth = ctx["helpers"]["ok"], ctx["helpers"]["fail"], ctx["helpers"]["auth"]
    from flask import request

    @app.get("/api/tools")
    @auth("ro")
    def _list():
        return ok(tools=[{"name": k, "desc": v,
                          "installed": shutil.which(k) is not None}
                         for k, v in CATALOG.items()])

    @app.post("/api/tools/install")
    @auth("full")
    def _install():
        name = (request.get_json(silent=True) or {}).get("name", "")
        if name not in CATALOG:
            return fail("herramienta no catalogada", 404)
        pkg = PKG_MAP.get(name, name)
        try:
            subprocess.run(["pkg", "install", "-y", pkg],
                           check=True, capture_output=True, timeout=300)
        except Exception as e:
            return fail(f"instalación falló: {e}", 500)
        return ok(tool=name, installed=shutil.which(name) is not None)
PYEOF

# ---------- AI (multi-provider con Gemini del gemini.py + fallback) ----------
cat > "$PLUGINS/ai.py" <<'PYEOF'
"""plugins/ai.py — router multi-proveedor con selección automática."""
import json, os, urllib.request
from flask import request

PROVIDERS = {
    "gemini": {
        "url": "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
        "env": "GEMINI_API_KEY", "model_default": "gemini-2.0-flash",
    },
    "openai": {
        "url": "https://api.openai.com/v1/chat/completions",
        "env": "OPENAI_API_KEY", "model_default": "gpt-4o-mini",
    },
    "anthropic": {
        "url": "https://api.anthropic.com/v1/messages",
        "env": "ANTHROPIC_API_KEY", "model_default": "claude-3-5-sonnet-latest",
    },
}

def _cfg_models():
    cfg = (getattr(_cfg_models, "_cache", None))
    if cfg is None:
        import json as _j, pathlib as _p
        fp = _p.Path.home() / ".termux" / "tasker" / "config.json"
        try:
            cfg = _j.loads(fp.read_text()).get("ai", {}).get("models", {})
        except Exception:
            cfg = {}
        _cfg_models._cache = cfg
    return cfg

def _call(provider, prompt, system="", model_override=None):
    info = PROVIDERS[provider]
    key = os.environ.get(info["env"])
    if not key:
        raise RuntimeError(f"falta {info['env']}")
    model = model_override or _cfg_models().get(provider) or info["model_default"]

    if provider == "gemini":
        url = info["url"].format(model=model) + f"?key={key}"
        body = {"contents": [{"parts": [{"text": prompt}]}]}
        if system:
            body["systemInstruction"] = {"parts": [{"text": system}]}
        req = urllib.request.Request(url, data=json.dumps(body).encode(),
            headers={"Content-Type": "application/json"})
        r = json.loads(urllib.request.urlopen(req, timeout=120).read())
        return r["candidates"][0]["content"]["parts"][0]["text"]

    if provider == "openai":
        msgs = ([{"role": "system", "content": system}] if system else []) + \
               [{"role": "user", "content": prompt}]
        req = urllib.request.Request(info["url"], data=json.dumps(
            {"model": model, "messages": msgs}).encode(),
            headers={"Authorization": f"Bearer {key}",
                     "Content-Type": "application/json"})
        r = json.loads(urllib.request.urlopen(req, timeout=120).read())
        return r["choices"][0]["message"]["content"]

    if provider == "anthropic":
        req = urllib.request.Request(info["url"], data=json.dumps({
            "model": model, "max_tokens": 4096,
            "system": system or "Eres un asistente técnico.",
            "messages": [{"role": "user", "content": prompt}],
        }).encode(), headers={
            "x-api-key": key, "anthropic-version": "2023-06-01",
            "Content-Type": "application/json"})
        r = json.loads(urllib.request.urlopen(req, timeout=120).read())
        return "".join(b.get("text", "") for b in r.get("content", []))

    raise RuntimeError(f"proveedor desconocido: {provider}")

def _autoselect(prompt):
    low = prompt.lower()
    if any(w in low for w in ("código", "code", "refactor", "debug", "python", "script", "bug")):
        return "anthropic"
    if any(w in low for w in ("imagen", "pdf", "documento", "video", "multimodal")):
        return "gemini"
    return "gemini"

def register(app, **ctx):
    ok, fail, auth = ctx["helpers"]["ok"], ctx["helpers"]["fail"], ctx["helpers"]["auth"]

    @app.post("/api/ai")
    @auth("full")
    def _ai():
        b = request.get_json(silent=True) or {}
        prompt = (b.get("prompt") or "").strip()
        if not prompt:
            return fail("falta 'prompt'")
        provider = b.get("provider") or _autoselect(prompt)
        if provider not in PROVIDERS:
            return fail(f"proveedor no soportado: {provider}", 400)
        try:
            text = _call(provider, prompt, b.get("system", ""), b.get("model"))
            model = _cfg_models().get(provider) or PROVIDERS[provider]["model_default"]
            return ok(provider=provider, model=model, text=text)
        except Exception as e:
            return fail(str(e), 503, "ai.unavailable")

    @app.get("/api/ai/providers")
    @auth("ro")
    def _providers():
        return ok(providers={
            k: {"model": v["model_default"],
                "configured": bool(os.environ.get(v["env"])),
                "env": v["env"]}
            for k, v in PROVIDERS.items()
        })
PYEOF

# ---------- TASKS (SSE completo) ----------
cat > "$PLUGINS/tasks.py" <<'PYEOF'
"""plugins/tasks.py — comandos en background con streaming SSE."""
import json, os, queue, secrets, subprocess, threading, time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path

ALIVE = {"queued", "running"}

class Task:
    __slots__ = ("id","cmd","args","cwd","env","timeout","status","exit_code",
                 "created_at","started_at","ended_at","lines","_subs","_lk",
                 "proc","notify","callback","max_out")
    def __init__(self, cmd, args, cwd, env, timeout, notify, callback, max_out):
        self.id = "t_" + secrets.token_hex(6)
        self.cmd, self.args = cmd, list(args)
        self.cwd, self.env = cwd, env
        self.timeout = timeout
        self.status = "queued"; self.exit_code = None
        self.created_at = time.time(); self.started_at = self.ended_at = None
        self.lines = []; self._subs = []; self._lk = threading.Lock()
        self.proc = None; self.notify, self.callback = notify, callback
        self.max_out = max_out

    def append(self, stream, text):
        with self._lk:
            size = sum(len(x[2]) + 1 for x in self.lines)
            if size >= self.max_out:
                if not self.lines or self.lines[-1][1] != "sys":
                    self.lines.append((len(self.lines), "sys",
                        f"[output truncado a {self.max_out} bytes]", time.time()))
                return
            off, ts = len(self.lines), time.time()
            self.lines.append((off, stream, text, ts))
            for q in list(self._subs):
                try:
                    q.put_nowait({"offset": off, "stream": stream, "text": text, "ts": ts})
                except queue.Full:
                    pass

    def finish(self):
        with self._lk:
            ev = {"end": True, "status": self.status,
                  "exit_code": self.exit_code, "ended_at": self.ended_at}
            for q in list(self._subs):
                try:
                    q.put_nowait(ev)
                except queue.Full:
                    pass
            self._subs.clear()

    def subscribe(self, since=0):
        q = queue.Queue(maxsize=2000)
        with self._lk:
            for off, stream, text, ts in self.lines[since:]:
                q.put_nowait({"offset": off, "stream": stream, "text": text, "ts": ts})
            if self.status in ALIVE:
                self._subs.append(q)
            else:
                q.put_nowait({"end": True, "status": self.status,
                              "exit_code": self.exit_code, "ended_at": self.ended_at})
        return q

    def unsubscribe(self, q):
        with self._lk:
            try:
                self._subs.remove(q)
            except ValueError:
                pass

    def meta(self):
        return {"id": self.id, "cmd": self.cmd, "args": self.args,
                "cwd": self.cwd, "timeout": self.timeout,
                "status": self.status, "exit_code": self.exit_code,
                "created_at": self.created_at, "started_at": self.started_at,
                "ended_at": self.ended_at,
                "duration_s": round((self.ended_at or time.time())
                                    - (self.started_at or self.created_at), 2),
                "lines": len(self.lines), "callback": self.callback}

_STATE = {"dir": None, "tasks": {}, "lk": threading.Lock(),
          "cfg": {}, "log": None, "termux": None, "pool": None}

def _meta_fp(tid): return _STATE["dir"] / f"{tid}.json"
def _log_fp(tid):  return _STATE["dir"] / f"{tid}.log"

def _persist(t):
    if not _STATE["dir"]:
        return
    try:
        _meta_fp(t.id).write_text(json.dumps(t.meta(), indent=2))
    except Exception as e:
        _STATE["log"].warning("persist %s: %s", t.id, e)

def _append_log(t, stream, text, ts):
    if not _STATE["dir"]:
        return
    try:
        with _log_fp(t.id).open("a") as f:
            f.write(f"{datetime.fromtimestamp(ts, timezone.utc).isoformat()} {stream} {text}\n")
    except Exception:
        pass

def _notify_done(t):
    if not t.notify or not _STATE["termux"]:
        return
    try:
        _STATE["termux"]("termux-notification", [
            "--title", f"L.U.N.A. — {t.status}",
            "--content", f"{t.cmd} {' '.join(t.args)} → rc={t.exit_code} ({t.meta()['duration_s']}s)"])
    except Exception as e:
        _STATE["log"].warning("notify: %s", e)

def _fire_webhook(t):
    if not t.callback or not t.callback.startswith(("http://", "https://")):
        return
    try:
        import urllib.request
        req = urllib.request.Request(t.callback,
            data=json.dumps(t.meta()).encode(),
            headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=10).read()
    except Exception as e:
        _STATE["log"].warning("webhook: %s", e)

def _worker(t):
    # Una tarea cancelada mientras esperaba en la cola no debe ejecutarse después.
    with t._lk:
        if t.status == "killed":
            t.exit_code = -9
            t.ended_at = time.time()
            cancelled = True
        else:
            t.started_at = time.time(); t.status = "running"
            cancelled = False
    if cancelled:
        t.finish(); _persist(t)
        return
    _persist(t)
    argv = [t.cmd] + t.args
    try:
        t.proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, bufsize=1, cwd=t.cwd, env=t.env)
    except FileNotFoundError:
        t.append("sys", f"comando no encontrado: {t.cmd}")
        t.exit_code = 127; t.status = "failed"; return _finish(t)
    except Exception as e:
        t.append("sys", f"error: {e}")
        t.exit_code = -1; t.status = "failed"; return _finish(t)

    if t.timeout > 0:
        def killer():
            time.sleep(t.timeout)
            if t.proc.poll() is None:
                t.append("sys", f"timeout tras {t.timeout}s")
                t.status = "timeout"
                try: t.proc.kill()
                except Exception: pass
        threading.Thread(target=killer, daemon=True).start()

    try:
        for raw in iter(t.proc.stdout.readline, ""):
            if not raw:
                break
            text = raw.rstrip("\n")
            t.append("out", text)
            _append_log(t, "out", text, time.time())
    except Exception as e:
        t.append("sys", f"read error: {e}")
    finally:
        try: t.proc.stdout.close()
        except Exception: pass

    rc = t.proc.wait(); t.exit_code = rc
    if t.status not in ("timeout", "killed"):
        t.status = "done" if rc == 0 else "failed"
    _finish(t)

def _finish(t):
    t.ended_at = time.time()
    t.finish(); _persist(t); _notify_done(t); _fire_webhook(t)

def _load_persisted():
    if not _STATE["dir"]:
        return
    cutoff = time.time() - _STATE["cfg"].get("cleanup_after_s", 604800)
    max_hist = _STATE["cfg"].get("max_history", 100)
    files = sorted(_STATE["dir"].glob("*.json"),
                   key=lambda p: p.stat().st_mtime, reverse=True)
    for i, fp in enumerate(files):
        try:
            meta = json.loads(fp.read_text())
            if fp.stat().st_mtime < cutoff or i >= max_hist:
                fp.unlink(missing_ok=True)
                _log_fp(meta["id"]).unlink(missing_ok=True)
                continue
            if meta.get("status") in ALIVE:
                meta["status"] = "interrupted"
            t = Task(meta["cmd"], meta.get("args", []), meta.get("cwd"),
                     None, 0, False, None, 0)
            t.id = meta["id"]; t.status = meta["status"]
            t.exit_code = meta.get("exit_code")
            t.created_at = meta.get("created_at", 0)
            t.started_at = meta.get("started_at")
            t.ended_at = meta.get("ended_at")
            lf = _log_fp(t.id)
            if lf.exists():
                for line in lf.read_text(errors="replace").splitlines():
                    parts = line.split(" ", 2)
                    if len(parts) == 3:
                        try:
                            ts = datetime.fromisoformat(parts[0]).timestamp()
                            t.lines.append((len(t.lines), parts[1], parts[2], ts))
                        except ValueError:
                            pass
            with _STATE["lk"]:
                _STATE["tasks"][t.id] = t
        except Exception as e:
            _STATE["log"].warning("load %s: %s", fp, e)

def register(app, **ctx):
    _STATE["log"] = ctx["log"]
    _STATE["termux"] = ctx["helpers"]["termux"]
    ok, fail, auth = ctx["helpers"]["ok"], ctx["helpers"]["fail"], ctx["helpers"]["auth"]
    _STATE["cfg"] = (ctx.get("config", {}).get("tasks") or {})
    if not _STATE["cfg"].get("enabled", False):
        _STATE["log"].info("tasks plugin deshabilitado")
        return
    home = Path(os.environ.get("LUNA_HOME", Path.home() / ".termux" / "tasker"))
    _STATE["dir"] = home / "data" / "tasks"
    _STATE["dir"].mkdir(parents=True, exist_ok=True)
    _STATE["pool"] = ThreadPoolExecutor(
        max_workers=_STATE["cfg"].get("max_concurrent", 3),
        thread_name_prefix="luna-task")
    _load_persisted()
    _STATE["log"].info("tasks activo (dir=%s max=%d)",
                       _STATE["dir"], _STATE["cfg"].get("max_concurrent", 3))

    from flask import Response, request, stream_with_context

    def _allowed(cmd):
        allow = _STATE["cfg"].get("commands") or []
        return (not allow) or (cmd in allow)

    @app.post("/api/tasks")
    @auth("full")
    def _create():
        b = request.get_json(silent=True) or {}
        cmd = (b.get("cmd") or b.get("command") or "").strip()
        if not cmd:
            return fail("campo 'cmd' requerido")
        if not _allowed(cmd):
            return fail(f"comando no permitido: {cmd}", 403, "tasks.not_allowed")
        args = b.get("args") or []
        if isinstance(args, str):
            args = [args]
        if not isinstance(args, list) or any(not isinstance(x, (str, int, float)) for x in args):
            return fail("'args' debe ser una lista de argumentos de texto o números")
        try:
            timeout = int(b.get("timeout") or _STATE["cfg"].get("max_runtime_s", 3600))
        except (TypeError, ValueError):
            return fail("timeout inválido")
        timeout = max(1, min(timeout, 86400))
        env = None
        if isinstance(b.get("env"), dict):
            env = os.environ.copy()
            env.update({str(k): str(v) for k, v in b["env"].items()})
        t = Task(cmd, args, b.get("cwd"), env, timeout,
                 bool(b.get("notify", True)), b.get("callback"),
                 _STATE["cfg"].get("max_output_bytes", 524288))
        with _STATE["lk"]:
            _STATE["tasks"][t.id] = t
        _persist(t)
        _STATE["pool"].submit(_worker, t)
        return ok(t.meta(), task_id=t.id,
                  status_url=f"/api/tasks/{t.id}",
                  stream_url=f"/api/tasks/{t.id}/stream")

    @app.get("/api/tasks")
    @auth("ro")
    def _list():
        with _STATE["lk"]:
            items = sorted((t.meta() for t in _STATE["tasks"].values()),
                           key=lambda x: x["created_at"], reverse=True)
        return ok(tasks=items, count=len(items))

    @app.get("/api/tasks/<tid>")
    @auth("ro")
    def _get(tid):
        with _STATE["lk"]:
            t = _STATE["tasks"].get(tid)
        if not t:
            return fail("tarea no encontrada", 404, "tasks.not_found")
        return ok(t.meta())

    @app.get("/api/tasks/<tid>/output")
    @auth("ro")
    def _output(tid):
        with _STATE["lk"]:
            t = _STATE["tasks"].get(tid)
        if not t:
            return fail("tarea no encontrada", 404, "tasks.not_found")
        return ok(task=t.meta(),
                  lines=[{"offset": o, "stream": s, "text": x, "ts": ts}
                         for o, s, x, ts in t.lines])

    @app.get("/api/tasks/<tid>/stream")
    @auth("ro")
    def _stream(tid):
        try:
            since = max(0, int(request.args.get("since", 0)))
        except ValueError:
            since = 0
        with _STATE["lk"]:
            t = _STATE["tasks"].get(tid)
        if not t:
            return fail("tarea no encontrada", 404, "tasks.not_found")
        q = t.subscribe(since)

        def gen():
            try:
                while True:
                    try:
                        item = q.get(timeout=20)
                    except queue.Empty:
                        yield ": keepalive\n\n"; continue
                    if item.get("end"):
                        yield f"event: end\ndata: {json.dumps(item)}\n\n"
                        return
                    yield f"event: line\ndata: {json.dumps(item, ensure_ascii=False)}\n\n"
            finally:
                t.unsubscribe(q)

        return Response(stream_with_context(gen()),
                        mimetype="text/event-stream",
                        headers={"Cache-Control": "no-cache",
                                 "X-Accel-Buffering": "no"})

    @app.post("/api/tasks/<tid>/kill")
    @auth("full")
    def _kill(tid):
        with _STATE["lk"]:
            t = _STATE["tasks"].get(tid)
        if not t:
            return fail("tarea no encontrada", 404, "tasks.not_found")
        if t.status not in ALIVE:
            return fail(f"ya terminó ({t.status})", 409, "tasks.not_running")
        t.append("sys", "kill solicitado")
        t.status = "killed"
        if t.proc:
            try: t.proc.kill()
            except Exception as e: return fail(str(e), 500)
        return ok(task_id=tid, status="killed")

    @app.delete("/api/tasks/<tid>")
    @auth("full")
    def _delete(tid):
        with _STATE["lk"]:
            t = _STATE["tasks"].get(tid)
            if t and t.status in ALIVE:
                t.status = "killed"
                if t.proc:
                    try: t.proc.kill()
                    except Exception: pass
            if t:
                _STATE["tasks"].pop(tid, None)
        if not t:
            return fail("tarea no encontrada", 404, "tasks.not_found")
        _meta_fp(t.id).unlink(missing_ok=True)
        _log_fp(t.id).unlink(missing_ok=True)
        return ok(deleted=tid)
PYEOF

# ---------- ARENA (comparativa ELO) ----------
cat > "$PLUGINS/arena.py" <<'PYEOF'
"""plugins/arena.py — comparativa ELO de modelos."""
import json, os, random, secrets, threading, time
from pathlib import Path

_LK = threading.Lock()
_STATE = {"fp": None, "data": None, "providers": None}

def _load():
    if _STATE["data"] is not None:
        return _STATE["data"]
    fp = _STATE["fp"]
    if fp and fp.exists():
        try:
            _STATE["data"] = json.loads(fp.read_text())
        except Exception:
            _STATE["data"] = {"models": {}, "votes": 0, "pairs": {}}
    else:
        _STATE["data"] = {"models": {}, "votes": 0, "pairs": {}}
    return _STATE["data"]

def _save():
    with _LK:
        try:
            _STATE["fp"].write_text(json.dumps(_STATE["data"], indent=2))
        except Exception:
            pass

def _register_model(name):
    d = _load()
    if name not in d["models"]:
        d["models"][name] = {"elo": 1500.0, "wins": 0, "losses": 0,
                             "ties": 0, "games": 0}
        _save()
    return d["models"][name]

def _elo_update(winner_elo, loser_elo, k=32):
    exp_w = 1.0 / (1 + 10 ** ((loser_elo - winner_elo) / 400))
    return winner_elo + k * (1 - exp_w), loser_elo + k * (0 - (1 - exp_w))

def register(app, **ctx):
    ok, fail, auth = ctx["helpers"]["ok"], ctx["helpers"]["fail"], ctx["helpers"]["auth"]
    from flask import request
    home = Path(os.environ.get("LUNA_HOME", Path.home() / ".termux" / "tasker"))
    d = home / "data" / "arena"
    d.mkdir(parents=True, exist_ok=True)
    _STATE["fp"] = d / "arena.json"
    _STATE["providers"] = {
        "gemini": "gemini-2.0-flash",
        "openai": "gpt-4o-mini",
        "anthropic": "claude-3-5-sonnet-latest",
    }
    for name in _STATE["providers"]:
        _register_model(name)

    def _call_provider(name, prompt):
        try:
            from ai import _call as _ai_call  # reuse ai.py
        except Exception:
            return f"[sin módulo ai: {name}]"
        try:
            return _ai_call(name, prompt, "Eres conciso. Responde en <=200 palabras.")[:800]
        except Exception as e:
            return f"[error {name}: {e}]"

    @app.post("/api/arena/pair")
    @auth("full")
    def _pair():
        b = request.get_json(silent=True) or {}
        prompt = (b.get("prompt") or "").strip()
        if not prompt:
            return fail("falta 'prompt'")
        models = list(_STATE["providers"].keys())
        if len(models) < 2:
            return fail("se necesitan >=2 modelos", 400)
        a, b_model = random.sample(models, 2)
        ta = _call_provider(a, prompt)
        tb = _call_provider(b_model, prompt)
        pid = "p_" + secrets.token_hex(4)
        with _LK:
            _STATE["data"]["pairs"][pid] = {
                "prompt": prompt, "a": a, "b": b_model,
                "ts": time.time(),
            }
            # cap history
            if len(_STATE["data"]["pairs"]) > 200:
                for old in sorted(_STATE["data"]["pairs"],
                                   key=lambda k: _STATE["data"]["pairs"][k]["ts"])[:50]:
                    _STATE["data"]["pairs"].pop(old, None)
        _save()
        return ok(pair={"id": pid, "prompt": prompt,
                        "a": {"model": a, "text": ta},
                        "b": {"model": b_model, "text": tb}})

    @app.post("/api/arena/vote")
    @auth("full")
    def _vote():
        b = request.get_json(silent=True) or {}
        pid = b.get("id", "")
        choice = b.get("choice", "")
        with _LK:
            pair = _STATE["data"]["pairs"].get(pid)
            if not pair:
                return fail("par no encontrado", 404)
            if choice not in ("a", "b", "tie"):
                return fail("choice debe ser a/b/tie")
            a, b_model = pair["a"], pair["b"]
            ma, mb = _STATE["data"]["models"][a], _STATE["data"]["models"][b_model]
            if choice == "a":
                ma["wins"] += 1; mb["losses"] += 1
                ma["elo"], mb["elo"] = _elo_update(ma["elo"], mb["elo"])
            elif choice == "b":
                mb["wins"] += 1; ma["losses"] += 1
                mb["elo"], ma["elo"] = _elo_update(mb["elo"], ma["elo"])
            else:
                ma["ties"] += 1; mb["ties"] += 1
            ma["games"] += 1; mb["games"] += 1
            _STATE["data"]["votes"] += 1
            _STATE["data"]["pairs"].pop(pid, None)
        _save()
        return ok(voted=choice, a=a, b=b_model)

    @app.get("/api/arena/leaderboard")
    @auth("ro")
    def _board():
        with _LK:
            models = [{"model": k, **v} for k, v in _STATE["data"]["models"].items()]
        models.sort(key=lambda m: m["elo"], reverse=True)
        return ok(leaderboard=models, total_votes=_STATE["data"]["votes"])

    @app.post("/api/arena/models")
    @auth("full")
    def _add():
        name = (request.get_json(silent=True) or {}).get("name", "").strip()
        if not name:
            return fail("falta 'name'")
        _register_model(name)
        return ok(models=list(_STATE["data"]["models"].keys()))

    @app.get("/api/arena/models")
    @auth("ro")
    def _models():
        return ok(models=list(_STATE["data"]["models"].keys()),
                  providers=list(_STATE["providers"].keys()))
PYEOF

OK "Plugins: apps, root, licenses, tools, ai, tasks, arena"

# ============================================================
# 7. CLI
# ============================================================
LOG "Instalando CLI 'luna'…"
cat > "$CLI" <<'SHEOF'
#!/usr/bin/env bash
set -euo pipefail
HOME_DIR="$HOME/.termux/tasker"
PY="$HOME_DIR/luna_core.py"
SUP="$HOME_DIR/supervisor.sh"
LOG="$HOME_DIR/luna.log"
PID="$HOME_DIR/luna.pid"
CFG="$HOME_DIR/config.json"
PORT="$(python -c "import json;print(json.load(open('$CFG'))['port'])" 2>/dev/null || echo 7070)"
BASE="http://127.0.0.1:$PORT"
TOKEN="${LUNA_TOKEN:-$(python -c "import json;t=json.load(open('$CFG'))['tokens']['full'];print(t[0] if t else '')" 2>/dev/null || echo "")}"
H=(); [ -n "$TOKEN" ] && H=(-H "X-Luna-Token: $TOKEN")
alive(){ [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; }

case "${1:-help}" in
  start)
    if alive; then echo "L.U.N.A. ya corriendo (PID $(cat "$PID"))"; exit 0; fi
    nohup bash "$SUP" >/dev/null 2>&1 & echo $! > "$PID"; sleep 1.5
    if alive; then echo "L.U.N.A. iniciada (PID $(cat "$PID"))"; echo "HUD: $BASE"
    else echo "Fallo al iniciar. Log: $LOG"; exit 1; fi ;;
  stop)
    if alive; then pid=$(cat "$PID"); kill "$pid" 2>/dev/null || true
      pkill -P "$pid" python 2>/dev/null || true; pkill -f "$PY" 2>/dev/null || true
      rm -f "$PID"; echo "Detenida."
    else echo "No está corriendo."; fi ;;
  restart) "$0" stop || true; sleep 1; "$0" start ;;
  status) if alive; then echo "Activa (PID $(cat "$PID")) en :$PORT"; else echo "Detenida."; fi ;;
  logs) exec tail -f "$LOG" ;;
  health) curl -fsS "${H[@]}" "$BASE/api/health" | jq . 2>/dev/null || curl -fsS "${H[@]}" "$BASE/api/health" ;;
  url) echo "$BASE" ;;
  doctor) curl -fsS "${H[@]}" "$BASE/api/doctor" | jq . ;;
  test) bash "$HOME_DIR/tests/smoke.sh" ;;
  apps)
    if [ "${2:-}" = "search" ]; then
      shift 2
      python -c 'import sys,urllib.parse;print(urllib.parse.quote(" ".join(sys.argv[1:])))' "$@" | {
        IFS= read -r q
        curl -fsS "${H[@]}" "$BASE/api/apps/search?q=$q" | jq .
      }
    else
      curl -fsS "${H[@]}" "$BASE/api/apps" | jq -r '.packages[]'
    fi ;;
  licenses) curl -fsS "${H[@]}" "$BASE/api/licenses" | jq '.count, .licenses[0:5]' ;;
  tools) curl -fsS "${H[@]}" "$BASE/api/tools" | jq -r '.tools[] | "\(if .installed then "✔" else "✘" end) \(.name) — \(.desc)"' ;;
  ai)
    shift
    PROMPT="${*:-}"
    [ -z "$PROMPT" ] && { echo "uso: luna ai <prompt>"; exit 1; }
    PAYLOAD=$(python -c 'import json,sys;print(json.dumps({"prompt":" ".join(sys.argv[1:])}))' "$@")
    curl -fsS "${H[@]}" -H "Content-Type: application/json" -d "$PAYLOAD" "$BASE/api/ai" | jq -r '.text // .error' ;;
  job)
    follow=1; timeout=3600
    while [ $# -gt 0 ]; do
      case "$1" in
        --no-follow|--detach) follow=0; shift ;;
        --timeout) timeout="$2"; shift 2 ;;
        --) shift; break ;;
        -*) echo "flag desconocido: $1"; exit 1 ;;
        *) break ;;
      esac
    done
    [ $# -ge 1 ] || { echo "uso: luna job [flags] <cmd> [args...]"; exit 1; }
    cmd="$1"; shift
    payload=$(python -c 'import json,sys;print(json.dumps({"cmd":sys.argv[1],"args":sys.argv[3:],"timeout":int(sys.argv[2]),"notify":True}))' "$cmd" "$timeout" "$@")
    resp=$(curl -fsS "${H[@]}" -H "Content-Type: application/json" -d "$payload" "$BASE/api/tasks")
    tid=$(echo "$resp" | python -c 'import sys,json;print(json.load(sys.stdin)["task_id"])')
    echo "→ task_id: $tid"
    [ "$follow" = "1" ] || { echo "background. Sigue: luna job-follow $tid"; exit 0; }
    exec "$0" job-follow "$tid" ;;
  jobs) curl -fsS "${H[@]}" "$BASE/api/tasks" | python -c '
import sys,json
d=json.load(sys.stdin)
if not d.get("tasks"): print("(sin tareas)"); sys.exit(0)
print("{:<16} {:<12} {:<4} {:<8} comando".format("id", "status", "rc", "dur"))
for t in d["tasks"]:
    cmd=" ".join([t["cmd"]]+t["args"])[:60]
    rc=str(t["exit_code"] if t["exit_code"] is not None else "-")
    print("{:<16} {:<12} {:<4} {:<8.0f} {}".format(t["id"], t["status"], rc, t["duration_s"], cmd))' ;;
  job-follow) curl -N -sS "${H[@]}" "$BASE/api/tasks/${2:?id requerido}/stream" | python -u -c '
import sys,json
for line in sys.stdin:
    if not line.startswith("data:"): continue
    try: d=json.loads(line[5:].strip())
    except Exception: continue
    if d.get("end"): print("\n[FIN] {} rc={}".format(d.get("status"), d.get("exit_code"))); break
    print(d.get("text",""), flush=True)' ;;
  job-kill) curl -fsS -X POST "${H[@]}" "$BASE/api/tasks/${2:?id requerido}/kill" | jq . ;;
  root) shift; case "${1:-status}" in
      status) curl -fsS "${H[@]}" "$BASE/api/root/status" | jq . ;;
      exec) shift
        payload=$(python -c 'import json,sys;print(json.dumps({"cmd":" ".join(sys.argv[1:])}))' "$@")
        curl -fsS -X POST "${H[@]}" -H "Content-Type: application/json" -d "$payload" "$BASE/api/root/exec" | jq . ;;
      *) echo "uso: luna root {status|exec <cmd>}" ;; esac ;;
  token) case "${2:-}" in
      generate) role="${3:-full}"
        case "$role" in full|ro) ;; *) echo "rol inválido: usa full o ro" >&2; exit 2 ;; esac
        tok=$(python -c "import secrets;print(secrets.token_urlsafe(32))")
        python - "$role" "$tok" <<'PP'
import json,sys,pathlib
role,tok=sys.argv[1:3]; p=pathlib.Path.home()/'.termux'/'tasker'/'config.json'
c=json.loads(p.read_text()); c.setdefault('tokens',{}).setdefault(role,[]).append(tok)
p.write_text(json.dumps(c,indent=2)); print(tok)
PP
        echo "(guardado en config.json, rol '$role')" >&2 ;;
      list) python -c "import json,pathlib;c=json.loads((pathlib.Path.home()/'.termux'/'tasker'/'config.json').read_text());print(json.dumps(c['tokens'],indent=2))" ;;
      *) echo "uso: luna token {generate [full|ro] | list}" ;; esac ;;
  *) cat <<EOF
Uso: luna <comando>
  start|stop|restart|status|logs|health|url|doctor|test
  apps [search <q>]        lista apps
  licenses                 catálogo SPDX (~600)
  tools                    herramientas disponibles
  ai <prompt>              consulta IA multi-proveedor
  job [flags] <cmd>        tarea larga en background
  jobs                     lista tareas
  job-follow <id>          sigue salida en vivo
  job-kill <id>            mata tarea
  root status|exec <cmd>   root (si hay su)
  token generate [full|ro] genera token
  token list               lista tokens
EOF
    ;;
esac
SHEOF
chmod +x "$CLI"
OK "CLI instalada: $CLI"

# ============================================================
# 8. SUPERVISOR
# ============================================================
cat > "$LUNA_HOME/supervisor.sh" <<'SHEOF'
#!/usr/bin/env bash
set -uo pipefail
CORE="$HOME/.termux/tasker/luna_core.py"
LOG="$HOME/.termux/tasker/luna.log"
mkdir -p "$(dirname "$LOG")"
echo "[$(date -Iseconds)] supervisor iniciado" >> "$LOG"
while true; do
  python "$CORE" >> "$LOG" 2>&1
  rc=$?
  echo "[$(date -Iseconds)] salida rc=$rc, reinicio en 2s" >> "$LOG"
  sleep 2
done
SHEOF
chmod +x "$LUNA_HOME/supervisor.sh"

# ============================================================
# 9. SMOKE TESTS
# ============================================================
mkdir -p "$LUNA_HOME/tests"
cat > "$LUNA_HOME/tests/smoke.sh" <<'SHEOF'
#!/usr/bin/env bash
set -uo pipefail
PORT="$(python -c "import json;print(json.load(open('$HOME/.termux/tasker/config.json'))['port'])" 2>/dev/null || echo 7070)"
BASE="http://127.0.0.1:$PORT"
TOKEN="${LUNA_TOKEN:-$(python -c "import json;t=json.load(open('$HOME/.termux/tasker/config.json'))['tokens']['full'];print(t[0] if t else '')" 2>/dev/null || echo "")}"
H=(); [ -n "$TOKEN" ] && H=(-H "X-Luna-Token: $TOKEN")
FAIL=0
chk(){ local n="$1" u="$2"; if curl -fsS "${H[@]}" "$u" >/dev/null; then echo "  ✔ $n"; else echo "  ✘ $n"; FAIL=1; fi; }
echo "[smoke] $BASE"
chk "health"    "$BASE/api/health"
chk "telemetry" "$BASE/api/telemetry"
chk "doctor"    "$BASE/api/doctor"
chk "apps"      "$BASE/api/apps"
chk "licenses"  "$BASE/api/licenses"
chk "tools"     "$BASE/api/tools"
chk "providers" "$BASE/api/ai/providers"
chk "arena"     "$BASE/api/arena/leaderboard"
exit $FAIL
SHEOF
chmod +x "$LUNA_HOME/tests/smoke.sh"

# ============================================================
# 10. RESUMEN
# ============================================================
cat <<EOF

$(printf '%s' "$C_GRN")✔  L.U.N.A. v5.0 instalada.$(printf '%s' "$C_RST")

  Config     : $CFG
  Servidor   : $CORE
  HUD        : $STATIC/hud.html
  Plugins    : $PLUGINS/
  CLI        : $CLI
  Tests      : $LUNA_HOME/tests/smoke.sh

  Arrancar   : luna start
  Verificar  : luna test
  HUD        : luna url   →  http://127.0.0.1:7070

  Mejoras v5.0 (respecto a setup_luna.sh):
    ✔ Python válido (true→True, gen() sin "ro", X-Accel-Buffering: no)
    ✔ config.json válido y token inicial generado si faltaba
    ✔ HUD completo con 8 pestañas + Arena ELO + tabla leaderboard
    ✔ tasks.py con SSE sin fugas de suscriptores
    ✔ arena.py nuevo (comparativa ELO multi-modelo)
    ✔ licenses.py con índice legal (copyleft, commercial, etc.)
    ✔ ai.py multi-proveedor con auto-selección
    ✔ Gemini 2.0 Flash como default (según gemini.py original)

  Atajos:
    luna apps                 → lista apps instaladas
    luna ai "explica quantum" → consulta IA
    luna job ffmpeg ...       → tarea larga en background
    luna root status          → ¿hay root?
    luna token generate full  → token de escritura

  Variables de entorno (opcional):
    GEMINI_API_KEY     → activa Gemini
    OPENAI_API_KEY     → activa OpenAI
    ANTHROPIC_API_KEY  → activa Claude

  Recuerda:
    • Instala "Termux:API" desde F-Droid para telemetría y notificaciones.
    • Para root: dispositivo rooteado (Magisk/KernelSU).
    • La Arena requiere al menos 1 proveedor de IA configurado.

EOF
