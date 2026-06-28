# Windows Server 2022 SQL Server 2022 + RDS Installer

PowerShell automation for an existing Windows Server 2022 GUI install. Run it
from an elevated PowerShell session to install SQL Server 2022 Database Engine
from local SQL Server media and enable Remote Desktop Services Session Host
access for users.

The script is intentionally conservative:

- SQL Server installs in Windows Authentication mode by default.
- The SQL `sa` login is not enabled unless you explicitly request mixed mode.
- RDS roles can be installed now while RDS CALs are added later.
- SQL Server media, product keys, and passwords are never stored in this repo.

## What this installs

- SQL Server 2022 Database Engine from a local folder, mounted ISO, or `setup.exe`.
- SQL Server service virtual accounts.
- Optional SQL TCP/IP enablement and firewall rule.
- Remote Desktop Session Host and RD Licensing roles.
- Windows Remote Desktop firewall rules.
- Optional members in the local `Remote Desktop Users` group.

## Licensing notes

This project does not include SQL Server licenses, SQL Server media, RDS CALs,
or Windows Server licenses.

For RDS, Windows Server normally allows a temporary grace period before an RD
Licensing server with valid CALs is required. You can install the RD Licensing
role with this script and add/activate CALs later through RD Licensing Manager.

For SQL Server, use properly licensed SQL Server 2022 media or evaluation media.
If you install Evaluation edition, plan the edition upgrade before the
evaluation period expires.

## SQL `sa` account behavior

Default behavior is Windows Authentication:

- No `sa` password is requested.
- SQL logins are not enabled.
- The built-in SQL `sa` login remains disabled.
- Members of `BUILTIN\Administrators` are made SQL sysadmins unless you pass a
  different `-SqlSysAdminAccounts` list.

If you need SQL Authentication, install in mixed mode:

```powershell
.\scripts\Install-WinServerSql2022Rds.ps1 `
  -AcceptSqlLicenseTerms `
  -SqlMediaPath 'D:\' `
  -SqlAuthMode Mixed `
  -PromptForSaPassword `
  -InstallRds
```

In mixed mode the script prompts interactively for the `sa` password during
install. It writes the password only to a temporary SQL setup configuration file
with restricted ACLs, then deletes that file after setup completes.

You can switch SQL Server from Windows Authentication to mixed mode later, but
doing it during install is cleaner because SQL setup validates and configures
the `sa` password as part of the installation.

## Prerequisites

- Windows Server 2022 with Desktop Experience.
- Local Administrator rights.
- SQL Server 2022 installation media available locally or as an ISO.
- PowerShell 5.1 or later.
- Internet is not required unless you choose to download SQL Server media
  separately.

## Quick start

Open PowerShell as Administrator, then run:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

.\scripts\Install-WinServerSql2022Rds.ps1 `
  -AcceptSqlLicenseTerms `
  -SqlMediaPath 'D:\' `
  -InstallRds `
  -RdsLicenseMode PerUser `
  -RdsUsers 'CONTOSO\AppUsers' `
  -EnableSqlTcp `
  -OpenSqlFirewall `
  -Restart
```

Use `D:\` when the SQL Server ISO is already mounted. You can also pass an ISO
path or a direct path to `setup.exe`:

```powershell
.\scripts\Install-WinServerSql2022Rds.ps1 `
  -AcceptSqlLicenseTerms `
  -SqlMediaPath 'C:\Installers\SQLServer2022-x64-ENU.iso' `
  -InstallRds
```

## Common examples

Install SQL Server only, Windows Authentication:

```powershell
.\scripts\Install-WinServerSql2022Rds.ps1 `
  -AcceptSqlLicenseTerms `
  -SqlMediaPath 'D:\' `
  -SkipRdsInstall
```

Install SQL Server with named sysadmin accounts:

```powershell
.\scripts\Install-WinServerSql2022Rds.ps1 `
  -AcceptSqlLicenseTerms `
  -SqlMediaPath 'D:\' `
  -SqlSysAdminAccounts 'CONTOSO\DBAdmins','CONTOSO\SqlOps'
```

Install RDS roles only:

```powershell
.\scripts\Install-WinServerSql2022Rds.ps1 `
  -SkipSqlInstall `
  -InstallRds `
  -RdsLicenseMode PerUser `
  -RdsUsers 'CONTOSO\AppUsers'
```

Install SQL Server with SQL Authentication enabled:

```powershell
.\scripts\Install-WinServerSql2022Rds.ps1 `
  -AcceptSqlLicenseTerms `
  -SqlMediaPath 'D:\' `
  -SqlAuthMode Mixed `
  -PromptForSaPassword
```

## Parameters

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-AcceptSqlLicenseTerms` | Off | Required for SQL Server setup. |
| `-SqlMediaPath` | None | Folder, ISO, or `setup.exe` for SQL Server 2022 setup. |
| `-SqlInstanceName` | `MSSQLSERVER` | SQL instance name. |
| `-SqlFeatures` | `SQLENGINE` | SQL setup features to install. |
| `-SqlAuthMode` | `Windows` | `Windows` or `Mixed`. |
| `-PromptForSaPassword` | Off | Prompt for `sa` password when mixed mode is selected. |
| `-SaPassword` | None | SecureString `sa` password for unattended mixed mode. |
| `-SqlSysAdminAccounts` | `BUILTIN\Administrators` | Windows accounts added as SQL sysadmin. |
| `-SqlProductKey` | None | Optional SQL Server product key for licensed media. |
| `-SqlInstallDir` | SQL default | Optional SQL Server instance root directory. |
| `-SqlDataDir` | SQL default | Optional user database and tempdb directory. |
| `-SqlBackupDir` | SQL default | Optional SQL backup directory. |
| `-EnableSqlTcp` | Off | Enable SQL TCP/IP after setup. |
| `-SqlTcpPort` | `1433` | Static SQL TCP port when TCP/IP is enabled. |
| `-OpenSqlFirewall` | Off | Add inbound firewall rule for the SQL TCP port. |
| `-InstallRds` | Off | Install and configure RDS roles. |
| `-RdsLicenseMode` | `PerUser` | RDS mode: `PerUser` or `PerDevice`. |
| `-RdsLicenseServers` | Local computer | License server list to assign to Session Host. |
| `-RdsUsers` | Empty | Users or groups to add to `Remote Desktop Users`. |
| `-Restart` | Off | Restart automatically if Windows features or SQL setup require it. |
| `-SkipSqlInstall` | Off | Skip SQL Server installation. |
| `-SkipRdsInstall` | Off | Skip RDS installation. |

## RDS notes

This is for a straightforward single-server RDS Session Host setup. It installs
the Session Host and Licensing role services and configures the server for RDP
user access.

For larger deployments with RD Connection Broker, RD Gateway, RD Web Access,
collections, profile disks, or high availability, use a full RDS deployment
design instead of this bootstrap script.

After installing RDS CALs later:

1. Open `licmgr.exe`.
2. Activate the RD Licensing server if it is not already activated.
3. Install the purchased RDS CALs.
4. Confirm the Session Host points to the correct licensing server.

## Reboot behavior

SQL Server setup and RDS role installation can both require a restart. Without
`-Restart`, the script reports that a reboot is required and exits. With
`-Restart`, the server restarts automatically at the end.

## Security reminders

- Prefer Windows Authentication and domain groups where possible.
- Avoid exposing SQL Server TCP/IP to broad networks.
- Keep the SQL Server service account model simple unless you need domain
  service accounts.
- Use a strong, unique `sa` password if mixed mode is required.
- Add only the required users or groups to `Remote Desktop Users`.
