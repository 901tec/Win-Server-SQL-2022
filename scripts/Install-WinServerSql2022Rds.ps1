#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$SqlMediaPath = 'D:\901TEC\SQLServer2022',

    [ValidatePattern('^[A-Za-z0-9_]{1,16}$')]
    [string]$SqlInstanceName = 'MSSQLSERVER',

    [ValidateNotNullOrEmpty()]
    [string[]]$SqlFeatures = @('SQLENGINE'),

    [ValidateSet('Windows', 'Mixed')]
    [string]$SqlAuthMode = 'Mixed',

    [SecureString]$SaPassword,

    [switch]$PromptForSaPassword,

    [switch]$KeepSaEnabled,

    [ValidateNotNullOrEmpty()]
    [string[]]$SqlSysAdminAccounts = @('BUILTIN\Administrators'),

    [string]$SqlProductKey,

    [string]$SqlInstallDir = 'C:\Program Files\Microsoft SQL Server',

    [string]$SqlDataDir = 'C:\SQLData',

    [string]$SqlLogDir = 'D:\SQLLogs',

    [string]$SqlBackupDir = 'D:\SQLBackups',

    [switch]$EnableSqlTcp,

    [ValidateRange(1, 65535)]
    [int]$SqlTcpPort = 1433,

    [switch]$OpenSqlFirewall,

    [switch]$InstallRds,

    [ValidateSet('PerUser', 'PerDevice')]
    [string]$RdsLicenseMode = 'PerUser',

    [string[]]$RdsLicenseServers = @($env:COMPUTERNAME),

    [string[]]$RdsUsers = @(),

    [switch]$SkipSqlInstall,

    [switch]$SkipRdsInstall,

    [switch]$AcceptSqlLicenseTerms,

    [switch]$Restart,

    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:NeedsRestart = $false
$script:MountedSqlImagePath = $null

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Assert-WindowsServer {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem

    if ($os.ProductType -eq 1) {
        throw "This script is intended for Windows Server. Detected client OS: $($os.Caption)"
    }

    if ($os.Caption -notmatch 'Windows Server 2022' -and -not $Force) {
        throw "This script is intended for Windows Server 2022. Detected: $($os.Caption). Use -Force to continue anyway."
    }

    Write-Verbose "Detected OS: $($os.Caption) build $($os.BuildNumber)"
}

function ConvertTo-PlainText {
    param([Parameter(Mandatory = $true)][SecureString]$SecureText)

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureText)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Read-ConfirmedSecureString {
    param([Parameter(Mandatory = $true)][string]$Prompt)

    $first = Read-Host "$Prompt" -AsSecureString
    $second = Read-Host "Confirm $Prompt" -AsSecureString

    $firstText = ConvertTo-PlainText -SecureText $first
    $secondText = ConvertTo-PlainText -SecureText $second

    try {
        if ($firstText -ne $secondText) {
            throw "The two passwords did not match."
        }

        if ($firstText.Length -lt 12) {
            throw "The SQL sa password must be at least 12 characters."
        }

        return $first
    }
    finally {
        $firstText = $null
        $secondText = $null
    }
}

function Assert-SaPasswordIsUsable {
    param([Parameter(Mandatory = $true)][SecureString]$SecureText)

    $plainText = ConvertTo-PlainText -SecureText $SecureText
    try {
        if ($plainText.Length -lt 12) {
            throw "The SQL sa password must be at least 12 characters."
        }

        if ($plainText -match '"') {
            throw "The SQL sa password cannot contain a double quote because SQL setup reads it from a temporary INI file."
        }
    }
    finally {
        $plainText = $null
    }
}

function Quote-IniValue {
    param([Parameter(Mandatory = $true)][string]$Value)

    '"' + ($Value -replace '"', '\"') + '"'
}

function Quote-IniList {
    param([Parameter(Mandatory = $true)][string[]]$Values)

    ($Values | ForEach-Object { Quote-IniValue -Value $_ }) -join ' '
}

