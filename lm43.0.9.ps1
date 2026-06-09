<#
.SYNOPSIS
    Запрос статуса /api/v2/status с Basic-аутентификацией, парсингом JSON,
    предложением инициализации при "не сконфигурирован" и ожиданием при "инициализация".
    В режиме ожидания показывает изменение данных dbState, перерисовывая
    один блок (без скроллинга) — только счётчики МРЦ, Заблокированные GTIN, Заблокированные КМ.
.DESCRIPTION
    Выполняет GET-запрос к http://<хост>:<порт>/api/v2/status.
    - При статусе "not_configured" предлагает выполнить инициализацию (POST /api/v2/init).
    - При статусе "initialization" опрашивает статус каждые 30 секунд,
      отображая текущие счётчики в одном перерисовываемом блоке.
    Все параметры запрашиваются интерактивно с умолчаниями:
      логин/пароль – admin/admin, хост – localhost, порт – 5995.
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

# Функция перевода английских статусов в русские
function Translate-Status {
    param($status)
    switch ($status) {
        "not_configured" { return "не сконфигурирован" }
        "initialization" { return "инициализация" }
        "ready"          { return "готов" }
        "active"         { return "штатный" }
        default          { return $status }
    }
}

try {
    $response = Get-Status -Uri $uri -Headers $authHeader

    # --- not_configured: инициализация ---
    if ($response.status -eq "not_configured") {
        Write-Host "`nВнимание: статус сервера — «не сконфигурирован». Требуется инициализация." -ForegroundColor Yellow
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

    # --- Ожидание при initialization с перерисовкой блока (надёжное выравнивание) ---
    $iteration = 0
    $blockTop = 0
    $blockHeight = 5
    $labelWidth = 22   # ширина для меток (по самой длинной — "Заблокированные GTIN")

    while ($response.status -eq "initialization") {
        $iteration++

        if ($iteration -eq 1) {
            $blockTop = [Console]::CursorTop
            for ($i=0; $i -lt $blockHeight; $i++) { Write-Host "" }
        }

        $newLines = [System.Collections.Generic.List[string]]::new()
        $header = "[$iteration] Статус: инициализация. Ожидание 30 сек. (Ctrl+C для выхода)"
        $newLines.Add($header)
        $newLines.Add("  Текущие данные:")

        if ($response.dbState) {
            $db = $response.dbState

            $mrcLabel = "МРЦ".PadRight($labelWidth)
            $mrcVal = if ($db.min_price) { $db.min_price.docCount } else { "—" }
            $newLines.Add("    ${mrcLabel} : $mrcVal")

            $gtinLabel = "Заблокированные GTIN".PadRight($labelWidth)
            $gtinVal = if ($db.blocked_gtin) { $db.blocked_gtin.docCount } else { "—" }
            $newLines.Add("    ${gtinLabel} : $gtinVal")

            $cisLabel = "Заблокированные КМ".PadRight($labelWidth)
            $cisVal = if ($db.blocked_cis) { $db.blocked_cis.docCount } else { "—" }
            $newLines.Add("    ${cisLabel} : $cisVal")
        } else {
            $newLines.Add("    (нет данных)")
            $newLines.Add("")
            $newLines.Add("")
        }

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

    if ($iteration -gt 0) {
        [Console]::SetCursorPosition(0, $blockTop + $blockHeight)
    }

    # --- Финальный вывод с автоматическим выравниванием ---
    Write-Host "`n=== Ответ сервера (основные поля) ===" -ForegroundColor Cyan

    # Собираем данные в упорядоченный словарь (сохраняет порядок)
    $data = [ordered]@{
        "Версия ПО"                       = $response.version
        "Статус"                          = Translate-Status $response.status
        "Режим работы"                    = if ($response.operationMode -eq 'active') {'штатный'} else {$response.operationMode}
        "Название ПО"                     = $response.name
        "ИНН участника оборота"           = $response.inn
        "Идентификатор экземпляра ПО"     = $response.inst
        "Проверка серых списков (GreyGtin)" = if ($response.isGreyGtin) {'включено'} else {'отключено'}
        "Адрес сервиса"                   = $response.serviceUrl
        "Идентификатор базы данных"       = $response.dbVersion
    }

    # Вычисляем максимальную длину ключа
    $maxKeyLength = ($data.Keys | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum

    # Выводим с форматированием через PadRight
    foreach ($key in $data.Keys) {
        $label = $key.PadRight($maxKeyLength)
        $val = $data[$key]
        Write-Host "  ${label} : $val"
    }

    # Временные метки
    if ($response.lastUpdate) {
        $dt = [DateTimeOffset]::FromUnixTimeMilliseconds($response.lastUpdate).LocalDateTime
        $label = "Последнее обновление".PadRight($maxKeyLength)
        Write-Host "  ${label} : $($dt.ToString('yyyy-MM-dd HH:mm:ss'))"
    }
    if ($response.lastSync) {
        $dtSync = [DateTimeOffset]::FromUnixTimeMilliseconds($response.lastSync).LocalDateTime
        $label = "Последняя синхронизация".PadRight($maxKeyLength)
        Write-Host "  ${label} : $($dtSync.ToString('yyyy-MM-dd HH:mm:ss'))"
    }

    if ($response.dbState) {
        Write-Host "`n--- Состояние базы данных ---" -ForegroundColor Yellow
        $db = $response.dbState
        $labelWidthDB = $maxKeyLength  # используем ту же ширину для красоты
        if ($db.min_price) {
            $label = "МРЦ (документов)".PadRight($labelWidthDB)
            Write-Host "  ${label} : $($db.min_price.docCount)"
        }
        if ($db.blocked_gtin) {
            $label = "Заблокированные GTIN (документов)".PadRight($labelWidthDB)
            Write-Host "  ${label} : $($db.blocked_gtin.docCount)"
        }
        if ($db.blocked_cis) {
            $label = "Заблокированные КМ (документов)".PadRight($labelWidthDB)
            Write-Host "  ${label} : $($db.blocked_cis.docCount)"
        }
    }

} catch {
    Write-Host "`nОшибка при выполнении запроса:" -ForegroundColor Red
    Write-Host $_.Exception.Message
}

Write-Host "`nНажмите любую клавишу для выхода..." -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
