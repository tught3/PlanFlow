$ErrorActionPreference = 'Stop'

$pgBin = 'C:\Program Files\PostgreSQL\18\bin'
$initdb = Join-Path $pgBin 'initdb.exe'
$pgCtl = Join-Path $pgBin 'pg_ctl.exe'
$psql = Join-Path $pgBin 'psql.exe'
foreach ($tool in @($initdb, $pgCtl, $psql)) {
    if (-not (Test-Path -LiteralPath $tool -PathType Leaf)) {
        throw "Required PostgreSQL tool not found: $tool"
    }
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$instancePath = Join-Path $tempRoot ('planflow-group-delete-' + [guid]::NewGuid().ToString('N'))
$dataPath = Join-Path $instancePath 'data'
$markerPath = Join-Path $instancePath '.planflow-test-runtime'
$portProbe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$portProbe.Start()
$port = ([Net.IPEndPoint]$portProbe.LocalEndpoint).Port
$portProbe.Stop()
$started = $false

try {
    [void][IO.Directory]::CreateDirectory($instancePath)
    [IO.File]::WriteAllText($markerPath, 'owned disposable PlanFlow test cluster')

    & $initdb -D $dataPath -U postgres --auth-local=trust --auth-host=trust --encoding=UTF8 --no-locale
    if ($LASTEXITCODE -ne 0) { throw "initdb failed with exit code $LASTEXITCODE" }

    & $pgCtl -D $dataPath -l (Join-Path $instancePath 'postgres.log') -o "-h 127.0.0.1 -p $port -c listen_addresses=127.0.0.1" -w start
    if ($LASTEXITCODE -ne 0) { throw "pg_ctl start failed with exit code $LASTEXITCODE" }
    $started = $true

    $fixture = Join-Path $PSScriptRoot 'group_deletion_notice_runtime.sql'
    & $psql -X -q -t -v ON_ERROR_STOP=1 -h 127.0.0.1 -p $port -U postgres -d postgres -f $fixture
    if ($LASTEXITCODE -ne 0) { throw "PostgreSQL integration fixture failed with exit code $LASTEXITCODE" }
}
finally {
    $safeToRemove = -not $started
    if ($started) {
        & $pgCtl -D $dataPath -m fast -w stop
        if ($LASTEXITCODE -eq 0) {
            $safeToRemove = $true
        }
        else {
            Write-Warning "Disposable pg_ctl stop returned $LASTEXITCODE; preserving its data directory rather than deleting files potentially in use."
        }
    }

    $resolvedInstance = [IO.Path]::GetFullPath($instancePath)
    $resolvedTemp = [IO.Path]::GetFullPath($tempRoot).TrimEnd('\') + '\'
    if ($safeToRemove -and $resolvedInstance.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        Remove-Item -LiteralPath $resolvedInstance -Recurse -Force
    }
}
