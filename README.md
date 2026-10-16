# Cerf Switcher

<p align="center">
  <img src="icon.png" width="128" alt="Cerf Switcher icon">
</p>

<p align="center">
  <b>Local EN↔RU keyboard-layout fixer for macOS</b><br>
  Typed <code>ghbdtn</code>? Get <code>привет</code>. Everything runs on your Mac.
</p>

<p align="center">
  <a href="https://github.com/yelloduxx/CerfSwitcher/tags"><img src="https://img.shields.io/github/v/tag/yelloduxx/CerfSwitcher?style=flat-square&label=beta" alt="Beta tag"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/yelloduxx/CerfSwitcher?style=flat-square" alt="License"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-blue?style=flat-square" alt="macOS 13+">
  <img src="https://img.shields.io/badge/Swift-6-orange?style=flat-square" alt="Swift 6">
  <img src="https://img.shields.io/badge/build-4.0.0%20(159)-brightgreen?style=flat-square" alt="Build 4.0.0 (159)">
</p>

<p align="center">
  <a href="#english">English</a> · <a href="#русский">Русский</a>
</p>

---

## English

**Why "cerf"?** Type the Russian word «сука» while the keyboard is still in the English layout and you get `cerf`. That is exactly the mistake this app fixes.

Cerf Switcher is a menu-bar app that fixes words typed in the wrong keyboard layout. You can fix a word by hand with a double Shift, or let the app fix it automatically when you finish the word. Decoding, learning and settings stay on your Mac. There is no telemetry.

### Manual conversion

| Action | Result |
|---|---|
| Type a word, tap **Shift** twice | The last word is converted |
| Tap **Shift** twice again | The word switches back |
| Select text, tap **Shift** twice | The selection is converted |

The trigger is configurable. It can be Shift, Option, Command or Control, either side or only the right one, with a single or double tap. Manual conversion works with any two installed layouts.

### Automatic conversion

Turn it on in **Settings → Overview**. It is off by default.

A word is checked only when you press Space, Enter or Tab, never in the middle of a word. The decoder compares the text you typed with the same keys in the other layout. It weighs:

- word frequency;
- English (SCOWL) and Russian (Hunspell) dictionaries;
- character patterns;
- the language of the surrounding phrase;
- next-word statistics;
- your own corrections.

When the evidence is weak, it leaves the text alone. Some examples:

- `ghbdtn,` → `привет,`
- `ghbdtncnde.` → `приветствую` (the final `.` key is `ю`)
- `b` → `и` in Russian text, but `plan B` stays
- `ult` → `где`
- `ашпьфб` → `figma` and `n/l/` → `т.д.` inside Russian text
- `руку` and `here` stay, because both words are real

It never touches:

- passwords and secure fields;
- terminals, IDEs and password managers (an editable app list);
- URLs, e-mail addresses and file paths;
- code identifiers, camelCase and mixed-script words;
- ALL-CAPS acronyms, unless the other reading is one in common use (`ЗК` → `PR`).

### It learns from you

- **Manual conversion teaches a word pair.** After you fix a word by hand, that word converts automatically the next time.
- **Undo is negative feedback.** Undoing an automatic fix, or switching it back with double Shift, counts against that conversion.
- **Your own words.** A word that no dictionary knows becomes part of your personal dictionary after you type it and keep it on three separate occasions. Examples are slang and project terms. Password fields, secure input and excluded apps are never counted.
- **Backup and reset.** Learned words can be exported, imported or reset in **Settings → Advanced**.

### Settings

Open them from the menu-bar icon → **Settings** (⌘,).

| Page | What it has |
|---|---|
| **Overview** | Permission status, automatic conversion, the layout flag at the cursor, per-app layout memory and launch at login. |
| **Keyboard** | The trigger key, right-side-only, double tap and the layout pair. |
| **Exceptions** | Apps where auto-conversion is off, words to never convert, and words to always convert. |
| **Advanced** | Auto-conversion in apps without Accessibility (terminals, Electron), Remote Desktop mode (beta), learned-word backup and reset, and the debug log. |
| **About** | Version, the GitHub link and update checks. |

