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
function Mouse-Ui($Item) {
    $Rect = $Item.Current.BoundingRectangle
    if ($Rect.Width -le 0 -or $Rect.Height -le 0) { throw 'Điều khiển không nằm trên cửa sổ.' }
    if (![VeoQaWindow]::SetCursorPos([int]($Rect.X + $Rect.Width / 2), [int]($Rect.Y + $Rect.Height / 2))) { throw 'Không đặt được con trỏ trên máy thử.' }
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
function Output-Files {
    Get-ChildItem -LiteralPath (Join-Path $Data 'du-an') -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Get-ChildItem -LiteralPath (Join-Path $_.FullName 'xuat') -File -Filter '*.mp4' -ErrorAction SilentlyContinue
    }
}

function Source-Hdr([string]$Label, [string]$Transfer, [string]$Color) {
    $SourceFile = Join-Path $Qa "$Label.mp4"
    $Graph = "zscale=pin=bt709:tin=bt709:min=gbr:rin=full:p=bt2020:t=$Transfer" + ':m=bt2020nc:r=tv:npl=100,format=yuv420p10le'
    $Lavfi = "color=c=$Color" + ':s=256x256:r=30:d=4,format=rgb24'
    & $FFmpeg -v error -f lavfi -i $Lavfi -f lavfi -i 'sine=f=400:r=48000:d=4' -vf $Graph -c:v libx264 -threads 1 -preset ultrafast -color_primaries bt2020 -color_trc $Transfer -colorspace bt2020nc -color_range tv -c:a aac -t 4 $SourceFile
    if ($LASTEXITCODE -ne 0) { throw "Không tạo được nguồn $Label." }
    $Tags = (& $Probe -v error -select_streams 'v:0' -show_entries 'stream=color_space,color_primaries,color_transfer,pix_fmt' -of json $SourceFile | ConvertFrom-Json).streams[0]
    if ($LASTEXITCODE -ne 0 -or $Tags.color_transfer -ne $Transfer -or $Tags.color_space -ne 'bt2020nc' -or $Tags.pix_fmt -ne 'yuv420p10le') {
        throw "Nguồn HDR thử sai thông tin."
    }
    $Tags | ConvertTo-Json | Set-Content -Encoding utf8 -LiteralPath (Join-Path $Proof "$Label-nguon.json")
    $Ref = Join-Path $Proof "$Label-chuan.png"
    & $FFmpeg -v error -ss 0.5 -i $SourceFile -vf 'zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv,format=yuv420p' -frames:v 1 -threads 1 $Ref
    if ($LASTEXITCODE -ne 0) { throw "Không tạo được khung đối chiếu $Label." }
    return @{ path=$SourceFile; rgb=@(Read-Color $Ref .32 .32) }
}

