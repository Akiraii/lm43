<#
.SYNOPSIS
    Запрос статуса /api/v2/status с Basic-аутентификацией, парсингом JSON,
    предложением инициализации при "not_configured" и ожиданием при "initialization".
    В режиме ожидания показывает изменение данных dbState, перерисовывая
    один блок (без скроллинга) — только счетчики, без LastUpdate.
.DESCRIPTION
    Выполняет GET-запрос к http://<хост>:<порт>/api/v2/status.
    - При "not_configured" предлагает выполнить инициализацию.
    - При "initialization" опрашивает статус каждые 30 секунд,
      отображая текущие docCount в одном перерисовываемом блоке.
    Все параметры запрашиваются интерактивно с умолчаниями.
    В конце ожидает нажатия любой клавиши.
.PARAMETER Login
    Имя пользователя.
.PARAMETER Password
    Пароль.
.PARAMETER HostName
    Хост или IP.
.PARAMETER Port
    Порт (по умолчанию 5995).
.PARAMETER Server
    Строка "хост:порт" (игнорирует HostName и Port, если указана).
.EXAMPLE
    .\check_status.ps1
.EXAMPLE
    .\check_status.ps1 -Login vh -Password 242466 -HostName 192.168.0.97 -Port 5995
#>

param(
    [string]$Login,
    [string]$Password,
    [string]$HostName,
    [int]$Port = 0,
    [string]$Server
)

# Безопасный ввод пароля с умолчанием "admin"
function Read-Password {
    $pass = Read-Host "Введите пароль (по умолчанию admin)" -AsSecureString
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($pass)
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        if ([string]::IsNullOrEmpty($plain)) { return "admin" }
        return $plain
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::FreeBSTR($BSTR)
    }
}

# Ввод параметров с умолчаниями
if (-not $Login) {
    $Login = Read-Host "Введите логин (по умолчанию admin)"
    if ([string]::IsNullOrEmpty($Login)) { $Login = "admin" }
}
if (-not $Password) {
    $Password = Read-Password
}

if ($Server) {
    $parts = $Server -split ':'
    $HostName = $parts[0]
    if ($parts.Length -gt 1) { $Port = [int]$parts[1] } elseif ($Port -eq 0) { $Port = 5995 }
} else {
    if (-not $HostName) {
        $HostName = Read-Host "Введите хост (по умолчанию localhost)"
        if ([string]::IsNullOrEmpty($HostName)) { $HostName = "localhost" }
    }
    if ($Port -eq 0) {
        $portInput = Read-Host "Введите порт (по умолчанию 5995)"
        if ([string]::IsNullOrEmpty($portInput)) { $Port = 5995 } else { $Port = [int]$portInput }
    }
}
if ($Port -eq 0) { $Port = 5995 }

$baseUri = "http://${HostName}:${Port}"
$uri = $baseUri + "/api/v2/status"

Write-Host "`nЗапрос к $uri ..." -ForegroundColor Green

# Base64 для Basic-авторизации
$pair = "${Login}:${Password}"
$bytes = [System.Text.Encoding]::ASCII.GetBytes($pair)
$base64 = [System.Convert]::ToBase64String($bytes)
$authHeader = @{ Authorization = "Basic $base64" }

# Функция получения статуса
function Get-Status {
    param($Uri, $Headers)
    return Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get -ErrorAction Stop
}

