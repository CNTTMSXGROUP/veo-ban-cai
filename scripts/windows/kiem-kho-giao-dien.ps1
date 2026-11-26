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

    function Loc-Mau([string]$KeysForOption, [string]$Sample) {
        $Picker = Wait-Moc { Find-Ui 'Thể loại' -Focusable } 15 'Không thấy bộ lọc thể loại.'
        $Picker.SetFocus()
        Keys '{DOWN}'
        $null = Ui 'Tất cả'
        Keys $KeysForOption
        return Ui "Xem thử $Sample"
    }

    Click-Ui (Ui 'Kho phong cách')
    $Pixel = Loc-Mau '{END}{ENTER}' 'Pixel retro'
    if (Find-Ui 'Xem thử Bản tin đồ họa') { throw 'Kho chưa lọc theo thể loại Pixel.' }
    Click-Ui $Pixel
    $null = Ui 'Đèn hiệu cuối đảo'
    Click-Ui (Ui 'Phát video')
    $null = Wait-Moc { Find-Ui 'Tạm dừng' } 10 'Phim mẫu Pixel chưa phát.'
    $null = Anh 'phim-mau-pixel'
    Click-Ui (Ui 'Tạm dừng')
    Write-Host 'Đã lọc Pixel và phát phim mẫu.'
    Click-Ui (Ui 'Chọn dùng')
    Click-Ui (Ui 'Tạo video theo mẫu')
    Click-Ui (Ui 'Dùng kịch bản mẫu')
    Click-Ui (Ui 'Dựng video')
    $null = Wait-Moc { Find-Ui 'Xuất video' } 120 'Storyboard Pixel chưa dựng xong.'
    $null = Anh 'storyboard-pixel'
    Write-Host 'Đã tạo video từ kịch bản của mẫu Pixel.'

    Click-Ui (Ui 'Kho phong cách')
    $null = Loc-Mau '{HOME}{DOWN 4}{ENTER}' 'Bản tin đồ họa'
    if (Find-Ui 'Xem thử Pixel retro') { throw 'Kho chưa lọc theo thể loại Bản tin.' }
    Click-Ui (Ui 'Chọn dùng')
    Click-Ui (Ui 'Áp vào video đang mở')
    $null = Ui 'So bộ kiểu'
    $null = Ui 'Bản đang dùng'
    $null = Ui 'Sau khi áp'
    $Apply = Ui 'Áp bộ kiểu'
    $null = Anh 'so-bo-kieu-ban-tin'
    Click-Ui $Apply
    $null = Wait-Moc { Find-Ui 'Đã áp bộ kiểu Bản tin đồ họa.' } 10 'Không thấy thông báo áp bộ kiểu.'
    Write-Host 'Đã xem trước thay đổi và áp bộ kiểu Bản tin.'

    Click-Ui (Ui 'Xuất video')
    Click-Ui (Ui '720p')
    Click-Ui (Ui 'Xuất 1 tệp')
    $Export = Wait-Moc {
        Get-ChildItem -LiteralPath (Join-Path $Data 'du-an') -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ChildItem -LiteralPath (Join-Path $_.FullName 'xuat') -File -Filter '*.mp4' -ErrorAction SilentlyContinue |
                Where-Object Length -gt 0 | Select-Object -First 1
        }
    } 130 'Chưa thấy MP4 do Vèo xuất.'
    $Probe = Join-Path $Install 'ffprobe.exe'
    $Streams = (& $Probe -v error -of json -show_entries 'stream=codec_name,codec_type,width,height,nb_frames' $Export.FullName | ConvertFrom-Json).streams
    if ($LASTEXITCODE -ne 0) { throw 'Không đọc được MP4.' }
    $Video = $Streams | Where-Object codec_type -eq 'video'
    if ($Video.codec_name -ne 'h264' -or $Video.width -ne 720 -or $Video.height -ne 720 -or [int]$Video.nb_frames -ne 480) {
        throw ('MP4 không khớp video Pixel 16 giây: ' + ($Streams | ConvertTo-Json -Compress))
    }
    Copy-Item -LiteralPath $Export.FullName -Destination (Join-Path $Proof 'tao-pixel-ap-ban-tin.mp4')
    @{
        source=$env:VEO_QA_SOURCE; sha=$env:VEO_QA_WORKER_SHA; os=$env:VEO_QA_OS;
        sample='pixel'; samplePlayed=$true; createdFromSample=$true; comparedAndApplied='ban-tin';
        streams=$Streams; screenshots=@(Get-ChildItem $Proof -Filter '*.png' | Select-Object -ExpandProperty Name)
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Proof 'ket-qua-kho-giao-dien.json') -Encoding utf8
    Write-Host 'Đã xuất MP4 720 x 720 dài 480 khung sau khi áp bộ kiểu.'
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
