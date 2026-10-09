param([switch]$NotificationControl)

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
    validationProcessArchitecture = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
}
$desktopDiagnosticsReady = $false
$wingetBootstrapped = $false

if ($NotificationControl) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count) { throw 'Could not parse the native notification probe' }
    $definition = $tokens | Where-Object {
        $_.Kind -eq [System.Management.Automation.Language.TokenKind]::HereStringLiteral -and $_.Value -like '*public static class DesktopShell*'
    }
    Add-Type -TypeDefinition $definition.Value -ErrorAction Stop
    $result.notificationControlWithoutTargetApp = $true
    $result.sessionId = (Get-Process -Id $PID).SessionId
    $result.userInteractive = [Environment]::UserInteractive
    $result.windowStation = [DesktopShell]::ObjectName([DesktopShell]::GetProcessWindowStation())
    $result.desktop = [DesktopShell]::ObjectName([DesktopShell]::GetThreadDesktop([DesktopShell]::GetCurrentThreadId()))
    $result.trayAvailableInitially = [DesktopShell]::FindWindow('Shell_TrayWnd', $null) -ne [IntPtr]::Zero
    $result.systemTrayProbe = [DesktopShell]::ProbeNotification()
    $result.passed = $result.systemTrayProbe.Added
    $result | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $evidence 'result.json')
    if (-not $result.passed) { throw 'Native notification control failed without target app or bootstrap changes' }
    exit 0
}

