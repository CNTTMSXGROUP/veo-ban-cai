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
function Dien([string]$Name, [string]$Value) {
    $Control = Wait-Moc { Find-Ui $Name -Focusable } 16 "Không tìm thấy ô $Name."
    $Control.SetFocus()
    Keys '^a'
    [System.Windows.Forms.Clipboard]::SetText($Value)
    Keys '^v'
}
function Chon([string]$Name, [int]$Index, [string]$OptionName) {
    $Control = Wait-Moc { Find-Ui $Name -Focusable } 16 "Không tìm thấy mục $Name."
    $Control.SetFocus()
    Keys '{DOWN}'
    $null = Ui $OptionName
    Keys '{HOME}'
    if ($Index) { Keys "{DOWN $Index}" }
    Keys '{ENTER}'
}
function Mo-Nguon {
    $Settings = Wait-Moc { (Find-Ui 'Kết nối nguồn AI' -Focusable) ?? (Find-Ui 'Nguồn AI dựng bản đầu' -ButtonPrefix -Focusable) } 20 'Không thấy lối mở Hệ thống.'
    Click-Ui $Settings
    (Ui 'Nguồn AI của dự án').SetFocus()
    Keys '{ENTER}'
    Chon 'Tác vụ của dự án' 1 'Nhắn sửa, gợi ý tít và dịch lời'
}
function Luu-Nguon([string]$Provider, [int]$Index, [string]$Model, [string]$Shot) {
    Mo-Nguon
    Chon 'Nguồn của dự án' $Index $Provider
    Dien 'Model của dự án' $Model
    (Ui 'Lưu cho dự án').SetFocus()
    Keys '{ENTER}'
    $null = Ui 'Đã lưu cho dự án.'
    $null = Wait-Moc { Find-Ui "Đang dùng $Provider · $Model." -TextPrefix } 12 'Vèo không hiện model vừa lưu.'
    $null = Anh $Shot
    (Ui 'Xong').SetFocus()
    Keys '{ENTER}'
    $null = Ui 'Nhắn hệ thống'
}
function Nhan([string]$Text, [string]$Reply, [string]$Shot) {
    Dien 'Nhắn hệ thống' $Text
    Keys '{ENTER}'
    $null = Wait-Moc { Find-Ui $Reply -TextPrefix } 38 "Chưa thấy phản hồi $Reply."
    $null = Anh $Shot
}
function Xuat([string]$Name, [int]$Frames) {
    $Button = Wait-Moc { (Find-Ui 'Xuất lại' -Focusable) ?? (Find-Ui 'Xuất video' -Focusable) } 15 'Chưa thấy nút xuất.'
    Mouse-Ui $Button
    Click-Ui (Ui '720p')
    Dien 'Tên tệp' $Name
    Keys '{TAB}'
    (Ui 'Xuất 1 tệp').SetFocus()
    Keys '{ENTER}'
    $null = Wait-Moc { Find-Ui 'Thành phẩm' } 120 'Video chưa xuất xong.'
    $Output = @(Get-ChildItem -LiteralPath (Join-Path $Data 'du-an') -Recurse -File -Filter "$Name.mp4")
    if ($Output.Count -ne 1 -or !$Output[0].Length) { throw "Thiếu MP4 $Name hoặc bị trùng." }
    $ProbeInfo = (& $Probe -v error -show_entries 'stream=codec_name,width,height,nb_frames,avg_frame_rate' -of json $Output[0].FullName | ConvertFrom-Json).streams
    $V = $ProbeInfo | Where-Object codec_name -eq h264
    if ($LASTEXITCODE -ne 0 -or $V.width -ne 1280 -or $V.height -ne 720 -or $V.nb_frames -ne "$Frames" -or $V.avg_frame_rate -ne '30/1' -or 'aac' -notin $ProbeInfo.codec_name) {
        throw "Sai thông số MP4 $Name. $($ProbeInfo | ConvertTo-Json -Compress)"
    }
    Copy-Item -LiteralPath $Output[0].FullName -Destination (Join-Path $Proof "$Name.mp4")
    return [ordered]@{ name=$Name; frames=$Frames; path=$Output[0].FullName; sha256=(Get-FileHash -LiteralPath $Output[0].FullName).Hash.ToLowerInvariant() }
}
function Kiem-Mau($Output, [string]$At, [int]$Channel) {
    $Frame = Join-Path $Proof "$($Output.name)-$At.png"
    & $FFmpeg -v error -ss $At -i $Output.path -frames:v 1 -threads 1 $Frame
    if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $Frame -PathType Leaf)) { throw 'Không đọc được khung đối chiếu.' }
    $Rgb = @(Read-Color $Frame .5 .5)
    if ($Rgb[$Channel] -lt 225 -or @((0..2) | Where-Object { $_ -ne $Channel -and $Rgb[$_] -gt 25 }).Count) {
        throw "Sai màu tệp $($Output.name) tại giây $At. RGB $Rgb."
    }
}

