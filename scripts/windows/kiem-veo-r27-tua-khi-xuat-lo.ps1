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
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int x, int y, uint data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
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
function Find-Ui([string]$Name, [switch]$ButtonPrefix, [switch]$TextPrefix, [switch]$Focusable) {
    $App.Refresh()
    if ($App.HasExited -or $App.MainWindowHandle -eq [IntPtr]::Zero) { return }
    try {
        $Window = [System.Windows.Automation.AutomationElement]::FromHandle($App.MainWindowHandle)
        $Condition = if ($ButtonPrefix -or $TextPrefix) {
            $Type = if ($ButtonPrefix) { [System.Windows.Automation.ControlType]::Button } else { [System.Windows.Automation.ControlType]::Text }
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ControlTypeProperty, $Type)
        } else {
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Name)
        }
        $Items = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants, $Condition)
        foreach ($Item in $Items) {
            if (($ButtonPrefix -or $TextPrefix) -and !([string]$Item.Current.Name).StartsWith($Name)) { continue }
            if ($Focusable -and !$Item.Current.IsKeyboardFocusable) { continue }
            if ($Item.Current.IsEnabled -and !$Item.Current.IsOffscreen) { return $Item }
        }
        foreach ($Item in $Items) {
            if (($ButtonPrefix -or $TextPrefix) -and !([string]$Item.Current.Name).StartsWith($Name)) { continue }
            if ($Focusable -and !$Item.Current.IsKeyboardFocusable) { continue }
            if ($Item.Current.IsEnabled) { return $Item }
        }
    } catch [System.Windows.Automation.ElementNotAvailableException] { return }
    catch {
        if ($_.Exception.ToString() -match '0x80010012') { return }
        throw
    }
}
function Ui([string]$Name) { Wait-Moc { Find-Ui $Name } 15 "Không thấy điều khiển '$Name'." }
function Keys([string]$Key) { [System.Windows.Forms.SendKeys]::SendWait($Key) }
function Click-Ui($Item) {
    $Item.SetFocus()
    Start-Sleep -Milliseconds 220
    Mouse-Ui $Item
}
function Mouse-Ui($Item, [double]$X=.5) {
    $Rect = $Item.Current.BoundingRectangle
    if ($Rect.Width -le 0 -or $Rect.Height -le 0) { throw 'Điều khiển không nằm trên cửa sổ.' }
    if (![VeoQaWindow]::SetCursorPos([int]($Rect.X + $Rect.Width*$X), [int]($Rect.Y + $Rect.Height / 2))) { throw 'Không đặt được con trỏ trên máy thử.' }
    [VeoQaWindow]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)
    [VeoQaWindow]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)
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