try {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        if ([Environment]::OSVersion.Version.Build -lt 22000) {
            Import-Module Appx -UseWindowsPowerShell
        }
        $existing = Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue | Where-Object {
            $_.PackageFullName -like "*_$($env:TARGET_ARCHITECTURE)_*"
        } | Sort-Object Version -Descending | Select-Object -First 1
        if ($existing -and (Test-Path (Join-Path $existing.InstallLocation 'winget.exe'))) {
            $result.imageAppInstallerPackage = $existing.PackageFullName
            Add-AppxPackage -Register (Join-Path $existing.InstallLocation 'AppxManifest.xml') -DisableDevelopmentMode
            $env:PATH = "$($existing.InstallLocation);$env:PATH"
            $result.wingetBootstrapMode = 'registered image package'
        }
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        # Preserve Runtime1.8 on ARM; Server2022 needs the proven licensed client.
        $wingetReleaseTag = if ($env:TARGET_ARCHITECTURE -eq 'arm64') { 'v1.11.430' } else { 'v1.29.380' }
        $release = Invoke-RestMethod "https://api.github.com/repos/microsoft/winget-cli/releases/tags/$wingetReleaseTag" -Headers @{ Authorization = "Bearer $env:GITHUB_TOKEN" }
        $result.wingetBootstrapMode = "official stable $wingetReleaseTag"
        $bundle = Join-Path $env:RUNNER_TEMP 'DesktopAppInstaller.msixbundle'
        $dependenciesZip = Join-Path $env:RUNNER_TEMP 'DesktopAppInstaller_Dependencies.zip'
        $license = Join-Path $env:RUNNER_TEMP 'DesktopAppInstaller_License1.xml'
        $bundleAsset = $release.assets | Where-Object name -eq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
        $dependenciesAsset = $release.assets | Where-Object name -eq 'DesktopAppInstaller_Dependencies.zip'
        $licenseAsset = @($release.assets | Where-Object name -like '*_License1.xml')
        if ($licenseAsset.Count -ne 1) { throw 'Expected the official release offline license' }
        Invoke-WebRequest $bundleAsset.browser_download_url -OutFile $bundle
        Invoke-WebRequest $dependenciesAsset.browser_download_url -OutFile $dependenciesZip
        Invoke-WebRequest $licenseAsset[0].browser_download_url -OutFile $license
        $result.wingetLicenseAsset = $licenseAsset[0].name
        $result.wingetLicenseSha256 = (Get-FileHash $license -Algorithm SHA256).Hash
        if ($result.wingetLicenseSha256 -ne 'BCB15118EC47DF24E3E6013A7006147C3A15B3A8104ED660FE87C8B4ED01F485') {
            throw 'Official WinGet release license hash mismatch'
        }
        $dependenciesDirectory = Join-Path $env:RUNNER_TEMP 'winget-dependencies'
        Expand-Archive $dependenciesZip $dependenciesDirectory
        $dependencies = @(Get-ChildItem $dependenciesDirectory -Recurse -File | Where-Object {
            $_.Extension -in @('.appx', '.msix') -and $_.FullName -match "[\\/]$($env:TARGET_ARCHITECTURE)[\\/]"
        } | Select-Object -ExpandProperty FullName)
        if ($dependencies.Count -eq 0) { throw 'No native WinGet dependency packages found' }
        if ([Environment]::OSVersion.Version.Build -lt 22000) {
            Import-Module Appx -UseWindowsPowerShell
        }
        foreach ($dependency in $dependencies) {
            $identity = [regex]::Match((Split-Path $dependency -Leaf), '^(?<name>.+)_(?<version>\d+(?:\.\d+){3})_(?<arch>[^_]+)\.(?:appx|msix)$')
            $satisfied = $null
            if ($identity.Success) {
                $satisfied = Get-AppxPackage -Name $identity.Groups['name'].Value -ErrorAction SilentlyContinue | Where-Object {
                    $_.PackageFullName -like "*_$($env:TARGET_ARCHITECTURE)_*" -and [version]$_.Version -ge [version]$identity.Groups['version'].Value
                }
            }
            if ($satisfied) {
                $result.wingetFrameworksReused = @($result.wingetFrameworksReused) + (Split-Path $dependency -Leaf)
            } else {
                Add-AppxPackage -Path $dependency -ForceApplicationShutdown
            }
        }
        if ([Environment]::OSVersion.Version.Build -lt 22000) {
            # Provision the signed Store license before registering the current user.
            # DISM accepts repeated dependency arguments without WinPS array remoting.
            $provisionDependencies = @(Get-ChildItem $dependenciesDirectory -Recurse -File | Where-Object {
                $_.Extension -in @('.appx', '.msix') -and $_.FullName -match '[\\/](x64|x86)[\\/]'
            } | Select-Object -ExpandProperty FullName)
            $provisionArgs = @('/Online', '/Add-ProvisionedAppxPackage', "/PackagePath:$bundle", "/LicensePath:$license", '/Region:all')
            foreach ($dependency in $provisionDependencies) {
                $provisionArgs += "/DependencyPackagePath:$dependency"
            }
            & dism.exe @provisionArgs | Tee-Object -FilePath (Join-Path $evidence 'winget-provision.log')
            $result.wingetProvisionExitCode = $LASTEXITCODE
            if ($LASTEXITCODE -ne 0) { throw 'Official WinGet package/license provisioning failed' }
        }
        Add-AppxPackage -Path $bundle -ForceApplicationShutdown
        $installation = Get-AppxPackage -Name Microsoft.DesktopAppInstaller
        if (-not $installation) { throw 'WinGet package was not registered' }
        $env:PATH = "$($installation.InstallLocation);$env:PATH"
        $wingetBootstrapped = $true
    }
    foreach ($credential in @('GITHUB_TOKEN', 'GH_TOKEN', 'ACTIONS_RUNTIME_TOKEN', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN')) {
        Remove-Item -LiteralPath "Env:$credential" -ErrorAction SilentlyContinue
    }
    $result.githubTokenRemovedBeforeLaunch = -not (Test-Path Env:GITHUB_TOKEN)
    $wingetExecutable = (Get-Command winget -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $result.wingetExecutable = $wingetExecutable
    & $wingetExecutable --info
    if ($LASTEXITCODE -ne 0) { throw 'winget bootstrap failed' }
    & $wingetExecutable settings --enable LocalManifestFiles
    if ($LASTEXITCODE -ne 0) { throw 'Could not enable local manifest validation' }
    & $wingetExecutable validate --manifest $manifest
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

    & $wingetExecutable install --manifest $manifest --silent --accept-source-agreements --accept-package-agreements --disable-interactivity --log (Join-Path $evidence 'winget-install.log')
    $result.installExitCode = $LASTEXITCODE
    if ($LASTEXITCODE -ne 0) { throw 'Manifest installation failed' }
    $executable = Join-Path $env:ProgramFiles 'zerolaunch-rs/zerolaunch-rs.exe'
    if (-not (Test-Path $executable)) { throw "Installed executable missing: $executable" }
    Get-ChildItem (Split-Path $executable) -File | Select-Object Name, Length | ConvertTo-Json | Set-Content (Join-Path $evidence 'installed-files.json')
    foreach ($dll in @('MSVCP140.dll', 'MSVCP140_1.dll', 'dxcore.dll', 'DirectML.dll')) {
        $result["system_$dll"] = Test-Path (Join-Path $env:SystemRoot "System32/$dll")
        $result["bundled_$dll"] = Test-Path (Join-Path (Split-Path $executable) $dll)
    }
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class DesktopShell {
    [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "FindWindowW")]
    public static extern IntPtr FindWindow(string className, string windowName);
    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
    [DllImport("user32.dll")]
    public static extern IntPtr GetProcessWindowStation();
    [DllImport("user32.dll")]
    public static extern IntPtr GetThreadDesktop(uint threadId);
    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool GetUserObjectInformation(IntPtr handle, int index, System.Text.StringBuilder value, int length, out int needed);
    public static string ObjectName(IntPtr handle) {
        var value = new System.Text.StringBuilder(256);
        int needed;
        return GetUserObjectInformation(handle, 2, value, value.Capacity * 2, out needed) ? value.ToString() : null;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowEx(uint styleEx, string className, string windowName, uint style, int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr parameter);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyWindow(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr LoadIcon(IntPtr instance, IntPtr iconName);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool Shell_NotifyIcon(uint message, ref NotifyIconData data);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData {
        public uint size;
        public IntPtr window;
        public uint id;
        public uint flags;
        public uint callback;
        public IntPtr icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string tip;
        public uint state;
        public uint stateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string info;
        public uint timeoutOrVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string infoTitle;
        public uint infoFlags;
        public Guid guid;
        public IntPtr balloonIcon;
    }
    public sealed class TrayProbeResult {
        public bool WindowCreated { get; set; }
        public bool IconLoaded { get; set; }
        public bool Added { get; set; }
        public int NativeError { get; set; }
        public int NativeDataSize { get; set; }
    }
    public static TrayProbeResult ProbeNotification() {
        var result = new TrayProbeResult();
        var window = CreateWindowEx(0, "STATIC", "ZeroLaunch validation probe", 0, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        result.WindowCreated = window != IntPtr.Zero;
        if (!result.WindowCreated) {
            result.NativeError = Marshal.GetLastWin32Error();
            return result;
        }
        var data = new NotifyIconData();
        data.size = (uint)Marshal.SizeOf(typeof(NotifyIconData));
        data.window = window;
        data.id = 1;
        data.flags = 2 | 4;
        data.icon = LoadIcon(IntPtr.Zero, new IntPtr(32512));
        result.IconLoaded = data.icon != IntPtr.Zero;
        data.tip = "ZeroLaunch validation probe";
        result.NativeDataSize = (int)data.size;
        try {
            result.Added = Shell_NotifyIcon(0, ref data);
            result.NativeError = result.Added ? 0 : Marshal.GetLastWin32Error();
            return result;
        } finally {
            if (result.Added) { Shell_NotifyIcon(2, ref data); }
            DestroyWindow(window);
        }
    }
}
'@
    $desktopDiagnosticsReady = $true
    $result.sessionId = (Get-Process -Id $PID).SessionId
    $result.userInteractive = [Environment]::UserInteractive
    $result.windowStation = [DesktopShell]::ObjectName([DesktopShell]::GetProcessWindowStation())
    $result.desktop = [DesktopShell]::ObjectName([DesktopShell]::GetThreadDesktop([DesktopShell]::GetCurrentThreadId()))
    $result.trayAvailableInitially = [DesktopShell]::FindWindow('Shell_TrayWnd', $null) -ne [IntPtr]::Zero
    if ($wingetBootstrapped -and $env:TARGET_ARCHITECTURE -eq 'arm64') {
        # Updating the WinGet frameworks can close dependent desktop components.
        # Restore the actual Explorer shell before the first app launch.
        Get-Process explorer -ErrorAction SilentlyContinue | Where-Object SessionId -eq $result.sessionId | Stop-Process -Force
        $result.explorerRestartedAfterBootstrap = $true
    }
    if (-not $result.trayAvailableInitially -or $result.explorerRestartedAfterBootstrap) {
        Start-Process explorer.exe
        $deadline = (Get-Date).AddSeconds(20)
        while ([DesktopShell]::FindWindow('Shell_TrayWnd', $null) -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 200
        }
    }
    $result.trayAvailableAtLaunch = [DesktopShell]::FindWindow('Shell_TrayWnd', $null) -ne [IntPtr]::Zero
    $trayProcess = [uint32]0
    [DesktopShell]::GetWindowThreadProcessId([DesktopShell]::FindWindow('Shell_TrayWnd', $null), [ref]$trayProcess) | Out-Null
    $result.trayProcessId = $trayProcess
    $result.explorerProcesses = @(Get-Process explorer -ErrorAction SilentlyContinue | Where-Object SessionId -eq $result.sessionId | Select-Object Id, SessionId, Responding)
    $env:RUST_BACKTRACE = 'full'
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
    if ($desktopDiagnosticsReady) {
        # Probe the real notification API only after the app attempt; this cannot
        # prepare the desktop for its first launch or replace a failed result.
        try { $result.systemTrayProbeAfterLaunch = [DesktopShell]::ProbeNotification() }
        catch { $result.systemTrayProbeError = $_.Exception.Message }
    }
    $applicationLogs = Join-Path $env:APPDATA 'ZeroLaunch-rs/logs'
    if (Test-Path $applicationLogs) {
        $logsDestination = Join-Path $evidence 'application-logs'
        New-Item -ItemType Directory -Path $logsDestination -Force | Out-Null
        Get-ChildItem $applicationLogs -File -ErrorAction SilentlyContinue | Copy-Item -Destination $logsDestination -ErrorAction Continue
    }
    $result | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $evidence 'result.json')
    Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = (Get-Date).AddMinutes(-30) } -ErrorAction SilentlyContinue | Select-Object TimeCreated, Id, ProviderName, Message | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $evidence 'application-events.json')
}
