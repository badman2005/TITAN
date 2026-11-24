#!/usr/bin/env bash
# =====================================================================
# Project TITAN — one-shot setup:  ./setup.sh
#   1. installs MariaDB (if missing) and starts it
#   2. creates titan_db + tables + triggers + app user from schema.sql
#   3. creates a Python venv and installs requirements
#   4. writes .env, seeds demo data, runs the test suite
#   5. starts the API at http://127.0.0.1:8000/docs
#
# Options:
#   --sqlite        skip MariaDB entirely; use a local SQLite file (dev only: no triggers/grants)
#   --reset         DROP and recreate titan_db (destroys all data), then reseed
#   --no-install    don't try to install MariaDB (use what's already there)
#   --skip-tests    don't run pytest
#   --no-run        set everything up but don't start the server
# Env overrides:  TITAN_DB_PASSWORD (default titan_pass)  MYSQL_ROOT_PASSWORD  PORT (default 8000)
# =====================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

USE_SQLITE=0; RESET=0; INSTALL=1; TESTS=1; RUN=1
for a in "$@"; do
  case "$a" in
    --sqlite) USE_SQLITE=1 ;; --reset) RESET=1 ;; --no-install) INSTALL=0 ;;
    --skip-tests) TESTS=0 ;; --no-run) RUN=0 ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $a (try --help)"; exit 2 ;;
  esac
done

DB_PASS="${TITAN_DB_PASSWORD:-titan_pass}"
PORT="${PORT:-8000}"
c_ok=$'\e[32m'; c_warn=$'\e[33m'; c_err=$'\e[31m'; c_off=$'\e[0m'
step() { echo; echo "${c_ok}==>${c_off} $*"; }
warn() { echo "${c_warn}!!${c_off}  $*"; }
die()  { echo "${c_err}xx${c_off}  $*" >&2; exit 1; }

SUDO=""
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  command -v sudo >/dev/null 2>&1 && SUDO="sudo"
fi
OS="$(uname -s)"

# ---------------------------------------------------------------- MariaDB
mariadb_cli() { command -v mariadb 2>/dev/null || command -v mysql 2>/dev/null || true; }

install_mariadb() {
  [ "$INSTALL" -eq 1 ] || die "MariaDB client/server not found and --no-install was given"
  step "Installing MariaDB server"
  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -q && DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -q mariadb-server
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y mariadb-server
  elif command -v yum >/dev/null 2>&1; then
    $SUDO yum install -y mariadb-server
  elif command -v pacman >/dev/null 2>&1; then
    $SUDO pacman -Sy --noconfirm mariadb
    [ -d /var/lib/mysql/mysql ] || $SUDO mariadb-install-db --user=mysql --basedir=/usr --datadir=/var/lib/mysql
  elif command -v brew >/dev/null 2>&1; then
    brew install mariadb
  else
    die "Unsupported OS: install MariaDB 10.5+ yourself, then re-run with --no-install"
  fi
}

server_up() { "$CLI" -uroot ${MYSQL_ROOT_PASSWORD:+-p"$MYSQL_ROOT_PASSWORD"} -e 'select 1' >/dev/null 2>&1 \
              || { [ -n "$SUDO" ] && $SUDO "$CLI" -e 'select 1' >/dev/null 2>&1; } \
              || { [ "$(id -u)" -eq 0 ] && "$CLI" -e 'select 1' >/dev/null 2>&1; }; }

start_mariadb() {
  server_up && return 0
  step "Starting MariaDB"
  if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    $SUDO systemctl start mariadb 2>/dev/null || $SUDO systemctl start mysql 2>/dev/null || true
  elif [ "$OS" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
    brew services start mariadb || true
  else
    $SUDO service mariadb start 2>/dev/null || $SUDO service mysql start 2>/dev/null || true
  fi
  if ! server_up && command -v mysqld_safe >/dev/null 2>&1; then   # containers / WSL without init
    $SUDO mkdir -p /run/mysqld && $SUDO chown mysql:mysql /run/mysqld 2>/dev/null || true
    $SUDO sh -c 'setsid nohup mysqld_safe --bind-address=127.0.0.1 >/tmp/titan-mysqld.log 2>&1 </dev/null &'
  fi
  for _ in $(seq 1 40); do server_up && return 0; sleep 1; done
  die "MariaDB did not come up. See /tmp/titan-mysqld.log or 'journalctl -u mariadb'."
}

# Run SQL from stdin as the MariaDB admin, however this machine lets us authenticate.
root_sql() {
  if "$CLI" -uroot ${MYSQL_ROOT_PASSWORD:+-p"$MYSQL_ROOT_PASSWORD"} "$@" 2>/dev/null; then return 0; fi
  if [ -n "$SUDO" ]; then $SUDO "$CLI" "$@"; else "$CLI" "$@"; fi
}
detect_root_access() {
  if "$CLI" -uroot ${MYSQL_ROOT_PASSWORD:+-p"$MYSQL_ROOT_PASSWORD"} -e 'select 1' >/dev/null 2>&1; then ROOT_MODE=direct
  elif [ -n "$SUDO" ] && $SUDO "$CLI" -e 'select 1' >/dev/null 2>&1; then ROOT_MODE=sudo
  elif "$CLI" -e 'select 1' >/dev/null 2>&1; then ROOT_MODE=socket
  else die "Can't log in to MariaDB as admin. Re-run with MYSQL_ROOT_PASSWORD=... ./setup.sh"; fi
}
admin() {   # admin [mysql args] < sql
  case "$ROOT_MODE" in
    direct) "$CLI" -uroot ${MYSQL_ROOT_PASSWORD:+-p"$MYSQL_ROOT_PASSWORD"} "$@" ;;
    sudo)   $SUDO "$CLI" "$@" ;;
    *)      "$CLI" "$@" ;;
  esac
}