function Ensure-Directory {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Set-PrivateFileAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    $acl = New-Object System.Security.AccessControl.FileSecurity
    $adminSid = New-Object System.Security.Principal.SecurityIdentifier -ArgumentList 'S-1-5-32-544'
    $systemSid = New-Object System.Security.Principal.SecurityIdentifier -ArgumentList 'S-1-5-18'
    $rights = [System.Security.AccessControl.FileSystemRights]::FullControl
    $inheritance = [System.Security.AccessControl.InheritanceFlags]::None
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow

    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule -ArgumentList $adminSid, $rights, $inheritance, $propagation, $allow))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule -ArgumentList $systemSid, $rights, $inheritance, $propagation, $allow))

    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Resolve-SqlSetupPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $resolvedPath = Resolve-Path -LiteralPath $Path -ErrorAction Stop | Select-Object -First 1 -ExpandProperty ProviderPath

    if (Test-Path -LiteralPath $resolvedPath -PathType Leaf) {
        $leafName = Split-Path -Leaf $resolvedPath

        if ($leafName -ieq 'setup.exe') {
            return $resolvedPath
        }

        if ([IO.Path]::GetExtension($resolvedPath) -ieq '.iso') {
            Write-Step "Mounting SQL Server ISO"
            $image = Mount-DiskImage -ImagePath $resolvedPath -PassThru
            $script:MountedSqlImagePath = $resolvedPath

            $volume = $image | Get-Volume | Where-Object { $_.DriveLetter } | Select-Object -First 1
            if (-not $volume) {
                Start-Sleep -Seconds 3
                $volume = Get-DiskImage -ImagePath $resolvedPath | Get-Volume | Where-Object { $_.DriveLetter } | Select-Object -First 1
            }

            if (-not $volume) {
                throw "Mounted ISO, but no drive letter was assigned."
            }

            $setupFromIso = Join-Path -Path ($volume.DriveLetter + ':\') -ChildPath 'setup.exe'
            if (-not (Test-Path -LiteralPath $setupFromIso -PathType Leaf)) {
                throw "Mounted ISO does not contain setup.exe at $setupFromIso"
            }

            return $setupFromIso
        }

        throw "SqlMediaPath must be a folder containing setup.exe, an ISO file, or setup.exe itself."
    }

    $setupFromFolder = Join-Path -Path $resolvedPath -ChildPath 'setup.exe'
    if (-not (Test-Path -LiteralPath $setupFromFolder -PathType Leaf)) {
        throw "Could not find setup.exe in $resolvedPath"
    }

    return $setupFromFolder
}

function Get-SqlServiceName {
    param([Parameter(Mandatory = $true)][string]$InstanceName)

    if ($InstanceName -eq 'MSSQLSERVER') {
        return 'MSSQLSERVER'
    }

    return "MSSQL`$$InstanceName"
}

function Get-SqlConnectionServerName {
    param([Parameter(Mandatory = $true)][string]$InstanceName)

    if ($InstanceName -eq 'MSSQLSERVER') {
        return 'localhost'
    }

    return "localhost\$InstanceName"
}

function Invoke-SqlNonQueryWithRetry {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [Parameter(Mandatory = $true)][string]$Query,
        [int]$TimeoutSeconds = 120
    )

    $serverName = Get-SqlConnectionServerName -InstanceName $InstanceName
    $connectionString = "Server=$serverName;Database=master;Integrated Security=SSPI;Connection Timeout=5;"
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastError = $null

    do {
        $connection = $null
        $command = $null

        try {
            $connection = New-Object System.Data.SqlClient.SqlConnection -ArgumentList $connectionString
            $connection.Open()

            $command = $connection.CreateCommand()
            $command.CommandTimeout = 30
            $command.CommandText = $Query
            $command.ExecuteNonQuery() | Out-Null
            return
        }
        catch {
            $lastError = $_.Exception
            if ([DateTime]::UtcNow -ge $deadline) {
                throw "SQL command failed on $serverName after $TimeoutSeconds seconds: $($lastError.Message)"
            }

            Start-Sleep -Seconds 5
        }
        finally {
            if ($command) {
                $command.Dispose()
            }

            if ($connection) {
                $connection.Dispose()
            }
        }
    } while ($true)
}

function Disable-SqlSaLogin {
    param([Parameter(Mandatory = $true)][string]$InstanceName)

    $query = @"
DECLARE @SaLoginName sysname = SUSER_SNAME(0x01);

IF @SaLoginName IS NOT NULL
BEGIN
    DECLARE @Sql nvarchar(max) = N'ALTER LOGIN ' + QUOTENAME(@SaLoginName) + N' DISABLE;';
    EXEC sys.sp_executesql @Sql;
END;
"@

    Write-Step "Disabling the SQL sa login"
    Invoke-SqlNonQueryWithRetry -InstanceName $InstanceName -Query $query
}