function Choose-File([string]$Title, [string]$Path) {
    $null = Wait-Moc {
        $Root = [System.Windows.Automation.AutomationElement]::RootElement
        $Name = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, $Title)
        $Window = $Root.FindFirst([System.Windows.Automation.TreeScope]::Children, $Name)
        if ($Window -and $Window.Current.ProcessId -eq $App.Id) { $Window }
    } 25 "Không thấy hộp $Title."
    Keys '%n'
    Keys $Path
    Keys '{ENTER}'
}
function Has-Frame([bool]$Blue) {
    $Rect = [VeoQaWindow+Rect]::new()
    if (![VeoQaWindow]::GetWindowRect($App.MainWindowHandle, [ref]$Rect)) { return $false }
    $Width = $Rect.R - $Rect.L
    $Height = $Rect.B - $Rect.T
    $Image = [System.Drawing.Bitmap]::new($Width, $Height)
    $Graphics = [System.Drawing.Graphics]::FromImage($Image)
    try {
        $Dc = $Graphics.GetHdc()
        try { $Ok = [VeoQaWindow]::PrintWindow($App.MainWindowHandle, $Dc, 2) }
        finally { $Graphics.ReleaseHdc($Dc) }
        if (!$Ok) { return $false }
        $N = 0
        for ($Y=[int]($Height*.20); $Y -lt $Height*.55; $Y+=12) {
            for ($X=[int]($Width*.30); $X -lt $Width*.70; $X+=12) {
                $C = $Image.GetPixel($X,$Y)
                if ($C.R -lt 45 -and (($Blue -and $C.B -gt 200 -and $C.G -lt 45) -or (!$Blue -and $C.G -gt 200 -and $C.B -lt 45))) {
                    if (++$N -ge 18) { return $true }
                }
            }
        }
        return $false
    } finally { $Graphics.Dispose(); $Image.Dispose() }
}
function Seek-Frame([bool]$Blue) {
    $Seek = Ui 'Tua video'
    $At = if ($Blue) { .70 } else { .25 }
    $Clock = [Diagnostics.Stopwatch]::StartNew()
    Mouse-Ui $Seek $At
    do {
        if (Has-Frame $Blue) { return [math]::Round($Clock.Elapsed.TotalMilliseconds, 1) }
        Start-Sleep -Milliseconds 8
    } while ($Clock.ElapsedMilliseconds -lt 7000)
    throw "Không thấy khung hình sau thao tác tua. Tỷ lệ vị trí $At."
}
function Seek-Sample {
    $null = Seek-Frame $false
    $Times = @(for ($I=0; $I -lt 30; $I++) { Seek-Frame ($I % 2 -eq 0) })
    $Sort = @($Times | Sort-Object)
    return [ordered]@{ ms=$Times; p50=[math]::Round(($Sort[14]+$Sort[15])/2,1); p95=$Sort[28] }
}
function Proxy-Count {
    return @(Get-ChildItem -LiteralPath (Join-Path $ReferenceDir 'xem') -File -Filter 'doan-*.mp4' -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match '^doan-[a-f0-9]{24}\.mp4$' -and (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($_.FullName, '.wav')))
    }).Count
}
function Running-Exports {
    return @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" | Where-Object {
        $_.CommandLine -like "*$Data*" -and $_.CommandLine -match '(?i)[/\\]\.dang-xuat-'
    }).Count
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

    $FFmpeg = Join-Path $Install 'ffmpeg.exe'
    $Probe = Join-Path $Install 'ffprobe.exe'
    $Source = Join-Path $Proof 'QA Tua 0.mp4'
    $Filter = "hue=s=0,drawbox=x=0:y=0:w=iw:h=ih/2:color=0x00ff00:t=fill:enable='lt(t,50)',drawbox=x=0:y=0:w=iw:h=ih/2:color=0x0000ff:t=fill:enable='gte(t,50)'"
    & $FFmpeg -v error -f lavfi -i 'testsrc2=s=640x360:r=30:d=120' -f lavfi -i 'sine=f=431:r=48000:d=120' -vf $Filter -t 120 -c:v libx264 -threads 2 -preset ultrafast -c:a aac $Source
    if ($LASTEXITCODE -ne 0) { throw 'Không tạo được clip thử 120 giây.' }
    $Short = Join-Path $Qa 'mau-lo-45-giay.mp4'
    & $FFmpeg -v error -i $Source -t 45 -c copy $Short
    if ($LASTEXITCODE -ne 0) { throw 'Không cắt được mẫu 45 giây cho lô xuất.' }

    Mouse-Ui (Ui 'Ngang 16:9')
    Click-Ui (Ui 'Cài dựng clip mới')
    $Picker = Wait-Moc { Find-Ui 'Cách dựng clip mới' -Focusable } 15 'Không tìm được cách dựng.'
    $Picker.SetFocus()
    Keys '{DOWN}'
    $null = Ui 'Theo hình'
    Keys '{HOME}{DOWN 2}{ENTER}'
    $null = Ui 'Vèo tìm điểm đổi cảnh tại máy. Có thể lấy lại mép đen đã rút trong Chỉnh nhanh → Cảnh.'
    Click-Ui (Ui 'Xong')
    foreach ($I in 0..3) {
        $Path = if ($I -eq 0) { $Source } else { Join-Path $Qa "QA Tua $I.mp4" }
        if ($I -ne 0) { Copy-Item -LiteralPath $Short -Destination $Path }
        Mouse-Ui (Ui 'Thả clip quay thô')
        Choose-File 'Chọn clip quay thô' $Path
        $Row = Wait-Moc { Find-Ui "Xem QA Tua $I" -Focusable } 60 "Chưa thấy dự án QA Tua $I."
        Mouse-Ui $Row
        $null = Wait-Moc { Find-Ui 'Xuất video' -Focusable } 150 "Dựng QA Tua $I quá thời gian."
        if ($I -eq 0) {
            $Reference = @(Get-ChildItem -LiteralPath (Join-Path $Data 'du-an') -Directory)
            if ($Reference.Count -ne 1) { throw 'Chưa xác định được kho của clip dùng để đo tua.' }
            $ReferenceDir = $Reference[0].FullName
        }
        Write-Host "Đã nhập và dựng QA Tua $I."
    }

    Mouse-Ui (Ui 'Xem QA Tua 0')
    Click-Ui (Ui 'Sửa tay')
    Click-Ui (Ui 'Xem rộng')
    $BeforeWarm = Proxy-Count
    $null = Seek-Frame $true
    $BlueReady = Wait-Moc { if (($N = Proxy-Count) -gt $BeforeWarm) { $N } } 35 'Chưa chuẩn bị được đoạn xanh lam.'
    $null = Seek-Frame $false
    $WarmSegments = Wait-Moc { if (($N = Proxy-Count) -gt $BlueReady) { $N } } 35 'Chưa chuẩn bị được đoạn xanh lục.'
    $Idle = Seek-Sample
    $null = Anh '01-tua-khi-may-ranh'
    Write-Host "Đo xong 30 lượt khi rảnh. P95 $($Idle.p95) ms."
    Mouse-Ui (Ui 'Tự động')
    Click-Ui (Ui 'Chọn nhiều')
    foreach ($I in 1..3) { Click-Ui (Ui "Chọn QA Tua $I") }
    (Ui 'Xuất 3 video đã chọn').SetFocus()
    Keys '{ENTER}'
    $null = Ui 'Video trong lô'
    Click-Ui (Ui '720p')
    $null = Anh '02-xuat-3-video-duoc-chon'
    $Batch = [Diagnostics.Stopwatch]::StartNew()
    Click-Ui (Ui 'Xuất 3 tệp')
    $null = Wait-Moc { Running-Exports } 30 'Không thấy tiến trình FFmpeg đang xuất.'
    Click-Ui (Ui 'Sửa tay')
    Click-Ui (Ui 'Xem rộng')
    $BeforeCount = Running-Exports
    $Busy = Seek-Sample
    $AfterCount = Running-Exports
    if (!$BeforeCount -or !$AfterCount) { throw 'Lô đã kết thúc trước khi đủ 30 lượt tua.' }
    $null = Anh '03-tua-khi-lo-dang-xuat'
    Write-Host "Đo xong 30 lượt khi đang xuất. P95 $($Busy.p95) ms."

    $Outputs = Wait-Moc {
        $Found = @(Get-ChildItem -LiteralPath (Join-Path $Data 'du-an') -Directory | ForEach-Object {
            Get-ChildItem -LiteralPath (Join-Path $_.FullName 'xuat') -File -Filter '*.mp4' -ErrorAction SilentlyContinue
        })
        if ($Found.Count -gt 3) { throw 'Lô tạo dư MP4.' }
        if ($Found.Count -eq 3 -and !(Running-Exports)) { ,$Found }
    } 420 'Chưa giao đủ ba MP4.'
    $Batch.Stop()
    foreach ($I in 1..3) {
        if (@($Outputs | Where-Object Name -match "^QA[ _-]Tua[ _-]$I(\D|$)").Count -ne 1) { throw "Lô chưa giao đúng QA Tua $I." }
    }
    $Files = @(foreach ($Output in $Outputs) {
        $Streams = (& $Probe -v error -show_entries 'stream=codec_name,width,height,nb_frames' -of json $Output.FullName | ConvertFrom-Json).streams
        $Video = $Streams | Where-Object codec_name -eq h264
        if ($LASTEXITCODE -ne 0 -or $Video.width -ne 1280 -or $Video.height -ne 720 -or $Video.nb_frames -ne '1350' -or 'aac' -notin $Streams.codec_name) {
            throw "MP4 $($Output.Name) có sai định dạng hoặc thời lượng."
        }
        [ordered]@{ name=$Output.Name; sha256=(Get-FileHash -LiteralPath $Output.FullName).Hash.ToLowerInvariant(); video=$Video; bytes=$Output.Length }
    })
    Mouse-Ui (Ui 'Tự động')
    Mouse-Ui (Ui 'Xem QA Tua 1')
    $null = Ui 'Thành phẩm'
    Keys '%{F4}'
    if (!$App.WaitForExit(15000)) { throw 'Vèo chưa đóng.' }
    $App = Start-Process $AppFile -WorkingDirectory $Install -PassThru
    $null = Wait-Moc { Find-Ui 'Xem QA Tua 1' } 70 'Vèo mở lại chưa thấy dự án.'
    if (!$Shell.AppActivate($App.Id)) { throw 'Không lấy được tiêu điểm sau khi mở lại.' }
    Mouse-Ui (Ui 'Xem QA Tua 1')
    $null = Ui 'Thành phẩm'
    Mouse-Ui (Ui 'Phát')
    $null = Wait-Moc { Find-Ui 'Dừng' } 8 'Không phát được MP4 sau khi mở lại.'
    $null = Anh '04-phat-mp4-sau-khi-mo-lai'
    foreach ($I in 0..2) {
        if ((Get-FileHash -LiteralPath $Outputs[$I].FullName).Hash -ne $Files[$I].sha256) { throw 'MP4 đổi sau khi mở lại.' }
    }
    $Example = $Outputs | Where-Object Name -match '^QA[ _-]Tua[ _-]1(\D|$)'
    Copy-Item -LiteralPath $Example.FullName -Destination (Join-Path $Proof 'thanh-pham.mp4')
    [ordered]@{
        source=$env:VEO_QA_SOURCE; workerSha256=$env:VEO_QA_WORKER_SHA; system=$env:VEO_QA_OS
        machineRamBytes=(Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory
        logicalCpus=[Environment]::ProcessorCount
        idle=$Idle; exporting=$Busy; proxySegmentsBeforeMeasurement=$WarmSegments
        ffmpegProcessesAtStart=$BeforeCount; ffmpegProcessesAtEnd=$AfterCount
        verifiedBatchMs=$Batch.ElapsedMilliseconds; reopenedAndPlayed=$true; outputs=$Files
    } | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $Proof 'ket-qua.json')
} catch {
    if ($App -and !$App.HasExited) {
        $null = Anh 'loi'
        try {
            $Win = [System.Windows.Automation.AutomationElement]::FromHandle($App.MainWindowHandle)
            $Nodes = $Win.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
            $Nodes | Where-Object { $_.Current.Name -and $_.Current.IsKeyboardFocusable } |
                ForEach-Object { $_.Current.Name } | Sort-Object -Unique |
                Set-Content -Encoding utf8 -LiteralPath (Join-Path $Proof 'dieu-khien-khi-loi.txt')
        } catch { Write-Host 'Không đọc được danh sách điều khiển khi dừng ca.' }
    }
    $Roots = @($Data, (Join-Path $env:LOCALAPPDATA 'vn.msxgroup.phongdung'))
    $Log = Get-ChildItem -LiteralPath $Roots -Recurse -File -Filter 'phan-dung.log' -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($Log) { Copy-Item -LiteralPath $Log.FullName -Destination (Join-Path $Proof 'phan-dung.log') }
    throw
} finally {
    if ($App -and !$App.HasExited) { Stop-Process -Id $App.Id }
    Remove-NetFirewallRule -Name $Firewall -ErrorAction SilentlyContinue
}