if [ "$USE_SQLITE" -eq 1 ]; then
  step "SQLite mode (no MariaDB): triggers/grants are NOT created — dev only"
  DATABASE_URL="sqlite:///./titan.db"; AUTO_CREATE=1
  [ "$RESET" -eq 1 ] && rm -f titan.db
else
  CLI="$(mariadb_cli)"
  if [ -z "$CLI" ] || { ! command -v mysqld >/dev/null 2>&1 && ! command -v mariadbd >/dev/null 2>&1 \
       && [ ! -x /usr/sbin/mariadbd ] && ! command -v brew >/dev/null 2>&1; }; then
    install_mariadb; CLI="$(mariadb_cli)"
  fi
  [ -n "$CLI" ] || die "mariadb/mysql client still not found after install"
  start_mariadb
  detect_root_access

  step "Creating database, tables, triggers and app user"
  [ "$RESET" -eq 1 ] && { warn "--reset: dropping titan_db"; echo "DROP DATABASE IF EXISTS titan_db;" | admin; }
  # Passwords are escaped by Python so any characters are safe in SQL and in the URL.
  python3 - "$DB_PASS" <<'PY' | admin
import sys
pw = sys.argv[1].replace("\\", "\\\\").replace("'", "''")
sql = open("schema.sql").read().replace("'titan_pass'", "'" + pw + "'")
print(sql)
# CREATE USER IF NOT EXISTS doesn't update the password on re-runs, so sync it explicitly
print("ALTER USER 'titan'@'%' IDENTIFIED BY '" + pw + "'; FLUSH PRIVILEGES;")
PY
  PW_URL="$(python3 -c 'import sys,urllib.parse as u; print(u.quote(sys.argv[1], safe=""))' "$DB_PASS")"
  DATABASE_URL="mysql+pymysql://titan:${PW_URL}@127.0.0.1:3306/titan_db?charset=utf8mb4"; AUTO_CREATE=0
fi

# ---------------------------------------------------------------- Python
step "Setting up Python environment"
PY="$(command -v python3 || command -v python || true)"
[ -n "$PY" ] || die "Python 3.10+ is required"
"$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' || die "Python 3.10+ is required (found $("$PY" -V))"
if [ ! -d .venv ]; then
  "$PY" -m venv .venv 2>/dev/null || {
    command -v apt-get >/dev/null 2>&1 && [ "$INSTALL" -eq 1 ] \
      && { rm -rf .venv; $SUDO apt-get install -y -q python3-venv && "$PY" -m venv .venv; } \
      || die "Could not create a venv (install python3-venv)"; }
fi
# shellcheck disable=SC1091
source .venv/bin/activate
python -m pip install -q --upgrade pip
pip install -q -r requirements.txt

# ---------------------------------------------------------------- .env
step "Writing .env"
[ -f .env ] && { cp .env ".env.bak"; warn "existing .env backed up to .env.bak"; }
sed -e "s|^DATABASE_URL=.*|DATABASE_URL=${DATABASE_URL}|" \
    -e "s|^TITAN_AUTO_CREATE=[01]|TITAN_AUTO_CREATE=${AUTO_CREATE}|" .env.example > .env
chmod 600 .env
set -a; source .env; set +a

# ---------------------------------------------------------------- tests + seed
if [ "$TESTS" -eq 1 ]; then
  step "Running tests (isolated in-memory SQLite)"
  python -m pytest -q -p no:cacheprovider
fi
step "Seeding demo data"
python seed.py

echo
echo "${c_ok}Setup complete.${c_off}"
echo "  API docs : http://127.0.0.1:${PORT}/docs"
echo "  Restart  : ./run.sh        Re-seed from scratch: ./setup.sh --reset"
echo "  Try      : curl -s 'http://127.0.0.1:${PORT}/api/crates/1/verify'"
if [ "$RUN" -eq 1 ]; then
  step "Starting API (Ctrl+C to stop)"
  exec uvicorn app.main:app --host 127.0.0.1 --port "$PORT" --reload
fi