function New-SqlSetupConfigurationFile {
    param(
        [Parameter(Mandatory = $true)][string]$InstanceName,
        [Parameter(Mandatory = $true)][string[]]$Features,
        [Parameter(Mandatory = $true)][string[]]$SysAdminAccounts,
        [Parameter(Mandatory = $true)][string]$AuthMode,
        [SecureString]$SecureSaPassword
    )

    $configPath = Join-Path -Path $env:TEMP -ChildPath ("SqlServer2022Setup-{0}.ini" -f ([Guid]::NewGuid().ToString('N')))
    $agentAccount = if ($InstanceName -eq 'MSSQLSERVER') { 'NT Service\SQLSERVERAGENT' } else { "NT Service\SQLAgent`$$InstanceName" }
    $engineAccount = if ($InstanceName -eq 'MSSQLSERVER') { 'NT Service\MSSQLSERVER' } else { "NT Service\MSSQL`$$InstanceName" }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('[OPTIONS]')
    $lines.Add('ACTION="Install"')
    $lines.Add(('FEATURES="{0}"' -f (($Features | ForEach-Object { $_.Trim() }) -join ',')))
    $lines.Add(('INSTANCENAME={0}' -f (Quote-IniValue -Value $InstanceName)))
    $lines.Add(('SQLSVCACCOUNT={0}' -f (Quote-IniValue -Value $engineAccount)))
    $lines.Add('SQLSVCSTARTUPTYPE="Automatic"')
    $lines.Add(('AGTSVCACCOUNT={0}' -f (Quote-IniValue -Value $agentAccount)))
    $lines.Add('AGTSVCSTARTUPTYPE="Automatic"')
    $lines.Add(('SQLSYSADMINACCOUNTS={0}' -f (Quote-IniList -Values $SysAdminAccounts)))
    $lines.Add('BROWSERSVCSTARTUPTYPE="Disabled"')
    $lines.Add('TCPENABLED="0"')
    $lines.Add('NPENABLED="0"')

    if ($SqlInstallDir) {
        $lines.Add(('INSTANCEDIR={0}' -f (Quote-IniValue -Value $SqlInstallDir)))
    }

    if ($SqlDataDir) {
        $lines.Add(('SQLUSERDBDIR={0}' -f (Quote-IniValue -Value $SqlDataDir)))
        $lines.Add(('SQLTEMPDBDIR={0}' -f (Quote-IniValue -Value $SqlDataDir)))
    }

    if ($SqlLogDir) {
        $lines.Add(('SQLUSERDBLOGDIR={0}' -f (Quote-IniValue -Value $SqlLogDir)))
        $lines.Add(('SQLTEMPDBLOGDIR={0}' -f (Quote-IniValue -Value $SqlLogDir)))
    }

    if ($SqlBackupDir) {
        $lines.Add(('SQLBACKUPDIR={0}' -f (Quote-IniValue -Value $SqlBackupDir)))
    }

    if ($SqlProductKey) {
        $lines.Add(('PID={0}' -f (Quote-IniValue -Value $SqlProductKey)))
    }

    if ($AuthMode -eq 'Mixed') {
        if (-not $SecureSaPassword) {
            throw "Mixed mode requires an sa password."
        }

        $plainSaPassword = ConvertTo-PlainText -SecureText $SecureSaPassword
        try {
            $lines.Add('SECURITYMODE="SQL"')
            $lines.Add(('SAPWD={0}' -f (Quote-IniValue -Value $plainSaPassword)))
        }
        finally {
            $plainSaPassword = $null
        }
    }

    Set-Content -LiteralPath $configPath -Value $lines -Encoding ASCII
    Set-PrivateFileAcl -Path $configPath

    return $configPath
}

