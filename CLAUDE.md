# И ВСЕ 3,14здец — памятка

Приложение для Mac — чат над Venice AI API. **Полный контекст — в `CONTEXT.md`, прочитай его первым.**

- Пользователь общается по-русски и не программист: отвечай просто, сначала результат.
- Интерфейс — `venice-chat/static/` (общий для приложения и браузерной версии).
- Маршруты `/api/*` есть в двух местах: `venice-chat/macapp/Backend.swift` и `venice-chat/server.py` — меняй оба.
- Сборка и `.dmg`: `./venice-chat/macapp/build.sh` (сначала `osascript -e 'quit app "И ВСЕ 3,14здец"'`).
- Самотест: `VENICE_SELFTEST=1 "$HOME/Applications/И ВСЕ 3,14здец.app/Contents/MacOS/VeniceChat"`;
  агент: добавь `VENICE_AGENTTEST="задание"`.
- Не переименовывать bundle id `local.venice.chat`, файл `VeniceChat`, папку данных `VeniceChat`.
- В `venice-chat/.env` — API-ключ владельца; он вшивается в сборку. Не публиковать.
- После тестов удаляй свои тестовые чаты и проекты; говори, сколько стоили запросы к Venice.
