# Example: run from an elevated PowerShell session on Windows Server 2022.
# Adjust the SQL media path and RDS users/groups before running.

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

..\scripts\Install-WinServerSql2022Rds.ps1 `
    -AcceptSqlLicenseTerms `
    -SqlMediaPath 'D:\901TEC\SQLServer2022' `
    -InstallRds `
    -RdsLicenseMode PerUser `
    -RdsUsers 'CONTOSO\AppUsers' `
    -EnableSqlTcp `
    -OpenSqlFirewall
