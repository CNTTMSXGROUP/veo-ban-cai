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

    $Start = Scan-Capture 'mep-ban-dau' 'timeline'
    Drag-Pixels ($Start.right-5) $Start.y 28 0
    $Grow = Scan-Capture 'keo-dai-mep-phai' 'timeline'
    Drag-Pixels ($Grow.right-5) $Grow.y -28 0
    $Shrink = Scan-Capture 'thu-ngan-mep-phai' 'timeline'
    Mouse-Ui (Ui 'Khung nhỏ')
    Start-Sleep -Milliseconds 700
    $Before = Scan-Capture 'khung-nho-ban-dau' 'shape'
    Drag-Pixels ($Before.right+1) ($Before.bottom+1) -19 0
    $After = Scan-Capture 'keo-goc-theo-ngang' 'shape'
    $Evidence = [ordered]@{
        source=$env:VEO_QA_SOURCE;
        keoDaiDuoc=($Grow.width -gt $Start.width+5);
        thuNganDuoc=($Shrink.width -lt $Grow.width-5);
        keoNgangDoiCaChieuCao=($After.height -lt ($Before.height-2) -and $After.width -lt ($Before.width-4));
        timeline=@($Start,$Grow,$Shrink); shape=@($Before,$After)
    }
    $Evidence | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 -LiteralPath (Join-Path $Proof 'tai-hien-canh-chen.json')
    Write-Host ($Evidence | ConvertTo-Json -Depth 6 -Compress)
    if (!$Evidence.keoDaiDuoc) { throw 'Chưa điều khiển được mép để tái hiện.' }
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