The menu-bar menu also lets you switch layouts directly. It has quick toggles for automatic conversion, the layout sound, the flag at the cursor, a monochrome icon and Remote Desktop mode.

The interface comes in 16 languages. The new Settings window is fully translated into English and Russian. In the other languages its newer strings appear in English for now.

### Installation

There is no prebuilt release yet. Build from source with Xcode Command Line Tools on macOS 13 or later:

```bash
git clone https://github.com/yelloduxx/CerfSwitcher.git
cd CerfSwitcher
SIGN_ID="<your code-signing identity>" bash build_app.sh
ditto CerfSwitcher.app /Applications/CerfSwitcher.app
open /Applications/CerfSwitcher.app
```

The result is a universal app for Apple Silicon and Intel. Use the same signing identity for every update. macOS ties permissions to the signature, so a different identity makes you grant them again.

On first launch, grant two permissions in System Settings → Privacy & Security. The built-in assistant walks you through them.

1. **Accessibility** reads and replaces text.
2. **Input Monitoring** sees which keys you press.

**Coming from RuSwitcher Pro?** On first launch Cerf Switcher copies your settings, learned words and personal dictionary once. The old settings are left untouched. Quit the old app first, so that two switchers do not handle the same keys.

### Privacy

- No text leaves your Mac. There are no cloud models, statistics or analytics.
- The only network request is the optional update check against this GitHub repository. You can turn it off in **About**.
- Debug logs contain lengths and outcomes, never the words you type.

### For developers

```bash
swift test
python3 scripts/run_mixed_layout_event_stream_suite.py <corpus.tsv> --jobs 8
```

`AGENTS.md` has the engineering notes: architecture, event delivery, safety gates, test harnesses and the release procedure. `THIRD_PARTY_NOTICES.md` lists the data sources: Google Books n-grams, SCOWL, LibreOffice Hunspell, Tatoeba and wordfreq. The optional InputMethodKit companion (`build_input_method.sh`) needs an Apple-issued signing identity to run.

### License

[MIT](LICENSE). Third-party data keeps its own licenses; see `THIRD_PARTY_NOTICES.md`.

---

## Русский

**Почему «cerf»?** Наберите «сука», забыв переключиться с английской раскладки, и получится `cerf`. Именно такие ошибки программа и исправляет.

Cerf Switcher живёт в строке меню и исправляет слова, набранные не в той раскладке. Слово можно исправить вручную двойным Shift или включить автоматическое исправление, которое срабатывает, когда вы дописали слово. Распознавание, обучение и настройки остаются на вашем Mac. Телеметрии нет.

### Ручная конвертация

| Действие | Результат |
|---|---|
| Набрать слово, нажать **Shift** два раза | Последнее слово сконвертировано |
| Ещё раз **Shift** два раза | Слово вернулось обратно |
| Выделить текст, нажать **Shift** два раза | Сконвертировано выделение |

Триггер настраивается. Это может быть Shift, Option, Command или Control, с любой стороны или только правая, одиночное или двойное нажатие. Ручная конвертация работает с любой парой установленных раскладок.

### Автоконверсия

Включается в **Настройки → Обзор**. По умолчанию выключена.

Слово проверяется только после пробела, Enter или Tab, никогда посреди слова. Движок сравнивает набранный текст с теми же клавишами в другой раскладке. Он учитывает:

- частоту слов;
- английский (SCOWL) и русский (Hunspell) словари;
- буквенные сочетания;
- язык фразы вокруг;
- статистику следующих слов;
- ваши собственные исправления.

Если уверенности мало, текст остаётся как есть. Примеры:

- `ghbdtn,` → `привет,`
- `ghbdtncnde.` → `приветствую` (клавиша `.` в конце это `ю`)
- `b` → `и` в русском тексте, но `plan B` не трогается
- `ult` → `где`
- `ашпьфб` → `figma` и `n/l/` → `т.д.` в русском тексте
- `руку` и `here` остаются, потому что оба слова настоящие

Программа никогда не трогает:

