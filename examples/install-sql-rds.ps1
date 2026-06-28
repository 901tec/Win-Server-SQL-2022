# Example: run from an elevated PowerShell session on Windows Server 2022.
# This downloads SQL Server 2022 Developer media to D:\901TEC before installing.
# For licensed Standard/Enterprise media, stage it at D:\901TEC\SQLServer2022
# and remove -DownloadSqlMedia.

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

..\scripts\Install-WinServerSql2022Rds.ps1 `
    -AcceptSqlLicenseTerms `
    -DownloadSqlMedia `
    -SqlMediaPath 'D:\901TEC\SQLServer2022' `
    -KeepSaEnabled `
    -SqlSysAdminAccounts "$($env:USERDOMAIN)\$($env:USERNAME)",'BUILTIN\Administrators' `
    -InstallRds `
    -RdsLicenseMode PerUser `
    -RdsUsers 'CONTOSO\AppUsers' `
    -EnableSqlTcp `
    -OpenSqlFirewall `
    -InstallSsms
