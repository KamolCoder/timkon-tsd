# ТСД: проверка перемещений (FlutterFlow Custom Code)

Кладовщик открывает непроведённое перемещение «Склад → Магазин», сканирует собранный товар.
Приложение показывает недостачи, лишнее и пересорт, затем записывает фактические количества
в 1С (OData, по LAN). Проводит документ кладовщик в 1С.

## Файлы

| Файл | Тип в FlutterFlow |
|---|---|
| `custom_widgets/transfer_list_widget.dart` | Custom Widget `TransferListWidget` — список к проверке |
| `custom_widgets/transfer_check_widget.dart` | Custom Widget `TransferCheckWidget` — экран проверки |
| `custom_actions/get_transfers_to_check.dart` | Custom Action `getTransfersToCheck` — то же, что список, но JSON для своего ListView (не нужен, если используете `TransferListWidget`) |

Зависимости: `http`, `shared_preferences` (в FlutterFlow: Custom Code → Dependencies, если ещё не добавлены).

## 0. Custom Widget `TransferListWidget`

Параметры: `baseUrl`, `username`, `password`, `warehouseKey` (String), `daysBack` (int, по умолчанию 7),
`onOpen` — Action **с параметром `transferKey` (String)**: Navigate To «Проверка» с этим ключом.
Размер: на весь экран.

Поиск по номеру/магазину, обновление свайпом вниз и кнопкой. Жёлтым подсвечены документы,
проверку которых начали на этом ТСД. После возврата со страницы проверки список обновляется сам.

## 1. Custom Action `getTransfersToCheck` (необязательно)

Аргументы: `baseUrl` (String), `username` (String), `password` (String), `warehouseKey` (String), `daysBack` (int).
Return Type: **JSON, List**.

Элемент списка: `key`, `number`, `date`, `receiver`, `lines`, `comment`.
В списке нет перемещений, у которых в комментарии уже стоит «Проверено ТСД».

`warehouseKey` основного склада: `c1d8b115-3257-11ef-8278-00155d642b01`.

## 2. Custom Widget `TransferCheckWidget`

Параметры: `baseUrl`, `username`, `password`, `transferKey`, `checkerName` (все String),
`onSaved` (Action: после сохранения, например Navigate Back).
Размер: на весь экран (width/height = ∞ или Expanded).

## 3. Страницы

1. **Настройки**: поля → App State `baseUrl`, `username`, `password`, `warehouseKey`, `checkerName`.
2. **Список**: только `TransferListWidget`; `onOpen(transferKey)` → Navigate To «Проверка» (параметр страницы `transferKey`).
3. **Проверка**: только `TransferCheckWidget` с `transferKey`; `onSaved` → Navigate Back (список обновится сам).

Адрес, логин, пароль и склад удобно держать в App State (persisted).
`baseUrl` = `http://<IP сервера>/tbase` — по IP, не по имени `srv1`.

## 4. Android: HTTP без TLS

1С опубликована по `http://`. Начиная с Android 9 такие запросы блокируются, поэтому в FlutterFlow:
Custom Code → Configuration Files → `AndroidManifest.xml` → в тег `<application>` добавить
`android:usesCleartextTraffic="true"`.

## 5. Сканер

Режим ТСД — **эмуляция клавиатуры, суффикс Enter**. Виджет ловит коды сам, поле ввода не нужно.
Без сканера: кнопка ⌨ в шапке.

## Логика

- Блок: штрихкод единицы с `Коэффициент > 1` прибавляет весь блок.
- `rounded = ceil(план / k) × k`. Если `план < факт ≤ rounded` и факт кратен `k`, строка в порядке (🟢 «блок»).
- Больше плана, а блок неизвестен → кнопка «Блок?»: ввести штук в блоке. Создаётся единица «блок N»
  у номенклатуры в 1С (`Catalog_ЕдиницыИзмерения`), дальше блок определяется сам.
- Лишнее сверх блока / пересорт → отправка запрещена. Недостача → подтверждение.
- Тап по строке → ввести факт вручную (весовой товар, крупные партии).
- Прогресс хранится на ТСД (переживает перезапуск) и удаляется после отправки.
- Отправка: перечитывает документ; если он проведён или изменён в 1С после загрузки, ничего не пишет.
  Иначе `Товары` = факт (строки с 0 удаляются, ссылка на заказ и цена сохраняются),
  в `Комментарий` дописывается «Проверено ТСД: …; округлено: …; недостача: …».

## Права пользователя 1С для ТСД

Чтение: номенклатура, единицы измерения, штрихкоды, склады, перемещения.
Изменение: перемещения. Добавление: единицы измерения.
