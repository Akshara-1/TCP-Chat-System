# Windows Forms Chat Client for Haskell Server
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Create the form
$form = New-Object System.Windows.Forms.Form
$form.Text = "Haskell Chat Client"
$form.Size = New-Object System.Drawing.Size(900, 700)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#1e1e1e")
$form.KeyPreview = $true

# Create menu strip
$menuStrip = New-Object System.Windows.Forms.MenuStrip
$menuStrip.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#2d2d2d")

$fileMenu = New-Object System.Windows.Forms.ToolStripMenuItem
$fileMenu.Text = "File"
$fileMenu.ForeColor = [System.Drawing.Color]::White

$connectMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
$connectMenuItem.Text = "Connect"
$connectMenuItem.Add_Click({ Connect-ToServer })

$disconnectMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
$disconnectMenuItem.Text = "Disconnect"
$disconnectMenuItem.Enabled = $false
$disconnectMenuItem.Add_Click({ Disconnect-FromServer })

$exitMenuItem = New-Object System.Windows.Forms.ToolStripMenuItem
$exitMenuItem.Text = "Exit"
$exitMenuItem.Add_Click({ $form.Close() })

$fileMenu.DropDownItems.AddRange(@($connectMenuItem, $disconnectMenuItem, $exitMenuItem))
$menuStrip.Items.Add($fileMenu) | Out-Null

# Create main panel
$mainPanel = New-Object System.Windows.Forms.Panel
$mainPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$mainPanel.Padding = New-Object System.Windows.Forms.Padding(10)
$mainPanel.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#1e1e1e")

# Create chat display
$chatBox = New-Object System.Windows.Forms.RichTextBox
$chatBox.Location = New-Object System.Drawing.Point(10, 30)
$chatBox.Size = New-Object System.Drawing.Size(860, 520)
$chatBox.ReadOnly = $true
$chatBox.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#252526")
$chatBox.ForeColor = [System.Drawing.ColorTranslator]::FromHtml("#d4d4d4")
$chatBox.Font = New-Object System.Drawing.Font("Consolas", 10)
$chatBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$chatBox.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Vertical

# Create input panel
$inputPanel = New-Object System.Windows.Forms.Panel
$inputPanel.Location = New-Object System.Drawing.Point(10, 560)
$inputPanel.Size = New-Object System.Drawing.Size(860, 80)
$inputPanel.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#1e1e1e")

# Create input textbox
$inputBox = New-Object System.Windows.Forms.TextBox
$inputBox.Location = New-Object System.Drawing.Point(0, 0)
$inputBox.Size = New-Object System.Drawing.Size(770, 80)
$inputBox.Multiline = $true
$inputBox.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#3c3c3c")
$inputBox.ForeColor = [System.Drawing.Color]::White
$inputBox.Font = New-Object System.Drawing.Font("Consolas", 10)
$inputBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$inputBox.Enabled = $false

# Create send button
$sendButton = New-Object System.Windows.Forms.Button
$sendButton.Location = New-Object System.Drawing.Point(780, 0)
$sendButton.Size = New-Object System.Drawing.Size(80, 80)
$sendButton.Text = "Send"
$sendButton.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#0e639c")
$sendButton.ForeColor = [System.Drawing.Color]::White
$sendButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$sendButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$sendButton.Enabled = $false
$sendButton.Cursor = [System.Windows.Forms.Cursors]::Hand

$inputPanel.Controls.Add($inputBox)
$inputPanel.Controls.Add($sendButton)

# Create status strip
$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusStrip.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#007acc")

$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = "Disconnected - Click File -> Connect"
$statusLabel.ForeColor = [System.Drawing.Color]::White
$statusStrip.Items.Add($statusLabel) | Out-Null

$mainPanel.Controls.Add($chatBox)
$mainPanel.Controls.Add($inputPanel)

$form.Controls.Add($mainPanel)
$form.Controls.Add($menuStrip)
$form.Controls.Add($statusStrip)
$form.MainMenuStrip = $menuStrip

# Global variables
$script:client       = $null
$script:stream       = $null
$script:reader       = $null
$script:writer       = $null
$script:connected    = $false
$script:receiveTimer = $null
$script:username     = $null

# -- Helpers ---

function Add-Message {
    param([string]$message, [string]$color = "#d4d4d4")
    if ($chatBox.InvokeRequired) {
        $chatBox.Invoke([Action[string,string]]{ param($m,$c) Add-Message -message $m -color $c }, $message, $color)
        return
    }
    $timestamp = Get-Date -Format "HH:mm:ss"
    $chatBox.SelectionStart  = $chatBox.TextLength
    $chatBox.SelectionLength = 0
    $chatBox.SelectionColor  = [System.Drawing.ColorTranslator]::FromHtml("#888888")
    $chatBox.AppendText("[$timestamp] ")
    $chatBox.SelectionColor  = [System.Drawing.ColorTranslator]::FromHtml($color)
    $chatBox.AppendText("$message`r`n")
    $chatBox.ScrollToCaret()
}

