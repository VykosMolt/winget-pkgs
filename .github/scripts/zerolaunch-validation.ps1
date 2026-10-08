$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$evidence = Join-Path $env:RUNNER_TEMP 'zerolaunch-evidence'
New-Item -ItemType Directory -Path $evidence -Force | Out-Null
$manifest = Join-Path $env:GITHUB_WORKSPACE 'manifests/g/ghost-him/ZeroLaunch-rs/0.5.2'
$result = [ordered]@{
    commit = $env:GITHUB_SHA
    architecture = $env:TARGET_ARCHITECTURE
    os = [Environment]::OSVersion.VersionString
    nativeArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
}

try {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        $release = Invoke-RestMethod 'https://api.github.com/repos/microsoft/winget-cli/releases/tags/v1.29.380' -Headers @{ Authorization = "Bearer $env:GITHUB_TOKEN" }
        $bundle = Join-Path $env:RUNNER_TEMP 'DesktopAppInstaller.msixbundle'
        $dependenciesZip = Join-Path $env:RUNNER_TEMP 'DesktopAppInstaller_Dependencies.zip'
        $bundleAsset = $release.assets | Where-Object name -eq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
        $dependenciesAsset = $release.assets | Where-Object name -eq 'DesktopAppInstaller_Dependencies.zip'
        Invoke-WebRequest $bundleAsset.browser_download_url -OutFile $bundle
        Invoke-WebRequest $dependenciesAsset.browser_download_url -OutFile $dependenciesZip
        $dependenciesDirectory = Join-Path $env:RUNNER_TEMP 'winget-dependencies'
        Expand-Archive $dependenciesZip $dependenciesDirectory
        $dependencies = @(Get-ChildItem $dependenciesDirectory -Recurse -File | Where-Object {
            $_.Extension -in @('.appx', '.msix') -and $_.FullName -match "[\\/]$($env:TARGET_ARCHITECTURE)[\\/]"
        } | Select-Object -ExpandProperty FullName)
        if ($dependencies.Count -eq 0) { throw 'No native WinGet dependency packages found' }
        Add-AppxPackage -Path $bundle -DependencyPath $dependencies
        $installation = Get-AppxPackage -Name Microsoft.DesktopAppInstaller
        if (-not $installation) { throw 'WinGet package was not registered' }
        $env:PATH = "$($installation.InstallLocation);$env:PATH"
    }
    winget --info
    if ($LASTEXITCODE -ne 0) { throw 'winget bootstrap failed' }
    winget settings --enable LocalManifestFiles
    if ($LASTEXITCODE -ne 0) { throw 'Could not enable local manifest validation' }
    winget validate --manifest $manifest
    $result.validateExitCode = $LASTEXITCODE
    if ($LASTEXITCODE -ne 0) { throw 'Manifest validation failed' }

    python -m pip install --disable-pip-version-check PyYAML
    if ($LASTEXITCODE -ne 0) { throw 'Could not install manifest parser' }
    $installerManifest = Join-Path $manifest 'ghost-him.ZeroLaunch-rs.installer.yaml'
    $parsed = python -c 'import json,sys,yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1],encoding="utf-8")),default=str))' $installerManifest
    if ($LASTEXITCODE -ne 0) { throw 'Could not parse installer manifest' }
    $data = $parsed | ConvertFrom-Json
    $entry = $data.Installers | Where-Object Architecture -eq $env:TARGET_ARCHITECTURE
    if (@($entry).Count -ne 1) { throw 'Expected exactly one matching installer' }
    $msi = Join-Path $evidence 'installer.msi'
    Invoke-WebRequest $entry.InstallerUrl -OutFile $msi
    $result.actualSha256 = (Get-FileHash $msi -Algorithm SHA256).Hash
    $result.expectedSha256 = $entry.InstallerSha256
    if ($result.actualSha256 -ne $result.expectedSha256) { throw 'Installer hash mismatch' }
    $windowsInstaller = New-Object -ComObject WindowsInstaller.Installer
    $database = $windowsInstaller.OpenDatabase($msi, 0)
    foreach ($property in @('ProductCode', 'ProductVersion')) {
        $view = $database.OpenView("SELECT ``Value`` FROM ``Property`` WHERE ``Property`` = '$property'")
        $view.Execute()
        $record = $view.Fetch()
        $result[$property] = $record.StringData(1)
        $view.Close()
    }
    if ($result.ProductCode -ne $entry.ProductCode) { throw 'Installer ProductCode mismatch' }
    if ($result.ProductVersion -ne $data.PackageVersion) { throw 'Installer ProductVersion mismatch' }

    winget install --manifest $manifest --silent --accept-source-agreements --accept-package-agreements --disable-interactivity --log (Join-Path $evidence 'winget-install.log')
    $result.installExitCode = $LASTEXITCODE
    if ($LASTEXITCODE -ne 0) { throw 'Manifest installation failed' }
    $executable = Join-Path $env:ProgramFiles 'zerolaunch-rs/zerolaunch-rs.exe'
    if (-not (Test-Path $executable)) { throw "Installed executable missing: $executable" }
    Get-ChildItem (Split-Path $executable) -File | Select-Object Name, Length | ConvertTo-Json | Set-Content (Join-Path $evidence 'installed-files.json')
    foreach ($dll in @('MSVCP140.dll', 'MSVCP140_1.dll', 'dxcore.dll', 'DirectML.dll')) {
        $result["system_$dll"] = Test-Path (Join-Path $env:SystemRoot "System32/$dll")
        $result["bundled_$dll"] = Test-Path (Join-Path (Split-Path $executable) $dll)
    }
    $process = Start-Process $executable -WorkingDirectory (Split-Path $executable) -PassThru -RedirectStandardOutput (Join-Path $evidence 'launch-stdout.log') -RedirectStandardError (Join-Path $evidence 'launch-stderr.log')
    if ($process.WaitForExit(15000)) {
        $result.launchExitCode = $process.ExitCode
        if ($process.ExitCode -ne 0) { throw "Application launch failed with exit code $($process.ExitCode)" }
    } else {
        $result.launchAliveAfter15Seconds = $true
        Stop-Process -Id $process.Id -Force
    }
    $result.passed = $true
} catch {
    $result.passed = $false
    $result.error = $_.Exception.Message
    $_ | Out-String | Set-Content (Join-Path $evidence 'error.log')
    throw
} finally {
    $result | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $evidence 'result.json')
    Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = (Get-Date).AddMinutes(-30) } -ErrorAction SilentlyContinue | Select-Object TimeCreated, Id, ProviderName, Message | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $evidence 'application-events.json')
}