- пароли и защищённые поля;
- терминалы, IDE и менеджеры паролей (список приложений редактируется);
- адреса сайтов, почту и пути к файлам;
- код, camelCase и слова со смешанными алфавитами;
- аббревиатуры ЗАГЛАВНЫМИ, если другое прочтение не известная аббревиатура (`ЗК` → `PR`).

### Учится у вас

- **Ручная конвертация учит пару слов.** После исправления вручную это слово в следующий раз сконвертируется автоматически.
- **Отмена учит в обратную сторону.** Если вы отменили автозамену или вернули слово двойным Shift, это считается сигналом против такой замены.
- **Ваши слова.** Слово, которого нет в словарях, попадает в личный словарь, если вы три раза в разное время набрали его и оставили как есть. Это может быть сленг или рабочие термины. Пароли, защищённый ввод и приложения-исключения не учитываются.
- **Резервная копия и сброс.** Выученное можно экспортировать, импортировать и сбросить в **Настройки → Дополнительно**.

### Настройки

Открываются из иконки в строке меню → **Настройки** (⌘,).

| Раздел | Что внутри |
|---|---|
| **Обзор** | Статус разрешений, автоконверсия, флаг у курсора, раскладка по приложениям и автозапуск. |
| **Клавиатура** | Клавиша-триггер, только правая клавиша, двойной тап и пара раскладок. |
| **Исключения** | Приложения без автоконверсии, слова, которые нельзя трогать, и слова, которые исправлять всегда. |
| **Дополнительно** | Автоконверсия в приложениях без Accessibility (терминалы, Electron), режим удалённого стола (бета), копия и сброс выученных слов, журнал отладки. |
| **О программе** | Версия, ссылка на GitHub и проверка обновлений. |

Из меню в строке меню можно сразу переключить раскладку. Там же быстрые переключатели автоконверсии, звука раскладки, флага у курсора, монохромной иконки и режима удалённого стола.

Интерфейс есть на 16 языках. Новое окно настроек полностью переведено на русский и английский. На остальных языках его новые строки пока показываются по-английски.

### Установка

Готовой сборки пока нет. Соберите из исходников на macOS 13+ с Xcode Command Line Tools:

```bash
git clone https://github.com/yelloduxx/CerfSwitcher.git
cd CerfSwitcher
SIGN_ID="<ваш сертификат подписи>" bash build_app.sh
ditto CerfSwitcher.app /Applications/CerfSwitcher.app
open /Applications/CerfSwitcher.app
```

Получится universal-приложение для Apple Silicon и Intel. Подписывайте все обновления одним и тем же сертификатом. macOS привязывает разрешения к подписи, поэтому с другим сертификатом их придётся выдавать заново.

При первом запуске выдайте два разрешения в «Системных настройках → Конфиденциальность и безопасность». Встроенный помощник проведёт по шагам.

1. **Универсальный доступ** нужен, чтобы читать и заменять текст.
2. **Мониторинг ввода** нужен, чтобы видеть нажатия клавиш.

**Переходите с RuSwitcher Pro?** При первом запуске Cerf Switcher один раз скопирует ваши настройки, выученные слова и личный словарь. Старые настройки не меняются. Старое приложение сначала закройте, чтобы два переключателя не обрабатывали одни и те же клавиши.

### Приватность

- Текст не покидает ваш Mac. Нет облачных моделей, статистики и аналитики.
- Единственный сетевой запрос это необязательная проверка обновлений в этом репозитории на GitHub. Её можно выключить в разделе **«О программе»**.
- В журнал отладки попадают только длины и результаты, но никогда не набранные слова.

### Для разработчиков

```bash
swift test
python3 scripts/run_mixed_layout_event_stream_suite.py <corpus.tsv> --jobs 8
```

В `AGENTS.md` собраны инженерные заметки: архитектура, доставка событий, защитные правила, тестовые стенды и порядок выпуска. `THIRD_PARTY_NOTICES.md` перечисляет источники данных: Google Books n-grams, SCOWL, LibreOffice Hunspell, Tatoeba и wordfreq. Для дополнительного Input Method (`build_input_method.sh`) нужен сертификат подписи от Apple.

### Лицензия

[MIT](LICENSE). Сторонние данные распространяются по своим лицензиям, см. `THIRD_PARTY_NOTICES.md`.
