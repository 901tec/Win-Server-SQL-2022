# Windows Server 2022 SQL Server 2022 + RDS Installer

PowerShell automation for an existing Windows Server 2022 GUI install. Run it
from an elevated PowerShell session to install SQL Server 2022 Database Engine
from local SQL Server media and enable Remote Desktop Services Session Host
access for users.

The script is intentionally conservative:

- SQL Server installs in mixed authentication mode by default, but disables the
  built-in SQL `sa` login immediately after setup.
- SQL Server data defaults to the OS `C:` drive, while SQL transaction logs and
  backups default to `D:`.
- SQL Server installation media defaults to `D:\901TEC\SQLServer2022`.
- SQL Server 2022 media can optionally be downloaded to `D:` before install.
- RDS roles can be installed now while RDS CALs are added later.
- SQL Server media, product keys, and passwords are never stored in this repo.

## What this installs

- SQL Server 2022 Database Engine from a local folder, mounted ISO, or `setup.exe`.
- SQL Server service virtual accounts.
- SQL Server paths that remain changeable with parameters:
  `C:\Program Files\Microsoft SQL Server`, `C:\SQLData`, `D:\SQLLogs`, and
  `D:\SQLBackups`.
- Optional SQL TCP/IP enablement and firewall rule.
- Optional SQL Server Management Studio installation.
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

The built-in download option uses Microsoft's SQL Server 2022 Developer
bootstrapper by default. Developer edition is useful for development and testing,
but it is not licensed for production workloads. For licensed Standard or
Enterprise deployments, either stage your licensed media at
`D:\901TEC\SQLServer2022` or pass your own approved download URL with
`-SqlDownloadUrl`.

## SQL authentication behavior

Default behavior is mixed authentication mode with SQL logins locked down:

- SQL Server setup requires an `sa` password for mixed mode, so the script
  prompts for a temporary bootstrap `sa` password unless you pass `-SaPassword`.
- After setup completes, the script connects with Windows Authentication and
  disables the built-in `sa` login.
- The installer does not create any additional SQL logins.
- Members of `BUILTIN\Administrators` are made SQL sysadmins unless you pass a
  different `-SqlSysAdminAccounts` list.

That means local Windows Administrators are not literally using the `sa` login,
but they do receive the SQL Server `sysadmin` role by default in this script.
Permission-wise, that is effectively equivalent to `sa`. If you want tighter
control, pass a specific domain or local group with `-SqlSysAdminAccounts`, such
as `CONTOSO\DBAdmins`.

Windows admin users can add SQL logins later from SQL Server Management Studio
or T-SQL after the install. If you want Windows Authentication only, pass
`-SqlAuthMode Windows`. If you intentionally want the `sa` login left enabled,
pass `-KeepSaEnabled`.

Mixed mode with `sa` disabled is the default, but this is the explicit form:

```powershell
.\scripts\Install-WinServerSql2022Rds.ps1 `
  -AcceptSqlLicenseTerms `
  -SqlMediaPath 'D:\901TEC\SQLServer2022' `
  -SqlAuthMode Mixed `
  -PromptForSaPassword `
  -InstallRds
```

The script writes the bootstrap `sa` password only to a temporary SQL setup
configuration file with restricted ACLs, then deletes that file after setup
completes.

## Prerequisites

- Windows Server 2022 with Desktop Experience.
- Local Administrator rights.
- SQL Server 2022 installation media available locally or as an ISO.
- PowerShell 5.1 or later.
- Internet is not required unless you choose to download SQL Server media
  separately.

## Quick start

Open PowerShell as Administrator, then run this if SQL Server media is already
under `D:\901TEC\SQLServer2022`:

Because mixed mode is the default, this command prompts for a temporary
bootstrap `sa` password during SQL setup. The script disables `sa` after setup.

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

$RequiredDirectories = @(
  'D:\901TEC',
  'D:\901TEC\Downloads',
  'D:\901TEC\SQLServer2022',
  'C:\SQLData',
  'D:\SQLLogs',
  'D:\SQLBackups'
)

foreach ($Directory in $RequiredDirectories) {
  New-Item -ItemType Directory -Path $Directory -Force | Out-Null
}

.\scripts\Install-WinServerSql2022Rds.ps1 `
  -AcceptSqlLicenseTerms `
  -SqlMediaPath 'D:\901TEC\SQLServer2022' `
  -InstallRds `
  -RdsLicenseMode PerUser `
  -RdsUsers 'CONTOSO\AppUsers' `
  -EnableSqlTcp `
  -OpenSqlFirewall `
  -InstallSsms `
  -Restart
```

To have the script download SQL Server 2022 Developer media to `D:` first, add
`-DownloadSqlMedia`:

```powershell
$RequiredDirectories = @(
  'D:\901TEC',
  'D:\901TEC\Downloads',
  'D:\901TEC\SQLServer2022',
  'C:\SQLData',
  'D:\SQLLogs',
  'D:\SQLBackups'
)

foreach ($Directory in $RequiredDirectories) {
  New-Item -ItemType Directory -Path $Directory -Force | Out-Null
}

.\scripts\Install-WinServerSql2022Rds.ps1 `
  -AcceptSqlLicenseTerms `
  -DownloadSqlMedia `
  -InstallRds `
  -RdsLicenseMode PerUser `
  -RdsUsers 'CONTOSO\AppUsers' `
  -EnableSqlTcp `
  -OpenSqlFirewall `
  -InstallSsms `
  -Restart
```