function Invoke-SqlSetup {
    param([Parameter(Mandatory = $true)][string]$SetupPath)

    if (-not $AcceptSqlLicenseTerms) {
        throw "SQL Server setup requires -AcceptSqlLicenseTerms."
    }

    if (-not $SqlMediaPath) {
        throw "SqlMediaPath is required unless -SkipSqlInstall is used."
    }

    $serviceName = Get-SqlServiceName -InstanceName $SqlInstanceName
    $existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($existingService -and -not $Force) {
        Write-Warning "SQL service $serviceName already exists. Skipping SQL setup. Use -Force to run setup anyway."
        return
    }

    $secureSaPasswordForSetup = $null
    if ($SqlAuthMode -eq 'Mixed') {
        $secureSaPasswordForSetup = $SaPassword
        if (-not $secureSaPasswordForSetup -or $PromptForSaPassword) {
            $secureSaPasswordForSetup = Read-ConfirmedSecureString -Prompt 'SQL sa password'
        }

        Assert-SaPasswordIsUsable -SecureText $secureSaPasswordForSetup
    }
    elseif ($SaPassword) {
        throw "-SaPassword is only valid when -SqlAuthMode Mixed is selected."
    }

    if ($SqlInstallDir) {
        Ensure-Directory -Path $SqlInstallDir
    }

    if ($SqlDataDir) {
        Ensure-Directory -Path $SqlDataDir
    }

    if ($SqlLogDir) {
        Ensure-Directory -Path $SqlLogDir
    }

    if ($SqlBackupDir) {
        Ensure-Directory -Path $SqlBackupDir
    }

    $configPath = New-SqlSetupConfigurationFile `
        -InstanceName $SqlInstanceName `
        -Features $SqlFeatures `
        -SysAdminAccounts $SqlSysAdminAccounts `
        -AuthMode $SqlAuthMode `
        -SecureSaPassword $secureSaPasswordForSetup

    try {
        $arguments = @(
            '/Q',
            '/INDICATEPROGRESS',
            '/IACCEPTSQLSERVERLICENSETERMS',
            '/SUPPRESSPRIVACYSTATEMENTNOTICE',
            ('/CONFIGURATIONFILE="{0}"' -f $configPath)
        )

        Write-Step "Installing SQL Server 2022 instance $SqlInstanceName"
        Write-Host "Running SQL setup from $SetupPath"
        $process = Start-Process -FilePath $SetupPath -ArgumentList $arguments -Wait -PassThru

        if ($process.ExitCode -eq 3010) {
            $script:NeedsRestart = $true
            Write-Warning "SQL Server setup completed and requested a reboot."
        }
        elseif ($process.ExitCode -ne 0) {
            throw "SQL Server setup failed with exit code $($process.ExitCode). Review SQL setup logs under C:\Program Files\Microsoft SQL Server\160\Setup Bootstrap\Log."
        }

        if ($SqlAuthMode -eq 'Mixed' -and -not $KeepSaEnabled) {
            Disable-SqlSaLogin -InstanceName $SqlInstanceName
        }
    }
    finally {
        if (Test-Path -LiteralPath $configPath) {
            Remove-Item -LiteralPath $configPath -Force
        }
    }
}

function Enable-SqlTcpIp {
    $instanceNamesPath = 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL'

    if (-not (Test-Path -LiteralPath $instanceNamesPath)) {
        throw "SQL Server instance registry path was not found. Cannot configure TCP/IP."
    }

    $instanceId = (Get-ItemProperty -LiteralPath $instanceNamesPath).$SqlInstanceName
    if (-not $instanceId) {
        throw "SQL Server instance $SqlInstanceName was not found in the registry."
    }

    $tcpPath = "HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\$instanceId\MSSQLServer\SuperSocketNetLib\Tcp"
    $ipAllPath = Join-Path -Path $tcpPath -ChildPath 'IPAll'

    if (-not (Test-Path -LiteralPath $tcpPath) -or -not (Test-Path -LiteralPath $ipAllPath)) {
        throw "SQL TCP/IP registry path was not found for instance $SqlInstanceName."
    }

    Write-Step "Configuring SQL Server TCP/IP on port $SqlTcpPort"
    Set-ItemProperty -LiteralPath $tcpPath -Name Enabled -Value 1
    Set-ItemProperty -LiteralPath $ipAllPath -Name TcpDynamicPorts -Value ''
    Set-ItemProperty -LiteralPath $ipAllPath -Name TcpPort -Value ([string]$SqlTcpPort)

    $serviceName = Get-SqlServiceName -InstanceName $SqlInstanceName
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
        Restart-Service -Name $serviceName -Force
    }
    else {
        Write-Warning "SQL service $serviceName was not found. TCP/IP settings will apply when the service starts."
    }
}

function Add-SqlFirewallRule {
    $displayName = "SQL Server $SqlInstanceName TCP $SqlTcpPort"
    $existingRule = Get-NetFirewallRule -DisplayName $displayName -ErrorAction SilentlyContinue

    if ($existingRule) {
        Write-Verbose "Firewall rule already exists: $displayName"
        return
    }

    Write-Step "Opening Windows Firewall for SQL Server TCP $SqlTcpPort"
    New-NetFirewallRule `
        -DisplayName $displayName `
        -Direction Inbound `
        -Action Allow `
        -Protocol TCP `
        -LocalPort $SqlTcpPort | Out-Null
}