try {
    $response = Get-Status -Uri $uri -Headers $authHeader

    # --- not_configured: инициализация ---
    if ($response.status -eq "not_configured") {
        Write-Host "`nВнимание: статус сервера — not_configured. Требуется инициализация." -ForegroundColor Yellow
        $token = Read-Host "Введите X-API-Key токен для инициализации"
        if ([string]::IsNullOrEmpty($token)) {
            Write-Host "Токен не введён, инициализация отменена." -ForegroundColor Red
        } else {
            $initUri = $baseUri + "/api/v2/init"
            $initBody = @{ token = $token } | ConvertTo-Json
            $initHeaders = @{
                Authorization = "Basic $base64"
                "Content-Type"  = "application/json"
            }

            Write-Host "Отправка инициализации на $initUri ..." -ForegroundColor Green
            try {
                $initResponse = Invoke-RestMethod -Uri $initUri -Headers $initHeaders -Method Post -Body $initBody -ErrorAction Stop
                Write-Host "Инициализация выполнена успешно." -ForegroundColor Green
                Write-Host "Ответ инициализации:" -ForegroundColor Cyan
                $initResponse | ConvertTo-Json -Depth 5 | Write-Host

                Write-Host "`nПовторный запрос статуса..." -ForegroundColor Green
                $response = Get-Status -Uri $uri -Headers $authHeader
            } catch {
                Write-Host "Ошибка при инициализации: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "`nНажмите любую клавишу для выхода..." -ForegroundColor DarkGray
                $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
                exit 1
            }
        }
    }

    # --- Ожидание при initialization с перерисовкой одного блока (только счетчики) ---
    $iteration = 0
    $blockTop = 0
    $blockHeight = 5   # строк: заголовок, "DB State сейчас:", три счетчика (или "—")

    while ($response.status -eq "initialization") {
        $iteration++

        if ($iteration -eq 1) {
            $blockTop = [Console]::CursorTop
            for ($i=0; $i -lt $blockHeight; $i++) { Write-Host "" }
        }

        $newLines = [System.Collections.Generic.List[string]]::new()
        $header = "[$iteration] Статус: initialization. Ожидание 30 сек. (Ctrl+C для выхода)"
        $newLines.Add($header)
        $newLines.Add("  DB State сейчас:")

        if ($response.dbState) {
            $db = $response.dbState
            $newLines.Add("    min_price.docCount    : " + $(if ($db.min_price) { $db.min_price.docCount } else { "—" }))
            $newLines.Add("    blocked_gtin.docCount : " + $(if ($db.blocked_gtin) { $db.blocked_gtin.docCount } else { "—" }))
            $newLines.Add("    blocked_cis.docCount  : " + $(if ($db.blocked_cis) { $db.blocked_cis.docCount } else { "—" }))
        } else {
            $newLines.Add("    (нет данных)")
            $newLines.Add("")
            $newLines.Add("")
        }

        # Дополняем до 5 строк пустыми, если нужно
        while ($newLines.Count -lt $blockHeight) { $newLines.Add("") }

        # Перерисовка блока
        [Console]::SetCursorPosition(0, $blockTop)
        $width = [Console]::WindowWidth
        foreach ($line in $newLines) {
            if ($line.Length -gt $width - 1) {
                $line = $line.Substring(0, $width - 1)
            } else {
                $line = $line.PadRight($width - 1)
            }
            Write-Host $line -NoNewline
            [Console]::CursorTop += 1
            [Console]::CursorLeft = 0
        }

        Start-Sleep -Seconds 30

        try {
            $response = Get-Status -Uri $uri -Headers $authHeader
        } catch {
            [Console]::SetCursorPosition(0, $blockTop + $blockHeight)
            Write-Host "Ошибка при проверке статуса: $($_.Exception.Message)" -ForegroundColor Red
            break
        }
    }

    # Перемещаемся за блок
    if ($iteration -gt 0) {
        [Console]::SetCursorPosition(0, $blockTop + $blockHeight)
    }

    # --- Финальный вывод ---
    Write-Host "`n=== Ответ сервера (основные поля) ===" -ForegroundColor Cyan
    Write-Host "Version       : $($response.version)"
    Write-Host "Status        : $($response.status)"
    Write-Host "OperationMode : $($response.operationMode)"
    Write-Host "Name          : $($response.name)"
    Write-Host "INN           : $($response.inn)"
    Write-Host "Inst          : $($response.inst)"
    Write-Host "IsGreyGtin    : $($response.isGreyGtin)"
    Write-Host "ServiceUrl    : $($response.serviceUrl)"
    Write-Host "DB Version    : $($response.dbVersion)"

    if ($response.lastUpdate) {
        $dt = [DateTimeOffset]::FromUnixTimeMilliseconds($response.lastUpdate).LocalDateTime
        Write-Host "LastUpdate    : $($response.lastUpdate) -> $($dt.ToString('yyyy-MM-dd HH:mm:ss'))"
    }
    if ($response.lastSync) {
        $dtSync = [DateTimeOffset]::FromUnixTimeMilliseconds($response.lastSync).LocalDateTime
        Write-Host "LastSync      : $($response.lastSync) -> $($dtSync.ToString('yyyy-MM-dd HH:mm:ss'))"
    }

    if ($response.dbState) {
        Write-Host "`n--- DB State ---" -ForegroundColor Yellow
        $db = $response.dbState
        if ($db.min_price) {
            Write-Host "min_price.docCount    : $($db.min_price.docCount)"
        }
        if ($db.blocked_gtin) {
            Write-Host "blocked_gtin.docCount : $($db.blocked_gtin.docCount)"
        }
        if ($db.blocked_cis) {
            Write-Host "blocked_cis.docCount  : $($db.blocked_cis.docCount)"
        }
    }

} catch {
    Write-Host "`nОшибка при выполнении запроса:" -ForegroundColor Red
    Write-Host $_.Exception.Message
}

Write-Host "`nНажмите любую клавишу для выхода..." -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