# -- Receive timer tick (runs on UI thread - safe to touch controls) ------------------------------------

$receiveTickHandler = {
    if (-not $script:connected -or $null -eq $script:reader) { return }
    try {
        # StreamReader may have internally buffered data even when Available==0,
        # so drain its buffer first, then also drain the OS socket buffer.
        while ($script:reader.Peek() -ge 0 -or $script:client.Available -gt 0) {
            $msg = $script:reader.ReadLine()   # ReadTimeout=80ms prevents blocking the UI
            if ($null -ne $msg) {
                Add-Message -message $msg -color "#ffffff"
            }
        }
    } catch [System.IO.IOException] {
        # ReadTimeout expired - just a partial line in transit, try again next tick
    } catch {
        Add-Message -message "Connection lost: $_" -color "#ff4444"
        Disconnect-FromServer
    }
}

# -- Connect ---

function Connect-ToServer {
    try {
        Add-Message -message "Connecting to localhost:1234..." -color "#ffff00"

        $script:client = New-Object System.Net.Sockets.TcpClient
        $script:client.Connect("localhost", 1234)
        $script:stream = $script:client.GetStream()
        $script:reader = New-Object System.IO.StreamReader($script:stream, [System.Text.Encoding]::UTF8)
        $script:writer = New-Object System.IO.StreamWriter($script:stream, [System.Text.Encoding]::UTF8)
        $script:writer.AutoFlush = $true
        # NetworkStream supports ReadTimeout - caps how long ReadLine can block the UI thread
        $script:stream.ReadTimeout = 80   # ms - slightly longer than timer interval (50ms)

        # Drain welcome banner with a short timeout window
        $deadline = (Get-Date).AddMilliseconds(800)
        while ((Get-Date) -lt $deadline) {
            if ($script:client.Available -gt 0) {
                $line = $script:reader.ReadLine()
                if ($null -ne $line) {
                    Add-Message -message $line -color "#00ffff"
                    $deadline = (Get-Date).AddMilliseconds(400)
                }
            } else { Start-Sleep -Milliseconds 50 }
        }

        # Username dialog
        $usernameForm = New-Object System.Windows.Forms.Form
        $usernameForm.Text = "Enter Username"
        $usernameForm.Size = New-Object System.Drawing.Size(350, 150)
        $usernameForm.StartPosition = "CenterScreen"
        $usernameForm.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#1e1e1e")
        $usernameForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog

        $usernameLabel = New-Object System.Windows.Forms.Label
        $usernameLabel.Text = "Username:"
        $usernameLabel.Location = New-Object System.Drawing.Point(20, 20)
        $usernameLabel.Size = New-Object System.Drawing.Size(100, 25)
        $usernameLabel.ForeColor = [System.Drawing.Color]::White

        $usernameInput = New-Object System.Windows.Forms.TextBox
        $usernameInput.Location = New-Object System.Drawing.Point(120, 20)
        $usernameInput.Size = New-Object System.Drawing.Size(200, 25)
        $usernameInput.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#3c3c3c")
        $usernameInput.ForeColor = [System.Drawing.Color]::White

        $okButton = New-Object System.Windows.Forms.Button
        $okButton.Text = "Connect"
        $okButton.Location = New-Object System.Drawing.Point(120, 60)
        $okButton.Size = New-Object System.Drawing.Size(100, 30)
        $okButton.BackColor = [System.Drawing.ColorTranslator]::FromHtml("#0e639c")
        $okButton.ForeColor = [System.Drawing.Color]::White
        $okButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $usernameForm.AcceptButton = $okButton
        $okButton.Add_Click({
            $raw = $usernameInput.Text.Trim()
            # Only allow alphanumeric, underscore, hyphen (what Haskell server accepts)
            $clean = $raw -replace '[^a-zA-Z0-9_\-]', ''
            if ($clean.Length -eq 0) {
                [System.Windows.Forms.MessageBox]::Show(
                    "Username must contain at least one letter or number.`nSpecial characters are not allowed.",
                    "Invalid Username",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null
                return
            }
            if ($clean -ne $raw) {
                $usernameInput.Text = $clean
                $usernameInput.SelectionStart = $clean.Length
                return   # let user review the cleaned name before confirming
            }
            $script:username = $clean
            $usernameForm.Close()
        })

        $usernameForm.Controls.AddRange(@($usernameLabel, $usernameInput, $okButton))
        $usernameForm.ShowDialog() | Out-Null

        if (-not $script:username) {
            Add-Message -message "Connection cancelled." -color "#ff8888"
            $script:client.Close(); $script:client = $null
            return
        }

        # Send username to server
        $script:writer.WriteLine($script:username)

        # Drain server response (join message, etc.)
        $deadline = (Get-Date).AddMilliseconds(800)
        while ((Get-Date) -lt $deadline) {
            if ($script:client.Available -gt 0) {
                $line = $script:reader.ReadLine()
                if ($null -ne $line) {
                    Add-Message -message $line -color "#00ff00"
                    $deadline = (Get-Date).AddMilliseconds(400)
                }
            } else { Start-Sleep -Milliseconds 50 }
        }

        # Mark connected, enable UI
        $script:connected           = $true
        $statusLabel.Text           = "Connected as: $script:username"
        $connectMenuItem.Enabled    = $false
        $disconnectMenuItem.Enabled = $true
        $inputBox.Enabled           = $true
        $sendButton.Enabled         = $true
        $inputBox.Focus()
        Add-Message -message "=== Connected! Commands: /who  /tell <user> <msg>  /help  /quit ===" -color "#88ff88"

        # Start receive timer (50 ms poll - snappy and non-blocking)
        $script:receiveTimer          = New-Object System.Windows.Forms.Timer
        $script:receiveTimer.Interval = 50
        $script:receiveTimer.Add_Tick($receiveTickHandler)
        $script:receiveTimer.Start()

    } catch {
        Add-Message -message "Failed to connect: $_" -color "#ff0000"
        if ($script:client) { try { $script:client.Close() } catch {} ; $script:client = $null }
    }
}

# -- Send ------------

function Send-Message {
    if (-not $script:connected) { return }
    $msg = $inputBox.Text.Trim()
    if (-not $msg) { return }

    try {
        $script:writer.WriteLine($msg)
        $inputBox.Clear()

        # Echo locally; server broadcasts to all OTHER clients
        switch -Regex ($msg) {
            "^/quit$" {
                Disconnect-FromServer
                return        # writer is now null - stop here
            }
            "^/who$" {
                Add-Message -message ">> /who sent - waiting for server..." -color "#aaaaff"
                break
            }
            "^/help$" {
                Add-Message -message ">> /help sent - waiting for server..." -color "#aaaaff"
                break
            }
            "^/tell\s+\S+\s+.+" {
                $parts = $msg -split '\s+', 3
                Add-Message -message ">> You told $($parts[1]): $($parts[2])" -color "#aaaaff"
                break
            }
            "^/tell" {
                # Malformed /tell - don't send, warn instead
                Add-Message -message "Usage: /tell <username> <message>" -color "#ff8844"
                $inputBox.Text = $msg   # put it back so user can fix it
                break
            }
            default {
                Add-Message -message "You: $msg" -color "#88ff88"
            }
        }
    } catch {
        Add-Message -message "Send failed: $_" -color "#ff0000"
        Disconnect-FromServer
    }
}

# -- Disconnect ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

function Disconnect-FromServer {
    if ($script:receiveTimer) {
        $script:receiveTimer.Stop()
        $script:receiveTimer.Dispose()
        $script:receiveTimer = $null
    }
    if ($script:writer) { try { $script:writer.Close() } catch {} ; $script:writer = $null }
    if ($script:reader) { try { $script:reader.Close() } catch {} ; $script:reader = $null }
    if ($script:stream) { try { $script:stream.Close() } catch {} ; $script:stream = $null }
    if ($script:client) { try { $script:client.Close() } catch {} ; $script:client = $null }

    $script:connected = $false
    $script:username  = $null

    $statusLabel.Text           = "Disconnected - Click File -> Connect"
    $connectMenuItem.Enabled    = $true
    $disconnectMenuItem.Enabled = $false
    $inputBox.Enabled           = $false
    $sendButton.Enabled         = $false
    Add-Message -message "=== Disconnected ===" -color "#ff8888"
}

# -- Event wiring ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------

$sendButton.Add_Click({ Send-Message })
$inputBox.Add_KeyDown({
    if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $_.SuppressKeyPress = $true
        $_.Handled = $true
        Send-Message
    }
})
$form.Add_FormClosing({ Disconnect-FromServer })

# -- Startup ---

Add-Message -message "=== Haskell Chat Client ===" -color "#88ff88"
Add-Message -message "Click File -> Connect to start" -color "#ffff00"
Add-Message -message "Commands: /who  /tell <user> <msg>  /help  /quit" -color "#88ff88"

[System.Windows.Forms.Application]::Run($form)