Use `D:\901TEC\SQLServer2022` when the SQL Server installer files live there.
You can also pass an ISO path, mounted ISO drive, or direct path to `setup.exe`.
For an ISO:

```powershell
.\scripts\Install-WinServerSql2022Rds.ps1 `
  -AcceptSqlLicenseTerms `
  -SqlMediaPath 'D:\901TEC\SQLServer2022-x64-ENU.iso' `
  -InstallRds
```

## Download behavior

When `-DownloadSqlMedia` is used, the script:

1. Downloads the SQL Server bootstrapper to `D:\901TEC\Downloads`.
2. Uses that bootstrapper to download SQL Server install media into
   `D:\901TEC\SQLServer2022`.
3. Finds the downloaded ISO or `setup.exe`.
4. Mounts the ISO if needed, then installs SQL Server from the local media.

Default download settings:

```powershell
-SqlDownloadUrl 'https://go.microsoft.com/fwlink/?linkid=2215158'
-SqlDownloadDir 'D:\901TEC\Downloads'
-SqlDownloadMediaType ISO
```

The default Microsoft URL currently points to the SQL Server 2022 Developer
bootstrapper. Override `-SqlDownloadUrl` if you maintain an internal or licensed
installer source.

## SSMS behavior

Use `-InstallSsms` to download and install SQL Server Management Studio during
the deployment. The installer is stored in `D:\901TEC\Downloads`.

Default SSMS settings:

```powershell
-SsmsDownloadUrl 'https://aka.ms/ssms/22/release/vs_SSMS.exe'
-SsmsDownloadDir 'D:\901TEC\Downloads'
```

The script skips SSMS if it already appears installed unless `-Force` is used.
You can also pass `-SsmsInstallerPath` to use a manually staged SSMS installer.

## Common examples

Install SQL Server only, mixed mode with `sa` disabled:

```powershell
.\scripts\Install-WinServerSql2022Rds.ps1 `
  -AcceptSqlLicenseTerms `
  -SqlMediaPath 'D:\901TEC\SQLServer2022' `
  -SkipRdsInstall
```

Install SQL Server with named sysadmin accounts:

```powershell
.\scripts\Install-WinServerSql2022Rds.ps1 `
  -AcceptSqlLicenseTerms `
  -SqlMediaPath 'D:\901TEC\SQLServer2022' `
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

Install SQL Server with Windows Authentication only:

```powershell
.\scripts\Install-WinServerSql2022Rds.ps1 `
  -AcceptSqlLicenseTerms `
  -SqlMediaPath 'D:\901TEC\SQLServer2022' `
  -SqlAuthMode Windows
```

## Parameters

| Parameter | Default | Purpose |
| --- | --- | --- |
| `-AcceptSqlLicenseTerms` | Off | Required for SQL Server setup. |
| `-SqlMediaPath` | `D:\901TEC\SQLServer2022` | Folder, ISO, or `setup.exe` for SQL Server 2022 setup. |
| `-DownloadSqlMedia` | Off | Download SQL Server media before installing if local media is not already present. |
| `-SqlDownloadUrl` | Microsoft SQL Server 2022 Developer bootstrapper | URL for the SQL Server bootstrapper or approved internal download. |
| `-SqlDownloadDir` | `D:\901TEC\Downloads` | Folder where the SQL bootstrapper is stored. |
| `-SqlDownloadMediaType` | `ISO` | Downloaded media type. ISO is the supported path for this script. |
| `-SqlInstanceName` | `MSSQLSERVER` | SQL instance name. |
| `-SqlFeatures` | `SQLENGINE` | SQL setup features to install. |
| `-SqlAuthMode` | `Mixed` | `Windows` or `Mixed`. |
| `-PromptForSaPassword` | Off | Force an interactive `sa` password prompt, even if `-SaPassword` is supplied. |
| `-SaPassword` | None | SecureString `sa` password for unattended mixed mode. |
| `-KeepSaEnabled` | Off | Leave the built-in `sa` login enabled after mixed-mode setup. |
| `-SqlSysAdminAccounts` | `BUILTIN\Administrators` | Windows accounts added as SQL sysadmin. |
| `-SqlProductKey` | None | Optional SQL Server product key for licensed media. |
| `-SqlInstallDir` | `C:\Program Files\Microsoft SQL Server` | SQL Server instance root directory. |
| `-SqlDataDir` | `C:\SQLData` | User database and tempdb data directory. |
| `-SqlLogDir` | `D:\SQLLogs` | User database and tempdb log directory. |
| `-SqlBackupDir` | `D:\SQLBackups` | SQL backup directory. |
| `-EnableSqlTcp` | Off | Enable SQL TCP/IP after setup. |
| `-SqlTcpPort` | `1433` | Static SQL TCP port when TCP/IP is enabled. |
| `-OpenSqlFirewall` | Off | Add inbound firewall rule for the SQL TCP port. |
| `-InstallSsms` | Off | Download and quietly install SQL Server Management Studio. |
| `-SsmsDownloadUrl` | Microsoft SSMS 22 bootstrapper | URL for the SSMS installer bootstrapper. |
| `-SsmsDownloadDir` | `D:\901TEC\Downloads` | Folder where the SSMS installer is stored. |
| `-SsmsInstallerPath` | None | Path to a manually staged SSMS installer. |
| `-SsmsInstallPath` | SSMS default | Optional custom SSMS install path. |
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
- Use a strong, unique bootstrap `sa` password for mixed mode, even though this
  script disables `sa` after setup by default.
- Add only the required users or groups to `Remote Desktop Users`.
