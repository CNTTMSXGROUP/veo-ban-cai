param([Parameter(Mandatory)][string]$Install, [Parameter(Mandatory)][string]$Qa)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or !$Qa.StartsWith($env:RUNNER_TEMP, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Chỉ thao tác cửa sổ trên máy Windows thử.'
}
$AppFile = Join-Path $Install 'msx-phong-dung.exe'
$Data = Join-Path $env:APPDATA 'vn.msxgroup.phongdung'
$Proof = Join-Path $Qa 'minh-chung'
New-Item -ItemType Directory -Path $Proof -Force | Out-Null
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -AssemblyName System.Windows.Forms
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class VeoQaWindow {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int L,T,R,B; }
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out Rect r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
}
'@

function Wait-Moc([scriptblock]$Predicate, [int]$Seconds, [string]$Message) {
    $Until = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $Value = & $Predicate
        if ($Value) { return $Value }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $Until)
    throw $Message
}
function Find-Ui([string]$Name, [switch]$ButtonPrefix, [switch]$Focusable) {
    $App.Refresh()
    if ($App.HasExited -or $App.MainWindowHandle -eq [IntPtr]::Zero) { return }
    try {
        $Window = [System.Windows.Automation.AutomationElement]::FromHandle($App.MainWindowHandle)
        $Condition = if ($ButtonPrefix) {
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
        } else {
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Name)
        }
        $Items = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $Condition)
        foreach ($Item in $Items) {
            if ($ButtonPrefix -and !([string]$Item.Current.Name).StartsWith($Name)) { continue }
            if ($Focusable -and !$Item.Current.IsKeyboardFocusable) { continue }
            if ($Item.Current.IsEnabled -and !$Item.Current.IsOffscreen) { return $Item }
        }
        foreach ($Item in $Items) {
            if ($ButtonPrefix -and !([string]$Item.Current.Name).StartsWith($Name)) { continue }
            if ($Focusable -and !$Item.Current.IsKeyboardFocusable) { continue }
            if ($Item.Current.IsEnabled) { return $Item }
        }
    } catch [System.Windows.Automation.ElementNotAvailableException] { return }
}
function Ui([string]$Name) { Wait-Moc { Find-Ui $Name } 15 "Không thấy điều khiển '$Name'." }
function Keys([string]$Key) { [System.Windows.Forms.SendKeys]::SendWait($Key) }
function Click-Ui($Item) {
    $Pattern = $null
    if ($Item.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$Pattern)) { $Pattern.Invoke(); return }
    if ($Item.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$Pattern)) { $Pattern.Toggle(); return }
    $Item.SetFocus()
    Keys '{ENTER}'
}
function Anh([string]$Name) {
    $App.Refresh()
    $Rect = [VeoQaWindow+Rect]::new()
    if (![VeoQaWindow]::GetWindowRect($App.MainWindowHandle, [ref]$Rect)) { return $false }
    $Image = [System.Drawing.Bitmap]::new(($Rect.R - $Rect.L), ($Rect.B - $Rect.T))
    $Graphics = [System.Drawing.Graphics]::FromImage($Image)
    try {
        $Dc = $Graphics.GetHdc()
        try { $Ok = [VeoQaWindow]::PrintWindow($App.MainWindowHandle, $Dc, 2) }
        finally { $Graphics.ReleaseHdc($Dc) }
        if (!$Ok -or $Image.GetPixel([int]($Image.Width / 2), 75).ToArgb() -eq 0) { return $false }
        $Image.Save((Join-Path $Proof "$Name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        return $true
    } finally { $Graphics.Dispose(); $Image.Dispose() }
}

function Dien([string]$Name, [string]$Value) {
    $Field = Wait-Moc { Find-Ui $Name -Focusable } 15 "Không thấy ô nhập '$Name'."
    $Field.SetFocus()
    Keys '^a'
    Keys $Value
    Keys '{TAB}'
}
$Firewall = "Veo-QA-WebView2-$env:GITHUB_RUN_ID"
$env:WEBVIEW2_USER_DATA_FOLDER = Join-Path $Qa 'webview2'
$Shell = New-Object -ComObject WScript.Shell
$App = $null
try {
    $App = Start-Process $AppFile -WorkingDirectory $Install -PassThru
    $null = Wait-Moc { Find-Ui 'Tiếp tục với Google' } 45 'Bộ cài chưa mở màn đăng nhập.'
    $Browser = Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" |
        Where-Object ParentProcessId -eq $App.Id | Select-Object -First 1
    if (!$Browser.ExecutablePath -or @((Get-NetFirewallProfile) | Where-Object Enabled -ne 'True').Count) {
        throw 'Chưa xác định được luật tường lửa cho WebView2 thử.'
    }
    # Chặn kết nối Internet trước khi tạo phiên tổng hợp. Phần dựng dùng 127.0.0.1.
    $Ranges = @('1.0.0.0-126.255.255.255','128.0.0.0-255.255.255.255','2000::/3')
    New-NetFirewallRule -Name $Firewall -DisplayName $Firewall -Enabled True -Direction Outbound -Action Block -Program $Browser.ExecutablePath -RemoteAddress $Ranges | Out-Null
    if (!(Get-NetFirewallRule -Name $Firewall -PolicyStore ActiveStore -ErrorAction SilentlyContinue)) {
        throw 'Luật ngoại tuyến chưa có hiệu lực.'
    }
    $PreviousWorker = Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
        Where-Object ParentProcessId -eq $App.Id | Select-Object -First 1
    if (!$App.CloseMainWindow() -or !$App.WaitForExit(10000)) {
        Stop-Process -Id $App.Id
        $App.WaitForExit()
    }
    if ($PreviousWorker) {
        $null = Wait-Moc {
            !(Get-Process -Id $PreviousWorker.ProcessId -ErrorAction SilentlyContinue)
        } 15 'Phần dựng từ lượt mở đầu chưa dừng.'
    }
    New-Item -ItemType Directory -Path $Data -Force | Out-Null
    @{refresh='veo-qa-khong-phai-token'; id='00000000-0000-4000-8000-000000000026'; email='veo-qa@example.invalid'; ten='Kho thử Windows'} |
        ConvertTo-Json -Compress | Set-Content -Encoding utf8 -LiteralPath (Join-Path $Data 'dang-nhap.json')
    $App = Start-Process $AppFile -WorkingDirectory $Install -PassThru
    $null = Wait-Moc {
        $Skip = Find-Ui 'Dùng ngay'
        if ($Skip) { Click-Ui $Skip }
        Find-Ui 'Tạo mới'
    } 65 'Không mở được kho thử trên Vèo.'
    if (!$Shell.AppActivate($App.Id)) { throw 'Không lấy được tiêu điểm cửa sổ thử.' }
    if ($Skip = Find-Ui 'Dùng ngay') { Click-Ui $Skip }
    Write-Host 'Đã vào Danh sách làm việc trong kho thử.'
    $null = Ui 'Vèo 0.3.24'
    $TaiNguyen = Join-Path $Data 'tai-nguyen'
    $MusicWait = [Diagnostics.Stopwatch]::StartNew()
    $null = Wait-Moc {
        (Test-Path (Join-Path $TaiNguyen 'kho-nhac-xong')) -and
            !(Test-Path (Join-Path $TaiNguyen 'kho-tam')) -and
            !(Test-Path (Join-Path $TaiNguyen 'kho-nhac-co-san.tar'))
    } 210 'Kho nhạc tải sẵn chưa nạp xong hoặc còn tệp giải nén.'
    $MusicWait.Stop()
    Write-Host 'Đã tải và nạp kho nhạc ở lần mở đầu.'

    Click-Ui (Ui 'Tạo mới')
    Click-Ui (Ui 'Từ ý tưởng / Storyboard')
    Dien 'Tên video' 'Storyboard Windows'
    Dien 'Chữ cảnh 1' 'Choose a story'
    Dien 'Số giây cảnh 1' '2'
    Click-Ui (Ui 'Tạo lời đọc')
    Dien 'Nội dung lời đọc' 'Welcome to the studio. First choose a story. Next bring it to life with a clear voice.'
    $Clock = [Diagnostics.Stopwatch]::StartNew()
    Click-Ui (Ui 'Tạo bản nghe thử')
    Write-Host 'Đã yêu cầu bản nghe thử bằng giọng tại máy.'
    $Apply = Wait-Moc { Find-Ui 'Dùng lời đọc và nới cảnh lên' -ButtonPrefix } 40 'Chưa thấy bản nghe thử để nới cảnh.'
    if ($Apply.Current.Name -notmatch 'lên ([0-9]+) giây$') { throw 'Không đọc được thời lượng đề xuất.' }
    $Seconds = [int]$Matches[1]
    if ($Seconds -le 2 -or $Seconds -gt 12) { throw 'Thời lượng đề xuất ngoài mức thử.' }
    $Clock.Stop()
    Click-Ui (Ui 'Phát âm thanh')
    $null = Wait-Moc { Find-Ui 'Tạm dừng' } 8 'Bản nghe thử chưa phát.'
    $null = Anh 'phat-loi-doc'
    Click-Ui (Ui 'Tạm dừng')
    $Apply = Wait-Moc { Find-Ui 'Dùng lời đọc và nới cảnh lên' -ButtonPrefix } 8 'Mất nút áp lời đọc.'
    Click-Ui $Apply
    $null = Ui 'Tạo lời đọc mới'
    $null = Anh 'loi-doc-da-vao-canh'
    Click-Ui (Ui 'Dựng video')
    $null = Wait-Moc { Find-Ui 'Xuất video' } 100 'Storyboard chưa dựng được.'
    Click-Ui (Ui 'Xuất video')
    Click-Ui (Ui '720p')
    Click-Ui (Ui 'Xuất 1 tệp')
    $Export = Wait-Moc {
        Get-ChildItem -LiteralPath (Join-Path $Data 'du-an') -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ChildItem -LiteralPath (Join-Path $_.FullName 'xuat') -File -Filter '*.mp4' -ErrorAction SilentlyContinue |
                Where-Object Length -gt 0 | Select-Object -First 1
        }
    } 120 'Chưa thấy MP4 do Vèo xuất.'
    $Probe = Join-Path $Install 'ffprobe.exe'
    $Streams = (& $Probe -v error -of json -show_entries 'stream=codec_name,codec_type,width,height,nb_frames' $Export.FullName | ConvertFrom-Json).streams
    if ($LASTEXITCODE -ne 0) { throw 'Không đọc được MP4.' }
    $Video = $Streams | Where-Object codec_type -eq 'video'
    $Audio = $Streams | Where-Object codec_type -eq 'audio'
    if ($Video.codec_name -ne 'h264' -or $Video.width -ne 1280 -or $Video.height -ne 720 -or [int]$Video.nb_frames -ne $Seconds * 30 -or $Audio.codec_name -ne 'aac') {
        throw ('MP4 không khớp storyboard: ' + ($Streams | ConvertTo-Json -Compress))
    }
    $Measure = (& (Join-Path $Install 'ffmpeg.exe') -v info -i $Export.FullName -vn -af volumedetect -f null - 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $Measure -notmatch 'mean_volume: ([-.0-9]+) dB' -or [double]$Matches[1] -lt -38) {
        throw 'MP4 chưa có lời đọc đủ mức để kiểm.'
    }
    Copy-Item -LiteralPath $Export.FullName -Destination (Join-Path $Proof 'storyboard-windows.mp4')
    @{
        source=$env:VEO_QA_SOURCE; sha=$env:VEO_QA_WORKER_SHA; os=$env:VEO_QA_OS;
        sceneSecondsBefore=2; sceneSecondsAfter=$Seconds; auditionPlayed=$true;
        previewMs=$Clock.ElapsedMilliseconds; streams=$Streams; meanDb=[double]$Matches[1]
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Proof 'ket-qua-storyboard.json') -Encoding utf8
    Write-Host "Đã phát thử lời đọc, nới cảnh từ 2 lên $Seconds giây và xuất MP4."
} catch {
    if ($App -and !$App.HasExited) { $null = Anh 'loi' }
    $Roots = @($Data, (Join-Path $env:LOCALAPPDATA 'vn.msxgroup.phongdung'))
    $Log = Get-ChildItem -LiteralPath $Roots -Recurse -File -Filter 'phan-dung.log' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($Log) { Copy-Item -LiteralPath $Log.FullName -Destination (Join-Path $Proof 'phan-dung.log') }
    throw
} finally {
    if ($App -and !$App.HasExited) { Stop-Process -Id $App.Id }
    Remove-NetFirewallRule -Name $Firewall -ErrorAction SilentlyContinue
}
