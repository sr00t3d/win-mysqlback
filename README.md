# win-mysqlback — Cross-Platform MySQL/MariaDB Backup CLI (`v2.0.0`)

![win-mysqlback cover](win-mysqlback-cover.webp)

A modern, cross-platform **Bash + Python 3** (`win-mysqlback.sh`) and native **Windows PowerShell 5.1+/7+** (`win-mysqlback.ps1`) CLI for securely backing up MySQL/MariaDB databases with compression, SHA-256 verification, retention pruning, and `table` / `json` / `csv` outputs.

## Historical Modernization

Inspired by **`win_mysqlback.bat`** (**HostGator Brasil**, authored by **Percio Andrade — `percio.andrade@hostgator.com.br`**), originally written as a Windows batch script for Plesk servers.

In `v2.0.0`, the batch script was modernized into dual native **Bash + Python 3** and **PowerShell** CLIs to fix critical security and automation issues:
- **Removed Hardcoded Credentials**: Eliminated the plaintext `set dbpass=...` and `--password=` CLI flag (which exposed passwords in process lists) in favor of `chmod 600` `--defaults-extra-file` configs, `MYSQL_USER`/`MYSQL_PASSWORD` env vars, or secure interactive prompts.
- **Closed Public Webroot Exposure**: Replaced `C:\inetpub\vhosts\default\htdocs\mysql\` (which exposed SQL dumps over HTTP on the server IP) with private backup directories (`chmod 700` / `600` on Linux, `%ProgramData%\mysqlback\backups` on Windows).
- **Non-Interactive & Compressed**: Replaced `choice`/`pause` prompts with `--databases`, `--exclude`, `--dry-run`, `--retain-days`, `.sql.gz`/`.sql.zip` compression, and SHA-256 checksums.

## Windows PowerShell

```powershell
pwsh -NoProfile -File .\win-mysqlback.ps1 -Databases app_db -DryRun -Output json
```

Validated end-to-end on `mcr.microsoft.com/powershell:alpine-3.20` (PowerShell 7+) and compatible with Windows PowerShell 5.1+.

## Real Output Example

```text
$ ./win-mysqlback.sh -d app_prod,analytics --exclude analytics --dry-run --no-color
=== win-mysqlback.sh v2.0.0 | MySQL/MariaDB Backup Report ===
DATABASE                 STATUS     SIZE_BYTES   FILE
----------------------------------------------------------------------------------
app_prod                 DRY_RUN    0            /var/backups/mysqlback/app_prod.sql.gz
```

## License

Apache-2.0 — see [LICENSE](LICENSE).
