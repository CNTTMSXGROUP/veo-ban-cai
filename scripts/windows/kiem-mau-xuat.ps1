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
    $Pattern = $null
    if ($Item.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$Pattern)) { $Pattern.Invoke(); return }
    if ($Item.TryGetCurrentPattern([System.Windows.Automation.TogglePattern]::Pattern, [ref]$Pattern)) { $Pattern.Toggle(); return }
    $Item.SetFocus()
    Keys '{ENTER}'
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
function Test-Color([string]$Label, [int]$Frames, [string]$Hdr) {
    $Exports = @(Output-Files | ForEach-Object FullName)
    $Png = Join-Path $Proof "$Label-file.png"
    $fileTag = @{pix_fmt='yuv420p'; color_range='tv'; color_space='bt709'; color_transfer=$Hdr}
    $null = Wait-Moc { Anh "$Label-xem" } 12 'Không chụp được khung xem.'
    $Preview = @(Read-Color (Join-Path $Proof "$Label-xem.png") .42 .38)

    Mouse-Ui (Ui 'Xuất video')
    Click-Ui (Ui '720p')
    Click-Ui (Ui 'Xuất 1 tệp')
    $Output = Wait-Moc {
        Output-Files | Where-Object { $_.FullName -notin $Exports -and $_.Length -gt 0 } | Select-Object -First 1
    } 160 "Chưa thấy MP4 của ca $Label."
    $Video = (& $Probe -v error -select_streams 'v:0' -of json -show_entries 'stream=codec_name,pix_fmt,width,height,nb_frames,color_space,color_range,color_transfer,color_primaries' $Output.FullName | ConvertFrom-Json).streams[0]
    if ($LASTEXITCODE -ne 0 -or $Video.codec_name -ne 'h264' -or $Video.width -ne 720 -or $Video.height -ne 720 -or [int]$Video.nb_frames -ne $Frames) {
        throw ('Sai thông số MP4 cho ' + $Label + ' ' + ($Video | ConvertTo-Json -Compress))
    }
    & $FFmpeg -v error -ss 0.5 -i $Output.FullName -frames:v 1 -threads 1 $Png
    if ($LASTEXITCODE -ne 0) { throw "Không đọc được khung MP4 của ca $Label." }
    $FromFile = @(Read-Color $Png .32 .32)

    $null = Wait-Moc { Find-Ui 'Thành phẩm' } 30 'Màn Tự động chưa mở bản đã xuất.'
    Mouse-Ui (Ui 'Phát')
    $null = Wait-Moc { Find-Ui 'Dừng' } 15 'Chưa phát tệp MP4 trong Vèo.'
    Start-Sleep -Milliseconds 400
    $null = Wait-Moc { Anh "$Label-phat" } 12 'Chưa chụp được lúc phát MP4.'
    Mouse-Ui (Ui 'Dừng')
    $Played = @(Read-Color (Join-Path $Proof "$Label-phat.png") .42 .38)
    Copy-Item -LiteralPath $Output.FullName -Destination (Join-Path $Proof "$Label.mp4")

    $Info = [ordered]@{ten=$Label; xem=$Preview; giaiMa=$FromFile; phat=$Played; stream=$Video;
                      fileDoiVoiXem=(Compare-Color $FromFile $Preview); phatDoiVoiXem=(Compare-Color $Played $Preview)}
    $Info | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $Proof "$Label.json")
    Write-Host ($Info | ConvertTo-Json -Depth 6 -Compress)
    foreach ($key in $fileTag.Keys) {
        if ($fileTag[$key] -and $Video.$key -ne $fileTag[$key]) { throw "Sai trường $key trong MP4 của ca $Label." }
    }
    if ($Info.fileDoiVoiXem -gt 8 -or $Info.phatDoiVoiXem -gt 8 -or (Compare-Color $FromFile $Played) -gt 8) {
        throw "Màu khi phát hoặc giải mã lệch quá 8 mức ở ca $Label."
    }
    if ($Label -eq 'sdr-canh-chen' -and (Compare-Color $Preview @(249,0,153)) -gt 8) { throw 'Điểm đo SDR không nằm trên cảnh chèn.' }
    if ($Hdr -and ($FromFile[0] -lt $FromFile[1]+30 -or $FromFile[2] -lt $FromFile[1]+20)) {
        throw "Khung $Label chưa giữ được mẫu màu HDR sau đổi dải sáng."
    }
    return $Output.FullName
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


    Click-Ui (Ui 'Kho phong cách')
    $Picker = Wait-Moc { Find-Ui 'Thể loại' -Focusable } 15 'Không thấy bộ lọc.'
    $Picker.SetFocus()
    Keys '{DOWN}'
    $null = Ui 'Tất cả'
    Keys '{END}{ENTER}'
    $null = Ui 'Xem thử Pixel retro'
    Click-Ui (Ui 'Chọn dùng')
    Click-Ui (Ui 'Tạo video theo mẫu')
    Click-Ui (Ui 'Dùng kịch bản mẫu')
    Click-Ui (Ui 'Dựng video')
    $null = Wait-Moc { Find-Ui 'Xuất video' } 120 'Storyboard thử chưa dựng.'
    Click-Ui (Ui 'Sửa tay')
    $Fixture = Join-Path $Qa 'canh-hong.png'
    & (Join-Path $Install 'ffmpeg.exe') -hide_banner -v error -f lavfi -i 'color=c=0xf90099:s=384x216' -frames:v 1 -threads 1 $Fixture
    if ($LASTEXITCODE -ne 0 -or !(Test-Path $Fixture)) { throw 'Không tạo được ảnh thử.' }
    Mouse-Ui (Ui 'Tư liệu')
    Mouse-Ui (Ui 'Đưa tệp vào')

    Choose-File 'Chọn ảnh hoặc clip' $Fixture
    Mouse-Ui (Ui 'Đặt')
    $null = Ui 'Khung nhỏ'
    Mouse-Ui (Ui 'Tự động')
    $null = Ui 'Xuất video'
    $Probe = Join-Path $Install 'ffprobe.exe'
    $FFmpeg = Join-Path $Install 'ffmpeg.exe'
    $null = Test-Color 'sdr-canh-chen' 480 ''

    Mouse-Ui (Ui 'Vuông 1:1')
    Mouse-Ui (Ui 'Cài dựng clip mới')
    $Picker = Wait-Moc { Find-Ui 'Cách dựng clip mới' -Focusable } 15 'Không tìm được cách dựng.'
    $Picker.SetFocus()
    Keys '{DOWN}'
    $null = Ui 'Theo hình'
    Keys '{HOME}{DOWN 2}{ENTER}'
    $null = Ui 'Vèo tìm điểm đổi cảnh tại máy. Có thể lấy lại mép đen đã rút trong Chỉnh nhanh → Cảnh.'
    Click-Ui (Ui 'Xong')
    foreach ($Type in @('smpte2084','arib-std-b67')) {
        $Label = if ($Type -eq 'smpte2084') { 'hdr-pq' } else { 'hdr-hlg' }
        $SourceFile = Join-Path $Qa "$Label.mp4"
        $Graph = "zscale=pin=bt709:tin=bt709:min=gbr:rin=full:p=bt2020:t=${Type}:m=bt2020nc:r=tv:npl=100,format=yuv420p10le"
        & $FFmpeg -v error -f lavfi -i 'color=c=0xD030A7:s=256x256:r=30:d=4,format=rgb24' -f lavfi -i 'sine=f=400:r=48000:d=4' -vf $Graph -c:v libx264 -threads 1 -preset ultrafast -color_primaries bt2020 -color_trc $Type -colorspace bt2020nc -color_range tv -c:a aac -t 4 $SourceFile
        if ($LASTEXITCODE -ne 0) { throw "Không tạo được nguồn HDR $Label." }
        $Tags = (& $Probe -v error -select_streams 'v:0' -show_entries 'stream=color_space,color_primaries,color_transfer,pix_fmt' -of json $SourceFile | ConvertFrom-Json).streams[0]
        if ($LASTEXITCODE -ne 0 -or $Tags.color_transfer -ne $Type -or $Tags.color_space -ne 'bt2020nc' -or $Tags.pix_fmt -ne 'yuv420p10le') {
           throw ('Nguồn HDR thử sai thông tin: ' + ($Tags | ConvertTo-Json -Compress))
        }
        $Tags | ConvertTo-Json | Set-Content -Encoding utf8 -LiteralPath (Join-Path $Proof "$Label-nguon.json")
        Mouse-Ui (Ui 'Thả clip quay thô')
        Choose-File 'Chọn clip quay thô' $SourceFile
        $null = Wait-Moc { Find-Ui $Label } 60 "Không thấy dự án $Label."
        $null = Wait-Moc { Find-Ui 'Xuất video' } 150 "Clip $Label chưa dựng xong."
        $OutputPath = Test-Color $Label 120 'bt709'
    }

    $HashBefore = (Get-FileHash -LiteralPath $OutputPath).Hash.ToLowerInvariant()
    Keys '%{F4}'
    if (!$App.WaitForExit(15000)) { throw 'Vèo chưa đóng.' }
    $App = Start-Process $AppFile -WorkingDirectory $Install -PassThru
    $null = Wait-Moc { Find-Ui 'Thành phẩm' } 65 'Mở lại Vèo chưa thấy thành phẩm của dự án.'
    if (!$Shell.AppActivate($App.Id)) { throw 'Không lấy được tiêu điểm sau khi mở lại.' }
    $null = Ui 'Vèo 0.3.24'
    Mouse-Ui (Ui 'Phát')
    $null = Wait-Moc { Find-Ui 'Dừng' } 15 'Không phát được MP4 sau khi mở lại.'
    Start-Sleep -Milliseconds 400
    $null = Wait-Moc { Anh 'hdr-hlg-mo-lai' } 12 'Chưa chụp được lúc phát sau khi mở lại.'
    $Reopened = @(Read-Color (Join-Path $Proof 'hdr-hlg-mo-lai.png') .42 .38)
    $Earlier = Get-Content -Raw -LiteralPath (Join-Path $Proof 'hdr-hlg.json') | ConvertFrom-Json
    $HashAfter = (Get-FileHash -LiteralPath $OutputPath).Hash.ToLowerInvariant()
    if ((Compare-Color $Reopened $Earlier.phat) -gt 8 -or $HashAfter -ne $HashBefore) {
        throw 'Màu phát hoặc MP4 đã thay đổi sau khi đóng mở Vèo.'
    }
    @{ mau = $Reopened; sha256 = $HashAfter; giuNguyenTep = $true } | ConvertTo-Json |
        Set-Content -Encoding utf8 -LiteralPath (Join-Path $Proof 'hdr-hlg-mo-lai.json')
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