function Install-RdsRoles {
    Import-Module ServerManager

    Write-Step "Installing Remote Desktop Services roles"
    $result = Install-WindowsFeature `
        -Name RDS-RD-Server, RDS-Licensing `
        -IncludeManagementTools

    if (-not $result.Success) {
        throw "RDS role installation failed."
    }

    if ($result.RestartNeeded -eq 'Yes') {
        $script:NeedsRestart = $true
    }
}

function Enable-RemoteDesktopAccess {
    Write-Step "Enabling Remote Desktop access"

    Set-ItemProperty `
        -LiteralPath 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
        -Name fDenyTSConnections `
        -Value 0

    Set-ItemProperty `
        -LiteralPath 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' `
        -Name UserAuthentication `
        -Value 1

    Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' | Out-Null
}

function Set-RdsLicensing {
    $licensingType = if ($RdsLicenseMode -eq 'PerUser') { 4 } else { 2 }
    $serverList = ($RdsLicenseServers | Where-Object { $_ } | Select-Object -Unique) -join ','

    Write-Step "Configuring RDS licensing mode $RdsLicenseMode"

    try {
        $tsSettings = Get-CimInstance `
            -Namespace 'root/CIMV2/TerminalServices' `
            -ClassName Win32_TerminalServiceSetting

        Invoke-CimMethod `
            -InputObject $tsSettings `
            -MethodName ChangeMode `
            -Arguments @{ LicensingType = [uint32]$licensingType } | Out-Null

        if ($serverList) {
            Invoke-CimMethod `
                -InputObject $tsSettings `
                -MethodName SetSpecifiedLicenseServerList `
                -Arguments @{ SpecifiedLSList = $serverList } | Out-Null
        }
    }
    catch {
        Write-Warning "Could not configure RDS licensing through WMI/CIM yet: $($_.Exception.Message)"
        Write-Warning "If the RDS role just installed, reboot and rerun the script or configure licensing in Server Manager."
    }

    $licensingCorePath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\RCM\Licensing Core'
    if (Test-Path -LiteralPath $licensingCorePath) {
        Set-ItemProperty -LiteralPath $licensingCorePath -Name LicensingMode -Type DWord -Value $licensingType
    }
}

function Add-RdsUsers {
    if (-not $RdsUsers -or $RdsUsers.Count -eq 0) {
        return
    }

    Write-Step "Adding users/groups to Remote Desktop Users"

    foreach ($member in $RdsUsers) {
        if (-not $member) {
            continue
        }

        try {
            Add-LocalGroupMember -Group 'Remote Desktop Users' -Member $member -ErrorAction Stop
            Write-Host "Added $member"
        }
        catch {
            if ($_.Exception.Message -match 'already.*member') {
                Write-Host "$member is already a member"
            }
            else {
                throw
            }
        }
    }
}

try {
    Assert-WindowsServer

    if ($SkipSqlInstall -and $SkipRdsInstall) {
        throw "Both -SkipSqlInstall and -SkipRdsInstall were specified. There is nothing to do."
    }

    if (-not $SkipSqlInstall) {
        if (-not $SqlMediaPath) {
            throw "SqlMediaPath is required unless -SkipSqlInstall is used."
        }

        $setupPath = Resolve-SqlSetupPath -Path $SqlMediaPath
        Invoke-SqlSetup -SetupPath $setupPath

        if ($EnableSqlTcp) {
            Enable-SqlTcpIp
        }

        if ($OpenSqlFirewall) {
            Add-SqlFirewallRule
        }
    }

    if ($InstallRds -and -not $SkipRdsInstall) {
        Install-RdsRoles
        Enable-RemoteDesktopAccess
        Set-RdsLicensing
        Add-RdsUsers
    }
    elseif (-not $SkipRdsInstall) {
        Write-Verbose "RDS installation skipped because -InstallRds was not specified."
    }

    if ($script:NeedsRestart) {
        if ($Restart) {
            Write-Step "Restarting server"
            Restart-Computer -Force
        }
        else {
            Write-Warning "A reboot is required. Restart the server when convenient."
        }
    }
    else {
        Write-Step "Completed without a required reboot"
    }
}
finally {
    if ($script:MountedSqlImagePath) {
        Write-Step "Dismounting SQL Server ISO"
        Dismount-DiskImage -ImagePath $script:MountedSqlImagePath -ErrorAction SilentlyContinue
    }
}