function Test-Palette([string]$Label, $Expected, [string]$ExportLabel) {
    $Existing = @{}
    Output-Files | ForEach-Object { $Existing[$_.FullName] = $_.LastWriteTimeUtc.Ticks }
    $null = Ui 'Đã lưu dự án'
    $Preview = (Wait-Moc {
        if (Anh "$Label-xem") {
            $Sample = @(Read-Color (Join-Path $Proof "$Label-xem.png") .42 .38)
            if ((Compare-Color $Sample $Expected) -le 8) { @{rgb=$Sample} }
        }
    } 60 "Khung xem $Label chưa khớp mẫu SDR.").rgb
    Mouse-Ui (Ui $ExportLabel)
    Click-Ui (Ui '720p')
    Click-Ui (Ui 'Xuất 1 tệp')
    $null = Wait-Moc { Find-Ui 'Thành phẩm' } 150 "Ca $Label chưa xuất xong."
    $Output = Wait-Moc {
        Output-Files | Where-Object { $_.Length -gt 0 -and $Existing[$_.FullName] -ne $_.LastWriteTimeUtc.Ticks } |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    } 30 "Chưa thấy MP4 của ca $Label."
    $Video = (& $Probe -v error -select_streams 'v:0' -of json -show_entries 'stream=codec_name,pix_fmt,width,height,nb_frames,color_space,color_range' $Output.FullName | ConvertFrom-Json).streams[0]
    if ($LASTEXITCODE -ne 0 -or $Video.codec_name -ne 'h264' -or $Video.pix_fmt -ne 'yuv420p' -or $Video.width -ne 720 -or $Video.height -ne 720 -or
       [int]$Video.nb_frames -ne 120 -or $Video.color_space -ne 'bt709' -or $Video.color_range -ne 'tv') {
        throw ('Sai thông số MP4 ' + $Label + ' ' + ($Video | ConvertTo-Json -Compress))
    }
    $Frame = Join-Path $Proof "$Label-file.png"
    & $FFmpeg -v error -ss 0.5 -i $Output.FullName -frames:v 1 -threads 1 $Frame
    if ($LASTEXITCODE -ne 0) { throw "Không đọc được khung MP4 của ca $Label." }
    $FromFile = @(Read-Color $Frame .32 .32)
    Mouse-Ui (Ui 'Phát')
    $null = Wait-Moc { Find-Ui 'Dừng' } 15 'Vèo chưa phát MP4.'
    Start-Sleep -Milliseconds 400
    $null = Wait-Moc { Anh "$Label-phat" } 12 'Chưa chụp được lúc phát.'
    Mouse-Ui (Ui 'Dừng')
    $Played = @(Read-Color (Join-Path $Proof "$Label-phat.png") .42 .38)
    Copy-Item -LiteralPath $Output.FullName -Destination (Join-Path $Proof "$Label.mp4")
    $Info = [ordered]@{ten=$Label; chuan=$Expected; xem=$Preview; giaiMa=$FromFile; phat=$Played; stream=$Video}
    $Info | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $Proof "$Label.json")
    Write-Host ($Info | ConvertTo-Json -Depth 6 -Compress)
    if ((Compare-Color $Preview $Played) -gt 8 -or (Compare-Color $Preview $FromFile) -gt 8 -or
        (Compare-Color $Expected $FromFile) -gt 8 -or (Compare-Color $Expected $Played) -gt 8) {
        throw "Ca $Label lệch quá 8 mức RGB."
    }
    return $Output.FullName
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



    $Probe = Join-Path $Install 'ffprobe.exe'
    $FFmpeg = Join-Path $Install 'ffmpeg.exe'
    $Hlg = Source-Hdr 'hlg-hong' 'arib-std-b67' '0xD030A7'
    $Pq = Source-Hdr 'pq-cam' 'smpte2084' '0xE09415'
    if ((Compare-Color $Pq.rgb $Hlg.rgb) -lt 40) { throw 'Hai nguồn HDR quá giống nhau.' }
    $Green = Join-Path $Qa 'phong-xanh.mp4'
    & $FFmpeg -v error -f lavfi -i 'color=c=0x00ff00:s=256x256:r=30:d=4' -f lavfi -i 'sine=f=300:r=48000:d=4' -vf 'drawbox=x=166:y=166:w=46:h=46:color=0xe0a080:t=fill' -c:v libx264 -threads 2 -c:a aac -t 4 $Green
    if ($LASTEXITCODE -ne 0) { throw 'Không tạo được clip phông xanh.' }

    Click-Ui (Ui 'Kho phong cách')
    $Picker = Wait-Moc { Find-Ui 'Thể loại' -Focusable } 15 'Không thấy bộ lọc.'
    $Picker.SetFocus()
    Keys '{DOWN}'
    $null = Ui 'Tất cả'
    Keys '{END}{ENTER}'
    $null = Ui 'Xem thử Pixel retro'
    Click-Ui (Ui 'Chọn dùng')
    Click-Ui (Ui 'Tạo video theo mẫu')
    Dien 'Tên video' 'HDR Storyboard'
    Dien 'Số giây cảnh 1' '4'
    Click-Ui (Ui 'Chọn tệp cho Ảnh hoặc clip cảnh 1')
    Choose-File 'Chọn ảnh hoặc clip' $Hlg.path
    $null = Ui 'hlg-hong.mp4'
    Click-Ui (Ui 'Dựng video')
    $null = Wait-Moc { Find-Ui 'Xuất video' } 120 'Storyboard thử chưa dựng.'
    Click-Ui (Ui 'Sửa tay')
    Click-Ui (Ui 'Hiệu ứng hình')
    Bo-MauMacDinh -BatBuoc
    Mouse-Ui (Ui 'Tự động')
    $null = Test-Palette 'story-hlg' $Hlg.rgb 'Xuất video'

    Click-Ui (Ui 'Sửa tay')
    $Tab = Wait-Moc {
        (Find-Ui 'Tư liệu 1') ?? (Find-Ui 'Tư liệu1') ?? (Find-Ui 'Tư liệu')
    } 20 'Không thấy thẻ Tư liệu của storyboard.'
    Click-Ui $Tab
    Click-Ui (Ui 'Đưa tệp vào')
    Choose-File 'Chọn ảnh hoặc clip' $Pq.path
    Dien 'Tìm tư liệu' 'pq-cam'
    $null = Ui 'pq-cam.mp4'
    Mouse-Ui (Ui 'Đặt')
    $null = Ui 'Khung nhỏ'
    Mouse-Ui (Ui 'Tự động')
    $null = Test-Palette 'chen-pq' $Pq.rgb 'Xuất lại'

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
    Choose-File 'Chọn clip quay thô' $Green
    $null = Wait-Moc { Find-Ui 'phong-xanh' } 60 'Không thấy dự án phông xanh.'
    $null = Wait-Moc { Find-Ui 'Xuất video' } 150 'Clip phông xanh chưa dựng xong.'
    Click-Ui (Ui 'Sửa tay')
    Click-Ui (Ui 'Hiệu ứng hình')
    Bo-MauMacDinh
    Click-Ui (Ui 'Đoạn này')
    Dien 'Mã màu phông' '#00ff00'
    $null = Ui 'Độ gần màu phông'
    Click-Ui (Ui 'Chọn ảnh hoặc video nền')
    Choose-File 'Chọn ảnh hoặc video nền' $Hlg.path
    $null = Ui 'Bỏ nền'
    Mouse-Ui (Ui 'Tự động')
    $OutputPath = Test-Palette 'nen-hlg' $Hlg.rgb 'Xuất video'

    $HashBefore = (Get-FileHash -LiteralPath $OutputPath).Hash.ToLowerInvariant()
    Keys '%{F4}'
    if (!$App.WaitForExit(15000)) { throw 'Vèo chưa đóng.' }
    $App = Start-Process $AppFile -WorkingDirectory $Install -PassThru
    $null = Wait-Moc { Find-Ui 'Thành phẩm' } 65 'Mở lại Vèo chưa thấy MP4 đã lưu.'
    if (!$Shell.AppActivate($App.Id)) { throw 'Không lấy được tiêu điểm sau khi mở lại.' }
    Mouse-Ui (Ui 'Phát')
    $null = Wait-Moc { Find-Ui 'Dừng' } 15 'Không phát được MP4 sau khi mở lại.'
    Start-Sleep -Milliseconds 400
    $null = Wait-Moc { Anh 'nen-hlg-mo-lai' } 12 'Chưa chụp được sau khi mở lại.'
    $Reopened = @(Read-Color (Join-Path $Proof 'nen-hlg-mo-lai.png') .42 .38)
    $HashAfter = (Get-FileHash -LiteralPath $OutputPath).Hash.ToLowerInvariant()
    if ((Compare-Color $Reopened $Hlg.rgb) -gt 8 -or $HashAfter -ne $HashBefore) {
        throw 'Màu phát hoặc MP4 đã thay đổi sau khi đóng mở Vèo.'
    }
    @{ mau=$Reopened; sha256=$HashAfter; giuNguyenTep=$true } | ConvertTo-Json |
        Set-Content -Encoding utf8 -LiteralPath (Join-Path $Proof 'nen-hlg-mo-lai.json')

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
