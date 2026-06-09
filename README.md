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