$Firewall = "Veo-QA-WebView2-$env:GITHUB_RUN_ID"
$env:WEBVIEW2_USER_DATA_FOLDER = Join-Path $Qa 'webview2'
$Shell = New-Object -ComObject WScript.Shell
$CliDir = Join-Path $Qa 'cli-thu'
New-Item -ItemType Directory -Path $CliDir | Out-Null
$Codex = Join-Path $CliDir 'codex.exe'
$Agy = Join-Path $CliDir 'agy.exe'
$Compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (!(Test-Path $Compiler)) { throw 'Máy thử thiếu trình dịch C# có sẵn của Windows.' }
& $Compiler /nologo /target:exe /platform:x64 /reference:System.Web.Extensions.dll "/out:$Codex" (Join-Path $Qa 'cli-thu-veo.cs')
if ($LASTEXITCODE -ne 0) { throw 'Không dựng được CLI giả lập.' }
Copy-Item -LiteralPath $Codex -Destination $Agy
$env:DUNG_CODEX = $Codex
$env:DUNG_AGY = $Agy
$env:CODEX_HOME = Join-Path $CliDir 'codex-kho-trong'
New-Item -ItemType Directory -Path $env:CODEX_HOME | Out-Null
$CliLog = Join-Path $CliDir 'luot-cli.jsonl'
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
    $Clip = Join-Path $Proof 'Ba Mau Thu AI.mp4'
    $Filter = "drawbox=x=0:y=0:w=iw:h=ih:color=0x00ff00:t=fill:enable='gte(t,2)*lt(t,4)',drawbox=x=0:y=0:w=iw:h=ih:color=blue:t=fill:enable='gte(t,4)'"
    & $FFmpeg -v error -f lavfi -i 'color=c=red:s=640x360:r=30:d=6' -f lavfi -i 'sine=f=431:r=48000:d=6' -vf $Filter -t 6 -c:v libx264 -threads 1 -preset ultrafast -c:a aac $Clip
    if ($LASTEXITCODE -ne 0) { throw 'Không tạo được clip ba màu thử.' }
    Mouse-Ui (Ui 'Ngang 16:9')
    Click-Ui (Ui 'Cài dựng clip mới')
    Chon 'Cách dựng clip mới' 2 'Theo hình'
    $null = Ui 'Vèo tìm điểm đổi cảnh tại máy. Có thể lấy lại mép đen đã rút trong Chỉnh nhanh → Cảnh.'
    Click-Ui (Ui 'Xong')
    Mouse-Ui (Ui 'Thả clip quay thô')
    Choose-File 'Chọn clip quay thô' $Clip
    $null = Wait-Moc { Find-Ui 'Xuất video' -Focusable } 110 'Clip ba màu chưa dựng xong.'
    $Base = Xuat 'QA Goc' 180
    Kiem-Mau $Base '0.5' 0
    Kiem-Mau $Base '2.5' 1
    Kiem-Mau $Base '4.5' 2
    Write-Host 'Đã xuất clip gốc 180 khung.'

    Luu-Nguon 'Codex' 2 'gpt-qa-cut' '01-model-codex'
    Nhan 'Bỏ đoạn đỏ từ giây 0 đến 2.' 'Đã bỏ đoạn đỏ đầu video.' '02-codex-cat-dau'
    $CutOnce = Xuat 'QA Codex' 120
    Kiem-Mau $CutOnce '0.5' 1
    Kiem-Mau $CutOnce '2.5' 2
    Write-Host 'Codex cắt đúng đoạn đỏ. MP4 còn 120 khung.'

    New-Item -ItemType File -Path (Join-Path $CliDir 'het-phien-codex') | Out-Null
    Nhan 'Giữ nguyên bản dựng khi phiên hết hạn.' 'Kết nối Codex bằng tài khoản ChatGPT trong Hệ thống để tiếp tục.' '03-codex-het-phien'
    if (@(Get-Content -LiteralPath $CliLog).Count -ne 1) { throw 'Vẫn gọi model sau khi phiên Codex hết hạn.' }
    if ((Get-FileHash -LiteralPath $CutOnce.path).Hash -ne $CutOnce.sha256) { throw 'Phiên hết hạn làm đổi thành phẩm.' }
    Write-Host 'Vèo yêu cầu kết nối lại khi phiên Codex hết hạn.'

    Luu-Nguon 'Antigravity' 3 'gemini-qa-cut-high' '04-model-antigravity'
    Nhan 'Bỏ đoạn xanh lam từ giây 4 đến 6 của clip nguồn.' 'Đã bỏ đoạn xanh lam cuối video.' '05-antigravity-cat-cuoi'
    $CutTwice = Xuat 'QA Hai Nguon' 60
    Kiem-Mau $CutTwice '0.3' 1
    Kiem-Mau $CutTwice '1.5' 1
    Write-Host 'Antigravity cắt đúng đoạn xanh lam. MP4 còn 60 khung.'

    Click-Ui (Ui 'Sửa tay')
    Click-Ui (Ui 'Hoàn tác (Ctrl+Z)')
    $null = Wait-Moc { Find-Ui 'Làm lại (Ctrl+Y)' -Focusable } 15 'Vèo chưa hoàn tác lượt sửa AI.'
    $null = Anh '06-hoan-tac-cat-ai'
    Mouse-Ui (Ui 'Tự động')
    $Undo = Xuat 'QA Hoan Tac' 120
    Kiem-Mau $Undo '2.5' 2
    Click-Ui (Ui 'Sửa tay')
    Click-Ui (Ui 'Làm lại (Ctrl+Y)')
    $null = Wait-Moc { Find-Ui 'Hoàn tác (Ctrl+Z)' -Focusable } 15 'Vèo chưa làm lại lượt sửa AI.'
    Mouse-Ui (Ui 'Tự động')
    $Redo = Xuat 'QA Lam Lai' 60
    Kiem-Mau $Redo '1.5' 1

    Keys '%{F4}'
    if (!$App.WaitForExit(15000)) { throw 'Vèo chưa đóng.' }
    $App = Start-Process $AppFile -WorkingDirectory $Install -PassThru
    $null = Wait-Moc { Find-Ui 'Thành phẩm' } 70 'Vèo mở lại chưa thấy MP4.'
    if (!$Shell.AppActivate($App.Id)) { throw 'Không lấy được tiêu điểm sau khi mở lại.' }
    Mo-Nguon
    $null = Wait-Moc { Find-Ui 'Đang dùng Antigravity · gemini-qa-cut-high.' -TextPrefix } 15 'Mở lại mất model của dự án.'
    (Ui 'Xong').SetFocus()
    Keys '{ENTER}'
    Mouse-Ui (Ui 'Phát')
    $null = Wait-Moc { Find-Ui 'Dừng' } 10 'MP4 cắt bằng hai nguồn không phát được sau khi mở lại.'
    $null = Anh '07-phat-sau-khi-mo-lai'
    $Files = @($Base,$CutOnce,$CutTwice,$Undo,$Redo)
    foreach ($File in $Files) {
        if ((Get-FileHash -LiteralPath $File.path).Hash -ne $File.sha256) { throw "Mở lại làm đổi $($File.name)." }
    }
    $Calls = @(Get-Content -LiteralPath $CliLog | ForEach-Object { ConvertFrom-Json $_ })
    if ($Calls.Count -ne 2 -or $Calls[0].provider -ne 'codex' -or $Calls[1].provider -ne 'agy' -or @($Calls | Where-Object { !$_.direct }).Count) {
        throw 'Không giữ đúng thứ tự hai lượt CLI trực tiếp.'
    }
    Copy-Item -LiteralPath $CliLog -Destination (Join-Path $Proof 'luot-cli.jsonl')
    $Report = [ordered]@{
        source=$env:VEO_QA_SOURCE; workerSha256=$env:VEO_QA_WORKER_SHA; system=$env:VEO_QA_OS
        providerFixtures=$true; calls=$Calls; expiredShown=$true; noCallWhenExpired=$true
        files=@($Files | ForEach-Object { @{ name=$_.name; frames=$_.frames; sha256=$_.sha256 } })
        undoRedo=$true; savedProjectModelAfterRestart=$true; reopenedAndPlayed=$true
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
