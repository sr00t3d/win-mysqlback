#!/usr/bin/env bash
# ==============================================================================
# win-mysqlback.sh — Cross-Platform MySQL/MariaDB Backup CLI (v2.0.0)
# Modernized clean-room implementation inspired by win_mysqlback.bat (Percio Andrade).
# Copyright (c) 2026 Percio Castelo — Apache-2.0 License
# ==============================================================================
set -euo pipefail

VERSION="2.0.0"

if ! command -v python3 >/dev/null 2>&1; then
    echo "Error: python3 is required (3.6+)." >&2
    exit 1
fi

read -r -d '' PY_SCRIPT << 'EOF' || true
import argparse
import csv
import datetime
import getpass
import gzip
import hashlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile

VERSION = "2.0.0"
SYSTEM_DBS = {"information_schema", "performance_schema", "mysql", "sys"}


class Colors:
    def __init__(self, enabled=True):
        self.RESET = "\033[0m" if enabled else ""
        self.BOLD = "\033[1m" if enabled else ""
        self.CYAN = "\033[36m" if enabled else ""
        self.GREEN = "\033[32m" if enabled else ""
        self.YELLOW = "\033[33m" if enabled else ""
        self.RED = "\033[31m" if enabled else ""


def build_cnf(user, password, host, port):
    esc_pw = (password or "").replace("\\", "\\\\").replace('"', '\\"')
    fd, cnf_path = tempfile.mkstemp(prefix="mysqlback_", suffix=".cnf")
    os.chmod(cnf_path, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(f'[client]\nuser="{user}"\npassword="{esc_pw}"\nhost="{host}"\nport={port}\n')
    return cnf_path


def discover_databases(mysql_bin, cnf_path, include_list, exclude_set):
    if include_list:
        return [d for d in include_list if d not in exclude_set]
    res = subprocess.run(
        [mysql_bin, f"--defaults-extra-file={cnf_path}", "--batch", "--skip-column-names", "-e", "SHOW DATABASES;"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=15,
    )
    if res.returncode != 0:
        raise RuntimeError(res.stderr.strip() or f"mysql exited with {res.returncode}")
    dbs = []
    for line in res.stdout.splitlines():
        db = line.strip()
        if db and db not in SYSTEM_DBS and db not in exclude_set:
            dbs.append(db)
    return dbs


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def prune_old_backups(backup_dir, retain_days):
    if retain_days <= 0 or not os.path.isdir(backup_dir):
        return 0
    cutoff = datetime.datetime.now().timestamp() - (retain_days * 86400)
    removed = 0
    for fn in os.listdir(backup_dir):
        if fn.endswith((".sql", ".sql.gz", ".sha256")):
            fp = os.path.join(backup_dir, fn)
            if os.path.isfile(fp) and os.path.getmtime(fp) < cutoff:
                os.unlink(fp)
                removed += 1
    return removed


def render_output(rows, fmt, c):
    if fmt == "json":
        print(json.dumps(rows, indent=2))
        return
    if fmt == "csv":
        buf = io.StringIO()
        w = csv.DictWriter(buf, fieldnames=["database", "status", "file", "size_bytes", "sha256", "error"])
        w.writeheader()
        for r in rows:
            w.writerow(r)
        sys.stdout.write(buf.getvalue())
        return
    print(f"{c.BOLD}{c.CYAN}=== win-mysqlback.sh v{VERSION} | MySQL/MariaDB Backup Report ==={c.RESET}")
    if not rows:
        print("  (no databases processed)")
        return
    print(f"{c.BOLD}{'DATABASE':<24} {'STATUS':<10} {'SIZE_BYTES':<12} FILE{c.RESET}")
    print("-" * 82)
    for r in rows:
        st = r["status"]
        col = c.GREEN if st == "OK" else (c.YELLOW if st == "DRY_RUN" else c.RED)
        print(f"{r['database']:<24} {col}{st:<10}{c.RESET} {r['size_bytes']:<12} {r['file'] or r['error']}")


def main():
    parser = argparse.ArgumentParser(
        prog="win-mysqlback.sh",
        description="Cross-Platform MySQL/MariaDB Backup CLI (v2.0.0)",
    )
    parser.add_argument("-u", "--user", default=os.environ.get("MYSQL_USER", "root"), help="MySQL username (or MYSQL_USER)")
    parser.add_argument("-p", "--prompt-password", action="store_true", help="Prompt securely for MySQL password")
    parser.add_argument("-H", "--host", default="127.0.0.1", help="MySQL host (default: 127.0.0.1)")
    parser.add_argument("-P", "--port", type=int, default=3306, help="MySQL port (default: 3306)")
    parser.add_argument("-d", "--databases", help="Comma-separated database names (default: all non-system DBs)")
    parser.add_argument("--exclude", default="", help="Comma-separated database names to exclude")
    parser.add_argument("-b", "--backup-dir", default="/var/backups/mysqlback", help="Private backup directory")
    parser.add_argument("--no-compress", action="store_true", help="Write plain .sql instead of .sql.gz")
    parser.add_argument("--retain-days", type=int, default=0, help="Delete backups older than N days (0=keep all)")
    parser.add_argument("--dry-run", action="store_true", help="Preview databases without dumping")
    parser.add_argument("-o", "--output", choices=["table", "json", "csv"], default="table")
    parser.add_argument("--no-color", action="store_true")
    parser.add_argument("-v", "--version", action="version", version=f"win-mysqlback.sh {VERSION}")
    args = parser.parse_args()

    password = os.environ.get("MYSQL_PASSWORD", "")
    if args.prompt_password:
        password = getpass.getpass(f"MySQL password for {args.user}@{args.host}: ")

    include_list = [x.strip() for x in (args.databases or "").split(",") if x.strip()]
    exclude_set = set(x.strip() for x in (args.exclude or "").split(",") if x.strip())

    if args.dry_run and include_list:
        rows = [
            {"database": db, "status": "DRY_RUN", "file": os.path.join(args.backup_dir, f"{db}.sql" + ("" if args.no_compress else ".gz")), "size_bytes": 0, "sha256": "-", "error": ""}
            for db in include_list if db not in exclude_set
        ]
        render_output(rows, args.output, Colors(enabled=sys.stdout.isatty() and not args.no_color))
        return

    mysql_bin = shutil.which("mysql") or shutil.which("mariadb")
    dump_bin = shutil.which("mysqldump") or shutil.which("mariadb-dump")
    if not mysql_bin or not dump_bin:
        sys.stderr.write("Error: mysql and mysqldump (or mariadb/mariadb-dump) are required.\n")
        sys.exit(1)

    cnf_path = build_cnf(args.user, password, args.host, args.port)
    rows = []
    try:
        dbs = discover_databases(mysql_bin, cnf_path, include_list, exclude_set)
        if args.dry_run:
            rows = [
                {"database": db, "status": "DRY_RUN", "file": os.path.join(args.backup_dir, f"{db}.sql" + ("" if args.no_compress else ".gz")), "size_bytes": 0, "sha256": "-", "error": ""}
                for db in dbs
            ]
        else:
            os.makedirs(args.backup_dir, exist_ok=True)
            os.chmod(args.backup_dir, 0o700)
            ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
            for db in dbs:
                ext = ".sql" if args.no_compress else ".sql.gz"
                out_file = os.path.join(args.backup_dir, f"{db}-{ts}{ext}")
                cmd = [
                    dump_bin,
                    f"--defaults-extra-file={cnf_path}",
                    "--single-transaction",
                    "--routines",
                    "--triggers",
                    "--databases",
                    db,
                ]
                res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
                if res.returncode != 0:
                    rows.append({
                        "database": db,
                        "status": "ERROR",
                        "file": "",
                        "size_bytes": 0,
                        "sha256": "",
                        "error": res.stderr.decode("utf-8", errors="replace").strip(),
                    })
                    continue
                if args.no_compress:
                    with open(out_file, "wb") as fh:
                        fh.write(res.stdout)
                else:
                    with gzip.open(out_file, "wb") as gz:
                        gz.write(res.stdout)
                os.chmod(out_file, 0o600)
                digest = sha256_file(out_file)
                rows.append({
                    "database": db,
                    "status": "OK",
                    "file": out_file,
                    "size_bytes": os.path.getsize(out_file),
                    "sha256": digest,
                    "error": "",
                })
            prune_old_backups(args.backup_dir, args.retain_days)
    except Exception as exc:
        sys.stderr.write(f"Error: {exc}\n")
        sys.exit(1)
    finally:
        try:
            os.unlink(cnf_path)
        except OSError:
            pass

    render_output(rows, args.output, Colors(enabled=sys.stdout.isatty() and not args.no_color))
    if any(r["status"] == "ERROR" for r in rows):
        sys.exit(1)


if __name__ == "__main__":
    main()
EOF

python3 -c "$PY_SCRIPT" "$@"
