<#
.SYNOPSIS
    win-mysqlback.ps1 — Cross-Platform MySQL/MariaDB Backup CLI (v2.0.0)
.DESCRIPTION
    Modernized clean-room PowerShell 5.1+/7+ implementation inspired by legacy win_mysqlback.bat (Percio Andrade).
    Eliminates hardcoded passwords, public IIS webroot dumps, and CLI --password exposure.
    Copyright (c) 2026 Percio Castelo — Apache-2.0 License
#>
[CmdletBinding()]
param(
    [string]$User = $(if ($env:MYSQL_USER) { $env:MYSQL_USER } else { "root" }),
    [switch]$PromptPassword,
    [string]$MysqlHost = "127.0.0.1",
    [int]$Port = 3306,
    [string[]]$Databases = @(),
    [string[]]$Exclude = @(),
    [string]$BackupDir = $(if ($env:ProgramData) { Join-Path $env:ProgramData "mysqlback\backups" } else { "/var/backups/mysqlback" }),
    [switch]$NoCompress,
    [int]$RetainDays = 0,
    [switch]$DryRun,
    [ValidateSet("table", "json", "csv")]
    [string]$Output = "table",
    [switch]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ScriptVersion = "2.0.0"

if ($Version) {
    Write-Output "win-mysqlback.ps1 $ScriptVersion"
    exit 0
}

function Find-MysqlTool {
    param([string[]]$Names, [string[]]$ExtraDirs)
    foreach ($n in $Names) {
        $cmd = Get-Command $n -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    foreach ($dir in $ExtraDirs) {
        if ($dir -and (Test-Path $dir)) {
            foreach ($n in $Names) {
                $cand = Join-Path $dir $n
                if (Test-Path $cand) { return $cand }
            }
        }
    }
    return $null
}

function Write-Report {
    param($Rows, [string]$Format)
    if ($Format -eq "json") {
        $Rows | ConvertTo-Json -Depth 4
        return
    }
    if ($Format -eq "csv") {
        $Rows | ConvertTo-Csv -NoTypeInformation
        return
    }
    Write-Output "=== win-mysqlback.ps1 v$ScriptVersion | MySQL/MariaDB Backup Report ==="
    if (-not $Rows -or $Rows.Count -eq 0) {
        Write-Output "  (no databases processed)"
        return
    }
    $Rows | Format-Table -Property database, status, size_bytes, file -AutoSize | Out-String | Write-Output
}

$SystemDbs = @("information_schema", "performance_schema", "mysql", "sys")
$ExcludeSet = @{}
foreach ($e in $Exclude) { if ($e) { $ExcludeSet[$e.Trim()] = $true } }

$Ext = if ($NoCompress) { ".sql" } else { ".sql.zip" }

if ($DryRun -and $Databases.Count -gt 0) {
    $rows = @()
    foreach ($db in $Databases) {
        $d = $db.Trim()
        if ($d -and -not $ExcludeSet.ContainsKey($d)) {
            $rows += [PSCustomObject]@{
                database   = $d
                status     = "DRY_RUN"
                file       = (Join-Path $BackupDir "$d$Ext")
                size_bytes = 0
                sha256     = "-"
                error      = ""
            }
        }
    }
    Write-Report -Rows $rows -Format $Output
    exit 0
}

$PleskMysqlBin = if ($env:plesk_dir) { Join-Path $env:plesk_dir "MySQL\bin" } else { $null }
$ExtraDirs = @($PleskMysqlBin, "C:\Program Files\MySQL\MySQL Server 8.0\bin", "C:\Program Files\MariaDB 10.11\bin")

$MysqlBin = Find-MysqlTool -Names @("mysql.exe", "mysql", "mariadb.exe", "mariadb") -ExtraDirs $ExtraDirs
$DumpBin  = Find-MysqlTool -Names @("mysqldump.exe", "mysqldump", "mariadb-dump.exe", "mariadb-dump") -ExtraDirs $ExtraDirs

if (-not $MysqlBin -or -not $DumpBin) {
    Write-Error "mysql and mysqldump (or mariadb/mariadb-dump) binaries were not found."
    exit 1
}

$Password = if ($env:MYSQL_PASSWORD) { $env:MYSQL_PASSWORD } else { "" }
if ($PromptPassword) {
    $sec = Read-Host -AsSecureString "MySQL password for $User@$MysqlHost"
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    $Password = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
}

$EscPw = $Password.Replace("\", "\\").Replace('"', '\"')
$CnfPath = [System.IO.Path]::GetTempFileName()
Set-Content -Path $CnfPath -Value "[client]`nuser=`"$User`"`npassword=`"$EscPw`"`nhost=`"$MysqlHost`"`nport=$Port" -Encoding ASCII

$Rows = @()
try {
    $TargetDbs = @()
    if ($Databases.Count -gt 0) {
        foreach ($d in $Databases) {
            if ($d -and -not $ExcludeSet.ContainsKey($d)) { $TargetDbs += $d }
        }
    } else {
        $rawDbs = & $MysqlBin "--defaults-extra-file=$CnfPath" "--batch" "--skip-column-names" "-e" "SHOW DATABASES;" 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "mysql failed: $($rawDbs -join ' ')"
        }
        foreach ($line in $rawDbs) {
            $db = $line.ToString().Trim()
            if ($db -and ($SystemDbs -notcontains $db) -and (-not $ExcludeSet.ContainsKey($db))) {
                $TargetDbs += $db
            }
        }
    }

    if ($DryRun) {
        foreach ($db in $TargetDbs) {
            $Rows += [PSCustomObject]@{
                database   = $db
                status     = "DRY_RUN"
                file       = (Join-Path $BackupDir "$db$Ext")
                size_bytes = 0
                sha256     = "-"
                error      = ""
            }
        }
    } else {
        if (-not (Test-Path $BackupDir)) {
            New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
        }
        $Ts = Get-Date -Format "yyyyMMdd-HHmmss"
        foreach ($db in $TargetDbs) {
            $SqlOut = Join-Path $BackupDir "$db-$Ts.sql"
            $FinalOut = if ($NoCompress) { $SqlOut } else { Join-Path $BackupDir "$db-$Ts.sql.zip" }
            & $DumpBin "--defaults-extra-file=$CnfPath" "--single-transaction" "--routines" "--triggers" "--databases" $db "--result-file=$SqlOut" 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $SqlOut)) {
                $Rows += [PSCustomObject]@{ database = $db; status = "ERROR"; file = ""; size_bytes = 0; sha256 = ""; error = "mysqldump failed" }
                continue
            }
            if (-not $NoCompress) {
                Compress-Archive -Path $SqlOut -DestinationPath $FinalOut -Force
                Remove-Item -Path $SqlOut -Force
            }
            $hash = (Get-FileHash -Path $FinalOut -Algorithm SHA256).Hash.ToLower()
            $size = (Get-Item $FinalOut).Length
            $Rows += [PSCustomObject]@{
                database   = $db
                status     = "OK"
                file       = $FinalOut
                size_bytes = $size
                sha256     = $hash
                error      = ""
            }
        }
        if ($RetainDays -gt 0) {
            $Cutoff = (Get-Date).AddDays(-$RetainDays)
            Get-ChildItem -Path $BackupDir -File | Where-Object { $_.LastWriteTime -lt $Cutoff -and ($_.Name -match '\.(sql|zip)$') } | Remove-Item -Force
        }
    }
}
finally {
    if (Test-Path $CnfPath) { Remove-Item -Path $CnfPath -Force -ErrorAction SilentlyContinue }
}

Write-Report -Rows $Rows -Format $Output
if ($Rows | Where-Object { $_.status -eq "ERROR" }) { exit 1 }
