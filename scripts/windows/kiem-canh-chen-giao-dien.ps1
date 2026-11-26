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

function Ctrl-Key([byte]$Key, [byte]$Scan) {
    [VeoQaWindow]::keybd_event(0xA2,0x1D,0,[UIntPtr]::Zero)
    try {
        [VeoQaWindow]::keybd_event($Key,$Scan,0,[UIntPtr]::Zero)
        [VeoQaWindow]::keybd_event($Key,$Scan,2,[UIntPtr]::Zero)
    } finally { [VeoQaWindow]::keybd_event(0xA2,0x1D,2,[UIntPtr]::Zero) }
}
function Drag-Pixels([int]$X, [int]$Y, [int]$Dx, [int]$Dy) {
    $App.Refresh()
    $Window = [VeoQaWindow+Rect]::new()
    if (![VeoQaWindow]::GetWindowRect($App.MainWindowHandle, [ref]$Window)) { throw 'Mất cửa sổ đang thử.' }
    $X += $Window.L; $Y += $Window.T
    $null = [VeoQaWindow]::SetCursorPos($X,$Y)
    [VeoQaWindow]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
    try {
        for ($i = 1; $i -le 10; $i++) {
            $null = [VeoQaWindow]::SetCursorPos(($X + [int]($Dx * $i / 10)), ($Y + [int]($Dy * $i / 10)))
            Start-Sleep -Milliseconds 35
        }
    } finally { [VeoQaWindow]::mouse_event(4,0,0,0,[UIntPtr]::Zero) }
    Start-Sleep -Milliseconds 1250
}
function Scan-Box($Image, [int]$Left, [int]$Top, [int]$Right, [int]$Bottom, [switch]$Border) {
    $X0 = $Right; $Y0 = $Bottom; $X1 = -1; $Y1 = -1
    for ($y = $Top; $y -le $Bottom; $y += 2) {
        for ($x = $Left; $x -le $Right; $x += 2) {
            $c = $Image.GetPixel($x,$y)
            $ok = if ($Border) {
                $c.R -gt 205 -and $c.G -lt 178 -and $c.B -lt 150 -and ($c.R - $c.G) -gt 57 -and ($c.G - $c.B) -gt 10
            } else { $c.R -gt 224 -and $c.G -lt 35 -and $c.B -ge 125 -and $c.B -le 190 }
            if (!$ok) { continue }
            $X0 = [Math]::Min($X0,$x); $Y0 = [Math]::Min($Y0,$y)
            $X1 = [Math]::Max($X1,$x); $Y1 = [Math]::Max($Y1,$y)
        }
    }
    if ($X1 -lt 0) { throw 'Không thấy mẫu màu trong ảnh chụp của cửa sổ.' }
    [pscustomobject]@{left=$X0;top=$Y0;right=$X1;bottom=$Y1;width=($X1-$X0+1);height=($Y1-$Y0+1)}
}
function Scan-Capture([string]$Name, [string]$Mode) {
    $null = Wait-Moc { Anh $Name } 12 "Chưa chụp được ảnh $Name."
    $Image = [System.Drawing.Bitmap]::new((Join-Path $Proof "$Name.png"))
    try {
        if ($Image.Width -lt 1000 -or $Image.Height -lt 730) { throw 'Cửa sổ kiểm nhỏ hơn bố cục chuẩn.' }
        if ($Mode -eq 'timeline') {
            $Thumb = Scan-Box $Image ([int]($Image.Width*.17)) ([int]($Image.Height*.73)) ([int]($Image.Width*.74)) ([int]($Image.Height*.84))
            $Bar = Scan-Box $Image ($Thumb.left - 3) ($Thumb.top - 3) ([int]($Image.Width*.96)) ($Thumb.bottom + 3) -Border
            return [pscustomobject]@{left=($Thumb.left - 2);right=$Bar.right;y=[int](($Thumb.top+$Thumb.bottom)/2);width=($Bar.right-$Thumb.left+3)}
        }
        Scan-Box $Image ([int]($Image.Width*.29)) ([int]($Image.Height*.105)) ([int]($Image.Width*.64)) ([int]($Image.Height*.52))
    } finally { $Image.Dispose() }
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
    $null = Wait-Moc {
        $Root = [System.Windows.Automation.AutomationElement]::RootElement
        $Name = [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::NameProperty, 'Chọn ảnh hoặc clip')
        $Window = $Root.FindFirst([System.Windows.Automation.TreeScope]::Children, $Name)
        if ($Window -and $Window.Current.ProcessId -eq $App.Id) { $Window }
    } 20 'Không thấy hộp chọn tệp của Vèo.'
    Keys '%n'
    Keys $Fixture
    Keys '{ENTER}'
    Mouse-Ui (Ui 'Đặt')
    $null = Ui 'Khung nhỏ'
    Write-Host 'Đã nhập ảnh và đặt cảnh qua giao diện.'


    $Start = Scan-Capture '01-thoi-luong-ban-dau' 'timeline'
    Drag-Pixels ($Start.right-5) $Start.y 28 0
    $Grow = Scan-Capture '02-keo-dai-mep-phai' 'timeline'
    Drag-Pixels ($Grow.right-5) $Grow.y -28 0
    $Shrink = Scan-Capture '03-thu-ngan-mep-phai' 'timeline'
    if ($Grow.width -lt $Start.width + 15 -or $Shrink.width -gt $Grow.width - 15 -or [Math]::Abs($Shrink.width-$Start.width) -gt 4) {
        throw ('Mép phải chưa kéo về được: ' + (@($Start,$Grow,$Shrink) | ConvertTo-Json -Compress))
    }
    Drag-Pixels ($Shrink.left+3) $Shrink.y 26 0
    $LeftIn = Scan-Capture '04-thu-ngan-mep-trai' 'timeline'
    Drag-Pixels ($LeftIn.left+3) $LeftIn.y -26 0
    $LeftOut = Scan-Capture '05-keo-dai-mep-trai' 'timeline'
    if ($LeftIn.left -lt $Shrink.left + 16 -or $LeftOut.left -gt $LeftIn.left - 16 -or [Math]::Abs($LeftOut.left-$Start.left) -gt 4 -or [Math]::Abs($LeftIn.right-$Start.right) -gt 4) {
        throw ('Mép trái chưa đổi độc lập: ' + (@($Shrink,$LeftIn,$LeftOut) | ConvertTo-Json -Compress))
    }
    Write-Host 'Đã kéo dài rồi thu ngắn tại hai mép thời lượng.'

    function Same-Box($A, $B, [int]$px = 4) {
        foreach ($side in @('left','right','top','bottom')) {
            if ([Math]::Abs($A.$side - $B.$side) -gt $px) { return $false }
        }
        return $true
    }

    $Full = Scan-Capture '06-canh-day-khung-co-tay-nam' 'shape'
    Drag-Pixels ($Full.right-9) ($Full.bottom-9) 21 23
    $null = Ui 'Khung đã chạm mép video hoặc kích thước nhỏ nhất.'
    $null = Wait-Moc { Anh '06b-bao-ly-do-cham-mep' } 10 'Không chụp được thông báo khi chạm mép.'
    Drag-Pixels ($Full.right-9) ($Full.bottom-9) -68 -74
    $Reduced = Scan-Capture '07-thu-khung-ngay-tren-khung-xem' 'shape'
    if ($Reduced.width -gt $Full.width - 45 -or $Reduced.height -gt $Full.height - 45 -or [Math]::Abs($Reduced.left-$Full.left) -gt 4 -or [Math]::Abs($Reduced.top-$Full.top) -gt 4) {
        throw ('Kéo góc đầy khung chưa đổi được: ' + (@($Full,$Reduced) | ConvertTo-Json -Compress))
    }
    Drag-Pixels ([int](($Reduced.left+$Reduced.right)/2)) ([int](($Reduced.top+$Reduced.bottom)/2)) 28 30
    $Initial = Scan-Capture '08-doi-vi-tri-khung' 'shape'
    if ($Initial.left -lt $Reduced.left+20 -or $Initial.top -lt $Reduced.top+20 -or [Math]::Abs($Initial.width-$Reduced.width) -gt 4 -or [Math]::Abs($Initial.height-$Reduced.height) -gt 4) {
        throw 'Kéo thân chưa dời khung mà vẫn giữ kích thước.'
    }
    $Directions = @(
        @{name='nw'; x=-1; y=-1}, @{name='n'; x=0; y=-1}, @{name='ne'; x=1; y=-1},
        @{name='w'; x=-1; y=0}, @{name='e'; x=1; y=0},
        @{name='sw'; x=-1; y=1}, @{name='s'; x=0; y=1}, @{name='se'; x=1; y=1}
    )
    function Drag-Grip($Box, $Dir, $Sign) {
        $X = if ($Dir.x -lt 0) { $Box.left - 1 } elseif ($Dir.x -gt 0) { $Box.right + 1 } else { [int](($Box.left+$Box.right)/2) }
        $Y = if ($Dir.y -lt 0) { $Box.top - 1 } elseif ($Dir.y -gt 0) { $Box.bottom + 1 } else { [int](($Box.top+$Box.bottom)/2) }
        Drag-Pixels $X $Y (13*$Dir.x*$Sign) (17*$Dir.y*$Sign)
    }
    $Actions = @()
    $Old = $Initial
    foreach ($Dir in $Directions) {
        Drag-Grip $Old $Dir 1
        $Bigger = Scan-Capture ("09-phong-" + $Dir.name) 'shape'
        $XChanged = $Bigger.width - $Old.width
        $YChanged = $Bigger.height - $Old.height
        $XExpected = [Math]::Abs($Dir.x)*13
        $YExpected = [Math]::Abs($Dir.y)*17
        if ([Math]::Abs($XChanged-$XExpected) -gt 4 -or [Math]::Abs($YChanged-$YExpected) -gt 4) {
            throw ("Tay nắm $($Dir.name) không phóng theo hai trục: " + (@($Old,$Bigger) | ConvertTo-Json -Compress))
        }
        Drag-Grip $Bigger $Dir -1
        $Smaller = Scan-Capture ("10-thu-" + $Dir.name) 'shape'
        if (!(Same-Box $Old $Smaller)) { throw ("Tay nắm $($Dir.name) không thu về: " + (@($Old,$Smaller) | ConvertTo-Json -Compress)) }
        $Actions += @{name=$Dir.name; before=$Old; bigger=$Bigger; smaller=$Smaller}
        $Old = $Smaller
        Write-Host "Đã phóng và thu tay nắm $($Dir.name)."
    }
    Ctrl-Key 0x5A 0x2C
    Start-Sleep -Milliseconds 1100
    $Undone = Scan-Capture '11-hoan-tac' 'shape'
    $UndoByKey = Same-Box $Undone ($Actions[-1].bigger)
    if (!$UndoByKey) {
        Mouse-Ui (Ui 'Hoàn tác (Ctrl+Z)')
        Start-Sleep -Milliseconds 1100
        $Undone = Scan-Capture '11b-hoan-tac-bang-nut' 'shape'
    }
    if (!(Same-Box $Undone ($Actions[-1].bigger))) { throw 'Chưa hoàn tác được thao tác kéo.' }
    Ctrl-Key 0x59 0x15
    Start-Sleep -Milliseconds 1100
    $Redone = Scan-Capture '12-lam-lai' 'shape'
    $RedoByKey = Same-Box $Redone ($Actions[-1].smaller)
    if (!$RedoByKey) {
        Mouse-Ui (Ui 'Làm lại (Ctrl+Y)')
        Start-Sleep -Milliseconds 1100
        $Redone = Scan-Capture '12b-lam-lai-bang-nut' 'shape'
    }
    if (!(Same-Box $Redone ($Actions[-1].smaller))) { throw 'Chưa làm lại được thao tác kéo.' }
    Write-Host "Đã hoàn tác và làm lại. Bằng tổ hợp phím: $UndoByKey / $RedoByKey."

    if (!$App.CloseMainWindow() -or !$App.WaitForExit(15000)) { throw 'Chưa đóng được app để kiểm mở lại.' }
    $App = Start-Process $AppFile -WorkingDirectory $Install -PassThru
    $null = Wait-Moc { Find-Ui 'Đèn hiệu cuối đảo' } 85 'Mở lại app không có dự án.'
    if (!(Find-Ui 'Xuất video') -and !(Find-Ui 'Xuất lại')) { Mouse-Ui (Ui 'Đèn hiệu cuối đảo') }
    $Target = Wait-Moc { Find-Ui 'Sửa tay' } 15 'Mở lại app không có nút Sửa tay.'
    Mouse-Ui $Target
    $null = Ui 'Thu dải thời gian'
    $Saved = Scan-Capture '13-mo-lai-du-an' 'shape'
    if (!(Same-Box $Saved $Redone)) { throw ('Mở lại không giữ vị trí hoặc kích thước: ' + (@($Saved,$Redone) | ConvertTo-Json -Compress)) }

    Mouse-Ui (Ui 'Xuất')
    Click-Ui (Ui '720p')
    Click-Ui (Ui 'Xuất 1 tệp')
    $Export = Wait-Moc {
        Get-ChildItem -LiteralPath (Join-Path $Data 'du-an') -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            Get-ChildItem -LiteralPath (Join-Path $_.FullName 'xuat') -File -Filter '*.mp4' -ErrorAction SilentlyContinue |
                Where-Object Length -gt 0 | Select-Object -First 1
        }
    } 150 'Chưa có MP4 xuất từ nút Xuất.'
    $Streams = (& (Join-Path $Install 'ffprobe.exe') -v error -of json -show_entries 'stream=codec_name,codec_type,width,height,nb_frames' $Export.FullName | ConvertFrom-Json).streams
    if ($LASTEXITCODE -ne 0) { throw 'Không đọc được MP4.' }
    $Video = $Streams | Where-Object codec_type -eq 'video'
    if ($Video.codec_name -ne 'h264' -or $Video.width -ne 720 -or $Video.height -ne 720 -or [int]$Video.nb_frames -ne 480) {
        throw ('MP4 xuất sai số khung hoặc tỷ lệ: ' + ($Streams | ConvertTo-Json -Compress))
    }
    $ExportFrame = Join-Path $Proof '14-khung-trong-mp4.png'
    & (Join-Path $Install 'ffmpeg.exe') -v error -ss 0.5 -i $Export.FullName -frames:v 1 -threads 1 $ExportFrame
    if ($LASTEXITCODE -ne 0) { throw 'Không đọc được khung MP4.' }
    $Image = [System.Drawing.Bitmap]::new($ExportFrame)
    try { $Output = Scan-Box $Image 0 0 719 719 } finally { $Image.Dispose() }
    $Expected = @{
        left=720*($Saved.left-$Full.left)/$Full.width; top=720*($Saved.top-$Full.top)/$Full.height
        right=720*($Saved.right-$Full.left)/$Full.width; bottom=720*($Saved.bottom-$Full.top)/$Full.height
    }
    if (!(Same-Box $Output $Expected 12)) { throw ('Khung ở MP4 khác bản xem: ' + (@($Output,$Expected) | ConvertTo-Json -Compress)) }
    Copy-Item -LiteralPath $Export.FullName -Destination (Join-Path $Proof 'canh-chen-da-xuat.mp4')

    Mouse-Ui (Ui 'Tự động')
    $null = Wait-Moc { Find-Ui 'Thành phẩm' } 25 'Màn Tự động chưa mở bản đã xuất.'
    Mouse-Ui (Ui 'Phát')
    $null = Wait-Moc { Find-Ui 'Dừng' } 12 'Vèo chưa phát video đã xuất.'
    Start-Sleep -Milliseconds 400
    $null = Wait-Moc { Anh '15-phat-mp4-da-xuat' } 12 'Chưa chụp được lúc phát MP4.'
    Mouse-Ui (Ui 'Dừng')
    @{
        source=$env:VEO_QA_SOURCE; worker=$env:VEO_QA_WORKER_SHA; timeline=@($Start,$Grow,$Shrink,$LeftIn,$LeftOut);
        resizedFromFull=$Reduced; handles=$Actions; undo=$Undone; redo=$Redone; undoByKey=$UndoByKey; redoByKey=$RedoByKey; reopen=$Saved;
        video=$Video; previewIn720=$Expected; exported=$Output; playedExportInApp=$true
    } | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $Proof 'ket-qua-canh-chen.json')
    Write-Host 'Đã mở lại dự án, mở và phát MP4 trong Vèo, khớp vị trí khung xem.'
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
