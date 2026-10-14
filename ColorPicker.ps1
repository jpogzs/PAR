#Requires -Version 5.1
<#
  ColorPicker.ps1
  Pick a color for each item, then save the values as text (Name=#RRGGBB, one per line).
  If ColorSettings.txt exists next to the script, it is loaded on start.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Make coordinates match real screen pixels on scaled (high-DPI) displays
if (-not ('DpiHelper' -as [type])) {
    Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public static class DpiHelper {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@
}
try { [void][DpiHelper]::SetProcessDPIAware() } catch {}

[System.Windows.Forms.Application]::EnableVisualStyles()

$baseDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$defaultFile = Join-Path $baseDir 'ColorSettings.txt'

# Item name -> default hex
$items = [ordered]@{
    'Inside Corner'                  = '#FF0000'
    'Outside Corner'                 = '#0000FF'
    'Obtuse Inside Corner'           = '#FF8000'
    'Obtuse Outside Corner'          = '#00A0FF'
    'Top Wall'                       = '#00C000'
    'Bottom Wall'                    = '#808000'
    'Material Horizontal Boundary'   = '#FF00FF'
    'Material Vertical Boundary'     = '#800080'
    'Material Oblique Boundary'      = '#00FFFF'
    'Material Top'                   = '#FFFF00'
    'Material Bottom'                = '#A52A2A'
    'Material Inside Corner'         = '#FF6666'
    'Material Outside Corner'        = '#6666FF'
    'Material Obtuse Inside Corner'  = '#FFB266'
    'Material Obtuse Outside Corner' = '#66D1FF'
    'Isoline'                        = '#808080'
}

function ConvertTo-Hex([System.Drawing.Color]$c) {
    '#{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B
}

function ConvertFrom-Hex([string]$hex) {
    if ($hex -match '^\s*#?([0-9A-Fa-f]{6})\s*$') {
        $h = $Matches[1]
        return [System.Drawing.Color]::FromArgb(
            [Convert]::ToInt32($h.Substring(0, 2), 16),
            [Convert]::ToInt32($h.Substring(2, 2), 16),
            [Convert]::ToInt32($h.Substring(4, 2), 16))
    }
    return $null
}

# ---------- Screen eyedropper ----------
# Freezes a snapshot of ALL monitors, shows it full-screen with a magnifier.
# Left click / Enter / Space = pick, Esc / right click = cancel, arrow keys = nudge 1px.
function Get-ScreenColor {
    $vs  = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height)
    $g   = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($vs.Location, [System.Drawing.Point]::Empty, $vs.Size)
    $g.Dispose()

    $loupeBmp = New-Object System.Drawing.Bitmap(121, 121)

    $ov = New-Object System.Windows.Forms.Form
    $ov.FormBorderStyle = 'None'
    $ov.StartPosition   = 'Manual'
    $ov.Bounds          = $vs
    $ov.TopMost         = $true
    $ov.ShowInTaskbar   = $false
    $ov.Cursor          = [System.Windows.Forms.Cursors]::Cross
    $ov.KeyPreview      = $true
    $ov.BackgroundImage = $bmp
    $ov.BackgroundImageLayout = 'None'
    $ov.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($ov, $true)

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Size = New-Object System.Drawing.Size(123, 146)
    $panel.BackColor = [System.Drawing.Color]::Black
    $pic = New-Object System.Windows.Forms.PictureBox
    $pic.Location = New-Object System.Drawing.Point(1, 1)
    $pic.Size = New-Object System.Drawing.Size(121, 121)
    $pic.Image = $loupeBmp
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Location = New-Object System.Drawing.Point(0, 123)
    $lbl.Size = New-Object System.Drawing.Size(123, 22)
    $lbl.ForeColor = [System.Drawing.Color]::White
    $lbl.BackColor = [System.Drawing.Color]::Black
    $lbl.TextAlign = 'MiddleCenter'
    $lbl.Font = New-Object System.Drawing.Font('Consolas', 10)
    $panel.Controls.Add($pic)
    $panel.Controls.Add($lbl)
    $ov.Controls.Add($panel)

    $st = @{ Color = $null }

    $update = {
        param([int]$x, [int]$y)
        if ($x -lt 0 -or $y -lt 0 -or $x -ge $bmp.Width -or $y -ge $bmp.Height) { return }
        $c  = $bmp.GetPixel($x, $y)
        $lg = [System.Drawing.Graphics]::FromImage($loupeBmp)
        $lg.Clear([System.Drawing.Color]::Black)
        $lg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
        $lg.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
        $dest = New-Object System.Drawing.Rectangle(0, 0, 121, 121)
        $lg.DrawImage($bmp, $dest, ($x - 5), ($y - 5), 11, 11, [System.Drawing.GraphicsUnit]::Pixel)
        $lg.DrawRectangle([System.Drawing.Pens]::Black, 55, 55, 10, 10)
        $lg.DrawRectangle([System.Drawing.Pens]::White, 56, 56, 8, 8)
        $lg.Dispose()
        $pic.Invalidate()
        $lbl.Text = ConvertTo-Hex $c

        $px = $x + 20; $py = $y + 20
        if ($px + 125 -gt $bmp.Width)  { $px = $x - 145 }
        if ($py + 148 -gt $bmp.Height) { $py = $y - 168 }
        $panel.Location = New-Object System.Drawing.Point($px, $py)
    }.GetNewClosure()

    $ov.Add_MouseMove({
        param($s, $e)
        & $update $e.X $e.Y
    }.GetNewClosure())

    $ov.Add_MouseDown({
        param($s, $e)
        if ($e.Button -eq 'Left') { $st.Color = $bmp.GetPixel($e.X, $e.Y) }
        $ov.Close()
    }.GetNewClosure())

    $ov.Add_KeyDown({
        param($s, $e)
        $p = [System.Windows.Forms.Cursor]::Position
        switch ($e.KeyCode) {
            'Escape' { $ov.Close() }
            'Left'   { $p.X -= 1; [System.Windows.Forms.Cursor]::Position = $p }
            'Right'  { $p.X += 1; [System.Windows.Forms.Cursor]::Position = $p }
            'Up'     { $p.Y -= 1; [System.Windows.Forms.Cursor]::Position = $p }
            'Down'   { $p.Y += 1; [System.Windows.Forms.Cursor]::Position = $p }
            { $_ -in 'Return', 'Space' } {
                $st.Color = $bmp.GetPixel($p.X - $vs.X, $p.Y - $vs.Y)
                $ov.Close()
            }
        }
        if ($ov.Visible) {
            $q = [System.Windows.Forms.Cursor]::Position
            & $update ($q.X - $vs.X) ($q.Y - $vs.Y)
        }
    }.GetNewClosure())

    $ov.Add_Shown({
        $ov.Activate()
        $q = [System.Windows.Forms.Cursor]::Position
        & $update ($q.X - $vs.X) ($q.Y - $vs.Y)
    }.GetNewClosure())

    [void]$ov.ShowDialog()
    $ov.Dispose(); $bmp.Dispose(); $loupeBmp.Dispose()
    return $st.Color
}

# ---------- Form ----------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Color Picker'
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.ClientSize = New-Object System.Drawing.Size(470, 640)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$swatches = @{}
$boxes    = @{}
$customColors = @()
$y = 15

$setColor = {
    param([string]$name, [System.Drawing.Color]$color)
    $swatches[$name].BackColor = $color
    $boxes[$name].Text = ConvertTo-Hex $color
}

foreach ($name in $items.Keys) {
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $name
    $lbl.Location = New-Object System.Drawing.Point(15, ($y + 5))
    $lbl.Size = New-Object System.Drawing.Size(210, 20)
    $form.Controls.Add($lbl)

    $btn = New-Object System.Windows.Forms.Button
    $btn.Location = New-Object System.Drawing.Point(230, $y)
    $btn.Size = New-Object System.Drawing.Size(70, 26)
    $btn.FlatStyle = 'Flat'
    $btn.Tag = $name
    $btn.BackColor = ConvertFrom-Hex $items[$name]
    $form.Controls.Add($btn)
    $swatches[$name] = $btn

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(310, ($y + 2))
    $txt.Size = New-Object System.Drawing.Size(80, 22)
    $txt.Text = $items[$name]
    $txt.Tag = $name
    $txt.MaxLength = 7
    $form.Controls.Add($txt)
    $boxes[$name] = $txt

    $pick = New-Object System.Windows.Forms.Button
    $pick.Text = 'Pick'
    $pick.Location = New-Object System.Drawing.Point(398, $y)
    $pick.Size = New-Object System.Drawing.Size(52, 26)
    $pick.Tag = $name
    $form.Controls.Add($pick)

    # Pick from screen (any app, any monitor)
    $pick.Add_Click({
        param($sender, $e)
        $n = $sender.Tag
        $form.Opacity = 0
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 250
        try { $c = Get-ScreenColor }
        finally { $form.Opacity = 1; $form.Activate() }
        if ($c) { & $setColor $n $c }
    }.GetNewClosure())

    # Click swatch -> color dialog
    $btn.Add_Click({
        param($sender, $e)
        $n = $sender.Tag
        $dlg = New-Object System.Windows.Forms.ColorDialog
        $dlg.FullOpen = $true
        $dlg.AnyColor = $true
        $dlg.Color = $sender.BackColor
        $dlg.CustomColors = $script:customColors
        if ($dlg.ShowDialog($form) -eq 'OK') {
            $script:customColors = $dlg.CustomColors
            & $setColor $n $dlg.Color
        }
    }.GetNewClosure())

    # Typing a valid hex -> update swatch
    $txt.Add_TextChanged({
        param($sender, $e)
        $c = ConvertFrom-Hex $sender.Text
        if ($c) {
            $swatches[$sender.Tag].BackColor = $c
            $sender.BackColor = [System.Drawing.SystemColors]::Window
        } else {
            $sender.BackColor = [System.Drawing.Color]::MistyRose
        }
    }.GetNewClosure())

    $y += 34
}

$y += 10

function Get-ValidationErrors {
    $bad = foreach ($n in $items.Keys) {
        if (-not (ConvertFrom-Hex $boxes[$n].Text)) { $n }
    }
    return $bad
}

function Save-Colors([string]$path) {
    $lines = foreach ($n in $items.Keys) {
        '{0}={1}' -f $n, (ConvertTo-Hex (ConvertFrom-Hex $boxes[$n].Text))
    }
    Set-Content -Path $path -Value $lines -Encoding UTF8
}

function Load-Colors([string]$path) {
    foreach ($line in Get-Content -Path $path) {
        if ($line -match '^\s*(.+?)\s*=\s*(#?[0-9A-Fa-f]{6})\s*$') {
            $n = $Matches[1]
            $c = ConvertFrom-Hex $Matches[2]
            if ($items.Contains($n) -and $c) { & $setColor $n $c }
        }
    }
}

# ---------- Buttons ----------
$btnLoad = New-Object System.Windows.Forms.Button
$btnLoad.Text = 'Load...'
$btnLoad.Location = New-Object System.Drawing.Point(15, $y)
$btnLoad.Size = New-Object System.Drawing.Size(90, 32)
$form.Controls.Add($btnLoad)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = 'Save...'
$btnSave.Location = New-Object System.Drawing.Point(350, $y)
$btnSave.Size = New-Object System.Drawing.Size(100, 32)
$form.Controls.Add($btnSave)

$btnLoad.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
    $dlg.InitialDirectory = $baseDir
    if ($dlg.ShowDialog($form) -eq 'OK') {
        try { Load-Colors $dlg.FileName }
        catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Load failed') | Out-Null }
    }
})

$btnSave.Add_Click({
    $bad = @(Get-ValidationErrors)
    if ($bad.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Fix these invalid hex values (use #RRGGBB):`n`n" + ($bad -join "`n"),
            'Invalid color') | Out-Null
        return
    }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'Text files (*.txt)|*.txt|All files (*.*)|*.*'
    $dlg.InitialDirectory = $baseDir
    $dlg.FileName = [System.IO.Path]::GetFileName($defaultFile)
    if ($dlg.ShowDialog($form) -eq 'OK') {
        try {
            Save-Colors $dlg.FileName
            [System.Windows.Forms.MessageBox]::Show("Saved to:`n$($dlg.FileName)", 'Saved') | Out-Null
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Save failed') | Out-Null
        }
    }
})

# Auto-load existing settings
if (Test-Path $defaultFile) {
    try { Load-Colors $defaultFile } catch {}
}

[void]$form.ShowDialog()
