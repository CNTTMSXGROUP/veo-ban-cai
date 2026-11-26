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

function Dien([string]$Name, [string]$Value) {
    $Field = Wait-Moc { Find-Ui $Name -Focusable } 15 "Không thấy ô nhập '$Name'."
    $Field.SetFocus()
    Keys '^a'
    Keys $Value
    Keys '{TAB}'
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
function Read-Color([string]$Path, [double]$X, [double]$Y) {
    $Image = [System.Drawing.Bitmap]::new($Path)
    try {
        $Cx = [int]($Image.Width*$X)
        $Cy = [int]($Image.Height*$Y)
        $Totals = @(0,0,0)
        for ($dy=-4; $dy -le 4; $dy++) {
            for ($dx=-4; $dx -le 4; $dx++) {
                $c = $Image.GetPixel($Cx+$dx,$Cy+$dy)
                $Totals[0]+=$c.R; $Totals[1]+=$c.G; $Totals[2]+=$c.B
            }
        }
        return $Totals | ForEach-Object { [int][Math]::Round($_/81) }
    } finally { $Image.Dispose() }
}
function Compare-Color($A, $B) {
    $Worst = 0
    for ($I=0; $I -lt 3; $I++) { $Worst=[Math]::Max($Worst,[Math]::Abs($A[$I]-$B[$I])) }
    return $Worst
}
function Bo-MauMacDinh([switch]$BatBuoc) {
    Click-Ui (Ui 'Cả video')
    $Remove = if ($BatBuoc) { Ui 'Bỏ màu và chuyển động cả video' } else { Find-Ui 'Bỏ màu và chuyển động cả video' }
    if ($Remove) {
        Click-Ui $Remove
        $null = Wait-Moc { !(Find-Ui 'Bỏ màu và chuyển động cả video') } 15 'Bộ màu vẫn đang áp lên video.'
    }
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
    $Media = Join-Path $Proof 'tu-lieu'
    New-Item -ItemType Directory -Path $Media | Out-Null
    $Main = Join-Path $Media 'May A.mp4'
    $Insert = Join-Path $Media 'May B.mov'
    & $FFmpeg -v error -f lavfi -i 'color=c=blue:s=256x256:r=30:d=6' -f lavfi -i 'sine=f=440:r=48000:d=6' -c:v libx264 -threads 1 -c:a aac -t 6 $Main
    if ($LASTEXITCODE -ne 0) { throw 'Không tạo được clip chính.' }
    & $FFmpeg -v error -f lavfi -i 'color=c=0xff7800:s=256x256:r=30:d=3' -c:v libx264 -threads 1 -an -timecode '01:00:10:03' $Insert
    if ($LASTEXITCODE -ne 0) { throw 'Không tạo được cảnh chèn.' }
    $InsertProbe = (& $Probe -v error -select_streams 'v:0' -show_entries 'stream=nb_frames:stream_tags=timecode' -of json $Insert | ConvertFrom-Json).streams[0]
    if ($InsertProbe.nb_frames -ne '90' -or $InsertProbe.tags.timecode -ne '01:00:10:03') { throw 'Cảnh chèn thử sai khung hoặc mã thời gian.' }

    Mouse-Ui (Ui 'Vuông 1:1')
    Click-Ui (Ui 'Cài dựng clip mới')
    $Picker = Wait-Moc { Find-Ui 'Cách dựng clip mới' -Focusable } 15 'Không tìm được cách dựng.'
    $Picker.SetFocus()
    Keys '{DOWN}'
    $null = Ui 'Theo hình'
    Keys '{HOME}{DOWN 2}{ENTER}'
    $null = Ui 'Vèo tìm điểm đổi cảnh tại máy. Có thể lấy lại mép đen đã rút trong Chỉnh nhanh → Cảnh.'
    Click-Ui (Ui 'Xong')
    Mouse-Ui (Ui 'Thả clip quay thô')
    Choose-File 'Chọn clip quay thô' $Main
    $null = Wait-Moc { Find-Ui 'Xuất video' } 150 'Clip chính chưa dựng xong.'
    Click-Ui (Ui 'Sửa tay')
    Click-Ui (Ui 'Hiệu ứng hình')
    Bo-MauMacDinh
    $Tab = Wait-Moc {
        (Find-Ui 'Tư liệu 1') ?? (Find-Ui 'Tư liệu1') ?? (Find-Ui 'Tư liệu')
    } 20 'Không thấy thẻ Tư liệu.'
    Click-Ui $Tab
    Keys '{HOME}'
    Click-Ui (Ui 'Đưa tệp vào')
    Choose-File 'Chọn ảnh hoặc clip' $Insert
    Dien 'Tìm tư liệu' 'May B'
    $null = Ui 'Gắn nhãn cho May B.mov'
    Mouse-Ui (Ui 'Đặt')
    $null = Ui 'Khung nhỏ'
    $null = Wait-Moc { Anh '01-dat-canh-chen' } 12 'Chưa chụp được cảnh chèn.'
    Mouse-Ui (Ui 'Tự động')

    $null = Ui 'Đã lưu dự án'
    Mouse-Ui (Ui 'Xuất video')
    Click-Ui (Ui '720p')
    Click-Ui (Ui 'Tuỳ chọn xuất thêm')
    Click-Ui (Ui 'Dự án dựng')
    Click-Ui (Ui 'Bản nháp mở')
    $null = Wait-Moc { Anh '02-chon-ba-tep' } 12 'Chưa chụp được hộp Xuất.'
    Click-Ui (Ui 'Xuất 3 tệp')
    $null = Wait-Moc { Find-Ui 'Thành phẩm' } 180 'Chưa thấy thành phẩm.'

    $Outputs = @{}
    foreach ($Ext in @('mp4','fcpxml','otio')) {
        $Files = @(Get-ChildItem -LiteralPath (Join-Path $Data 'du-an') -Directory | ForEach-Object {
            Get-ChildItem -LiteralPath (Join-Path $_.FullName 'xuat') -File -Filter "*.$Ext" -ErrorAction SilentlyContinue
        })
        if ($Files.Count -ne 1 -or !$Files[0].Length) { throw "Thiếu tệp $Ext hoặc xuất trùng." }
        $Outputs[$Ext] = $Files[0]
        Copy-Item -LiteralPath $Files[0].FullName -Destination (Join-Path $Proof "ban-giao.$Ext")
    }
    $Video = (& $Probe -v error -select_streams 'v:0' -show_entries 'stream=codec_name,width,height,nb_frames,avg_frame_rate' -of json $Outputs.mp4.FullName | ConvertFrom-Json).streams[0]
    if ($LASTEXITCODE -ne 0 -or $Video.codec_name -ne 'h264' -or $Video.width -ne 720 -or $Video.height -ne 720 -or
        $Video.avg_frame_rate -ne '30/1' -or $Video.nb_frames -ne '180') { throw ('Sai thông số video: ' + ($Video | ConvertTo-Json -Compress)) }
    $Decoded = Join-Path $Proof '03-mp4-khung-canh-chen.png'
    & $FFmpeg -v error -ss 0.5 -i $Outputs.mp4.FullName -frames:v 1 -threads 1 $Decoded
    if ($LASTEXITCODE -ne 0) { throw 'Không giải mã được khung MP4.' }
    $Rgb = @(Read-Color $Decoded .32 .32)
    if ((Compare-Color $Rgb @(255, 120, 0)) -gt 20) { throw "Cảnh chèn không vào MP4: $Rgb" }

    [xml]$Xml = Get-Content -LiteralPath $Outputs.fcpxml.FullName -Raw -Encoding utf8
    if ($Xml.fcpxml.version -ne '1.10' -or @($Xml.SelectNodes('//sequence')).Count -ne 1) { throw 'FCPXML sai cấu trúc.' }
    $FcpPaths = @($Xml.SelectNodes('//media-rep') | ForEach-Object { ([uri]$_.GetAttribute('src')).LocalPath })
    $Connected = $Xml.SelectSingleNode('//asset-clip[@lane="1"]')
    if (!$Connected -or $Connected.GetAttribute('offset') -ne '0s') { throw 'Không thấy cảnh chèn ở đầu FCPXML.' }
    $FcpSource = $Xml.SelectSingleNode("//asset[@id='$($Connected.ref)']")
    if (!$FcpSource) { throw 'Thiếu cảnh chèn trong tài nguyên FCPXML.' }
    $InsertCopy = ([uri]$FcpSource.SelectSingleNode('media-rep').GetAttribute('src')).LocalPath
    if (!(Test-Path -LiteralPath $InsertCopy) -or (Get-FileHash -LiteralPath $InsertCopy).Hash -ne (Get-FileHash -LiteralPath $Insert).Hash) {
        throw "Cảnh chèn FCPXML không khớp bản chép của tư liệu: $InsertCopy"
    }
    $OtioFile = Get-Content -LiteralPath $Outputs.otio.FullName -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable -Depth 100
    if ($OtioFile.OTIO_SCHEMA -ne 'Timeline.1' -or $OtioFile.tracks.children.Count -lt 2) { throw 'OTIO thiếu timeline hoặc hàng cảnh chèn.' }
    $OtioPaths = @($OtioFile.tracks.children | ForEach-Object { $_.children } | Where-Object { $_.OTIO_SCHEMA -eq 'Clip.2' } |
        ForEach-Object { ([uri]$_.media_references.DEFAULT_MEDIA.target_url).LocalPath } | Sort-Object -Unique)
    foreach ($Ref in @($Main, $InsertCopy)) {
        if ($Ref -notin $FcpPaths -or $Ref -notin $OtioPaths -or !(Test-Path -LiteralPath $Ref)) { throw "Mất liên kết nguồn: $Ref" }
    }
    $OtioInsert = $OtioFile.tracks.children[1].children[0]
    $TimeCode = $OtioInsert.media_references.DEFAULT_MEDIA.available_range.start_time
    if ($TimeCode.value -ne 108303 -or $TimeCode.rate -ne 30 -or $OtioInsert.source_range.start_time.value -ne 108303) {
        throw ('Sai timecode trong OTIO: ' + ($TimeCode | ConvertTo-Json -Compress))
    }

    $Hash = @{}
    foreach ($Ext in $Outputs.Keys) {
        $Hash[$Ext] = (Get-FileHash -LiteralPath $Outputs[$Ext].FullName).Hash.ToLowerInvariant()
    }
    Keys '%{F4}'
    if (!$App.WaitForExit(15000)) { throw 'Vèo chưa đóng.' }
    $App = Start-Process $AppFile -WorkingDirectory $Install -PassThru
    $null = Wait-Moc { Find-Ui 'Thành phẩm' } 65 'Mở lại Vèo chưa thấy thành phẩm.'
    if (!$Shell.AppActivate($App.Id)) { throw 'Không lấy được tiêu điểm sau khi mở lại.' }
    Mouse-Ui (Ui 'Tua video') .1
    Mouse-Ui (Ui 'Phát')
    $null = Wait-Moc { Find-Ui 'Dừng' } 15 'Không phát được MP4 sau khi mở lại.'
    Start-Sleep -Milliseconds 400
    $null = Wait-Moc { Anh '04-phat-sau-khi-mo-lai' } 12 'Chưa chụp được khi phát lại.'
    Mouse-Ui (Ui 'Dừng')
    Click-Ui (Ui 'Lịch sử xuất')
    foreach ($Ext in $Outputs.Keys) {
        $null = Ui $Outputs[$Ext].Name
        if ((Get-FileHash -LiteralPath $Outputs[$Ext].FullName).Hash -ne $Hash[$Ext]) { throw "Mở lại làm đổi tệp $Ext." }
    }
    $null = Wait-Moc { Anh '05-lich-su-ba-tep' } 12 'Chưa chụp được lịch sử.'
    $Report = [ordered]@{
        source=$env:VEO_QA_SOURCE
        workerSha256=$env:VEO_QA_WORKER_SHA
        system=$env:VEO_QA_OS
        video=$Video
        pixel=$Rgb
        fcpVersion=$Xml.fcpxml.version
        sourceTimecode=$InsertProbe.tags.timecode
        otioTimecodeFrames=$TimeCode.value
        sha256=$Hash
        reopenedWithFiles=$true
    }
    $Report | ConvertTo-Json -Depth 7 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $Proof 'ket-qua.json')
    Write-Host ($Report | ConvertTo-Json -Depth 7 -Compress)

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
