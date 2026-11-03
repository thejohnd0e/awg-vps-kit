# AWG VPS Kit Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Do not start implementation until the user approves this written plan.

**Goal:** Повысить надёжность клиентских операций и обновления без потери идентичностей и неявного изменения сетевой политики.

**Architecture:** Сохранить существующие Bash entrypoints и файловый формат. Вводить изменения небольшими релизами: A — CLI/диагностика, B — клиентские операции, C — updater; сетевые изменения выделить в отдельное решение после VM-испытаний. Каталоги транзакций и общая блокировка согласуют изменения файлов и runtime, но не изображают атомарную транзакцию между файловой системой и ядром.

**Tech Stack:** Bash, util-linux/flock, Git, nftables, systemd, Debian 12 / Ubuntu 24.04 container tests; disposable Debian/Ubuntu VM for live checks.

**Spec:** `docs/superpowers/specs/2026-11-03-reliability-design.md`.

## Global Constraints

- Pure Bash, `set -euo pipefail`, Debian/Ubuntu, userspace `amneziawg-go`.
- Не менять ключи, адреса пиров, endpoint, MTU и рабочие параметры обфускации при обычном обновлении.
- Сохранить формат `[Peer]`, комментарий `# <name>` и `AllowedIPs = x/32`.
- Новые и существующие клиенты должны оставаться совместимыми после обновления менеджера.
- Никаких операций на действующих серверах без отдельного разрешения; привилегированные тесты только в одноразовых Linux-контейнерах/VM.
- Не выводить приватные ключи, PSK, клиентские конфиги и QR в диагностические логи.
- IPv6 blocking, изоляция клиентов, MTU/MSS, новые параметры обфускации и pinning апстрима требуют отдельных решений.
- Каждый task: сначала воспроизводящий failing test, затем минимальная реализация, затем regression suite; не коммитить чужие изменения.

## Review Focus

1. Запуск через stdin из каталога с посторонним `awg-client` не должен ошибочно выбирать этот каталог как kit (task 2).
2. Ошибка после успешного изменения runtime не должна давать ложный успех или терять материалы восстановления (tasks 4, 6).
3. Конкурирующие add/remove/show/update/uninstall не должны обходить блокировку, включая внутренние вызовы (tasks 3–6).
4. Пользовательские значения с `=`, IPv6 endpoint и вручную изменённые I-поля должны сохраняться без усечения (tasks 2, 5).
5. Проверки `is-active` и handshake не доказывают трафик; остановленный сервис и `--no-restart` не должны маскироваться как проверенное обновление (tasks 6–7).

## Исходные данные и границы

На момент написания прочитаны `AGENTS.md`, `STATUS.md`, `DECISIONS.md`, `TODO.md`, README, все четыре entrypoint, тест и CI. Локальный HEAD: `5fdee79` от 2026-10-18; рабочее дерево до записи документов чистое. GitHub и установленные серверы в этом сеансе не проверялись. В локальной версии нет `block-ping` и команды `mtu`; клиентский MTU копируется с сервера.

Этот документ не разрешает deploy, миграцию протокола, рестарт или fault injection на действующих серверах. Он не обещает Docker/firewalld-совместимость до испытаний. `--no-service` пишет системные файлы и не является безопасным тестом на рабочей машине.

## Карта файлов

| Файл | Ответственность |
|---|---|
| `install.sh` | валидация, bootstrap, сборка, cleanup, права, диагностика |
| `awg-client` | lock, атомарная публикация, recovery add/remove, protocol |
| `update.sh` | check/bootstrap, подготовка комплекта, backup/rollback |
| `uninstall.sh` | общий lock, locale, help; удаление согласованных новых артефактов |
| `tests/test-install.sh` | существующий install/update/uninstall smoke suite |
| `tests/test-reliability.sh` (new) | независимые сценарии отказов в одноразовом контейнере |
| `tests/helpers/reliability.sh` (new) | стабы и assertions, только тестовый код |
| `.github/workflows/ci.yml` | lint новых тестов и запуск reliability suite |
| `docs/testing/reliability-vm.md` (new) | безопасная инструкция живых проверок и результатов |
| README, STATUS, DECISIONS, TODO | фактическое поведение, ограничения, ссылки на проверки |

Общую production-библиотеку не вводить в этой серии: сначала стабилизировать контракты. Тестовые файлы не устанавливать на сервер. Не добавлять test-only fault switches в production CLI.

---

### Task 1: Воспроизводимые тесты отказов

**Files:** Create `tests/test-reliability.sh`, `tests/helpers/reliability.sh`; modify `.github/workflows/ci.yml`.

**Interfaces:** runner `bash tests/test-reliability.sh BIN_DIR CASE`, где CASE — `cli`, `bootstrap`, `cleanup`, `lock`, `peers`, `protocol`, `update` или `all`; exit 0 только при успехе всех assertions. `BIN_DIR` содержит три настоящих бинарника. Helpers: `fail MESSAGE`, `assert_status EXPECTED ACTUAL`, `assert_same FILE_A FILE_B`; стабы команд хранят реальные executable отдельно и журналируют только аргументы без секретов.

- [ ] Добавить runner и helpers с проверкой root и явным предупреждением о разрушительном контейнерном scope. Создать синтетические fixtures и очистку только известных тестовых путей; не запускать на Windows/рабочем сервере.
- [ ] Добавить первый тест `cli`: `install.sh --port` возвращает 1 и сообщение `--port requires a value`, без `unbound variable` и без вызова apt. Проверить FAIL на текущем коде в одноразовом контейнере.
- [ ] Подключить runner к lint и container matrix после существующего smoke suite. До реализации соответствующего task не включать его новые падающие сценарии в `all` в коммит, предназначенный для релиза.
- [ ] Проверить, что stderr стаба с синтетическим ключом не оказывается в опубликованных CI-логах; не использовать `set -x` на операциях с конфигами.
- [ ] Выполнить lint и существующий smoke suite; коммит `test: add reliability failure harness` вместе с первым исправлением task 2 либо сохранить task 1 как промежуточный нерелизный коммит с зафиксированным ожидаемым red.

### Task 2: CLI, bootstrap и диагностика — релиз A

**Files:** Modify `install.sh`, `update.sh`, `uninstall.sh`, `awg-client`, README; tests `cli/bootstrap/cleanup`.

**Interfaces:** локальные функции `usage()` и `need_value "$@"` в install/update; `die MESSAGE` — stderr + exit 1. `kv FILE KEY` сохраняет всё после первого `=`. `format_endpoint HOST PORT` выдаёт `host:port` или `[ipv6]:port`, не удваивает существующие скобки.

- [ ] Написать failing tests: отсутствующее значение каждой value-option; следующая опция вместо значения; порты 0/65536/abc; subnet `999.1.1`; help без shell-кода и со всеми опциями. Принять порты 1/65535; числа с ведущими нулями обрабатывать десятично.
- [ ] Реализовать валидацию до apt/сборки/записи. `--help` обрабатывать до bootstrap/root/package checks. Заменить sed-help во всех entrypoints с таким выводом, включая uninstall.
- [ ] Написать failing bootstrap tests через `bash -s --`: посторонний файл `awg-client` в CWD; `--check` при существующем checkout и при отсутствии kit. Проверять журнал git/apt/systemctl и хеши установленных файлов.
- [ ] Отличать stdin-запуск по `BASH_SOURCE`, а не соседнему файлу из CWD. Для update `--check` без checkout завершаться понятной ошибкой до clone/apt; с checkout запускать его check без pull. Check разрешает fetch метаданных, запрещает checkout/pull, установку пакетов, refresh_scripts и restart. Сохранить exit 0/10 для успешной проверки.
- [ ] Написать cleanup tests: сбой clone, build и checksum удаляет только созданный build-каталог. Реализовать build cleanup в subshell с EXIT trap и локальным абсолютным путём; исключить утечку RETURN trap в вызывающий контекст.
- [ ] Проверить `kv` со значением `a=b`, endpoint IPv4/hostname/IPv6/bracketed IPv6, явные права 0600 на секреты и 0644 на unit/sysctl/README. Ввести явные chmod/install и использовать `LC_ALL=C ufw status` в install/uninstall.
- [ ] Исправить обработку отказов `git ls-remote` и критических команд: сообщение с названием операции и exit 1, без вывода ключей. Не подавлять stderr apt; не обещать, что один ERR trap заменяет обработку ошибок. Сохранить единственный IP-сервис с ясным советом `--endpoint`: fallback не нужен для этого релиза.
- [ ] Запустить `cli`, `bootstrap`, `cleanup`, полный smoke suite и lint; обновить README/help; коммит `fix: validate CLI and make bootstrap checks non-mutating`.

### Task 3: Общая блокировка изменений

**Files:** Modify все четыре entrypoint; tests `lock`; README.

**Interfaces:** lock `/run/lock/awg-vps-kit.lock`, timeout 10 s, exit 1 с `another kit operation is running`. Help/version/check не берут эксклюзивную блокировку; изменяющие команды берут её до чтения изменяемого состояния. `show` считается изменяющим, так как публикует `.conf`.

- [ ] Написать failing tests: два одновременных add получают разные IP; add/remove не теряют соседних пиров; удерживаемый внешний lock заставляет add/update/uninstall завершиться по timeout без записи.
- [ ] Добавить `flock` с проверкой наличия команды; у updater брать lock после bootstrap/перехода в обновлённый checkout, но до installed-state snapshot и замены файлов. Перед заменой повторно проверить исходное состояние. Не полагаться на результаты pre-lock проверки.
- [ ] Исключить рекурсивный захват: protocol выводит список через функцию, не `"$0" list`; install вызывает `--first-client` после освобождения своего lock. Build-only не берёт установленный-state lock. Не вводить публичный `--skip-lock` или доверие к произвольной env-переменной.
- [ ] Проверить SIGTERM держателя: дескриптор освобождён, следующий процесс проходит; uninstall не удаляет общий lock-файл, пока удерживает его, чтобы не создавать второй inode-lock.
- [ ] Запустить `lock` и regression suite; коммит `fix: serialize installed state mutations`.

### Task 4: Восстанавливаемые add/remove — релиз B, часть 1

**Files:** Modify `awg-client`; tests `peers`; README.

**Interfaces:** `require_runtime()` проверяет `awg show awg0`; ошибка до постоянных изменений. Транзакция под `$DIR/transactions/peer.XXXXXX`, каталог 0700, секретные файлы 0600; содержит old/new config, необходимые ключи и phase. Наличие незавершённой транзакции запрещает следующие изменения, но не list/version/help. `show` публикует `.conf` через temporary file + rename в том же каталоге.

- [ ] Добавить failing tests `add_runtime_down`, `add_set_failure`, `remove_set_failure`: ненулевой exit; прежние файлы/пиры неизменны; повторный add того же имени после штатного отката успешен. Remove не сообщает об отзыве доступа при неудаче runtime.
- [ ] Реализовать staging полного результата до изменения runtime; сохранять старые данные до commit. Add применяет runtime peer, затем публикует staged files/config; remove сначала удаляет runtime peer, затем публикует конфиг и удаляет клиентские файлы. Любая ошибка публикации запускает обратную runtime-операцию и восстановление файлов под тем же lock.
- [ ] Добавить сценарии сбоя rename и удаления после успешного runtime-change. Проверять, что обратное применение peer использует сохранённые pub/PSK/IP; чужие peer-блоки сохраняются побайтно.
- [ ] При успешном откате удалить только каталог своей транзакции. При ошибке отката сохранить его, вернуть exit 1 и путь восстановления без секретов; запретить дальнейшие изменения до ручного восстановления по README.
- [ ] Добавить SIGTERM и SIGKILL tests с барьерами в стабе, не sleep-race: SIGTERM восстанавливает; SIGKILL оставляет защищённую транзакцию, следующий add отказывается. Не обещать fsync/power-loss атомарность.
- [ ] Добавить tests параллельного show и отказа генерации: ранее готовый `.conf` не обнуляется. Проверить уникальность IP и отсутствие временных файлов после успеха.
- [ ] Выполнить `peers/lock` и smoke suite; записать точную ручную процедуру восстановления в README; коммит `fix: make peer mutations recoverable`.

### Task 5: Переключение протокола без лишнего разрыва — релиз B, часть 2

**Files:** Modify `awg-client`, `tests/test-install.sh`, reliability `protocol`, README.

**Interfaces:** 1.0 ↔ 1.5 меняет только protocol metadata; `awg0.conf` побайтно неизменен, systemctl restart не вызывается. Вывод I1–I5 в клиент зависит от активного protocol; сохранённые пользовательские I-параметры не удаляются при переходе на 1.0/2.0. В 1.5 default I1 создаётся только при отсутствии пользовательского I1.

- [ ] Написать failing tests 1.0→1.5→1.0→1.5 с custom I1/I2 и `=` внутри значения: metadata сохраняет настройки, 1.0 не экспортирует I-поля, повторный 1.5 возвращает custom значения. Проверить нулевое число restart и неизменность серверного конфига/ключей/пиров.
- [ ] Реализовать protocol read/write через staging и rename; повторный выбор той же версии — no-op. Сохранить неизвестные metadata-ключи, не использовать `source` для чтения файла.
- [ ] Для переходов через 2.0 сохранить явное предупреждение о необходимости новых конфигов; делать уникальный backup серверного конфига и metadata в защищённом transaction-каталоге. При неудаче restart восстановить старые файлы и попытаться запустить прежний профиль; при неудаче recovery заблокировать следующие изменения как в task 4.
- [ ] Добавить failure tests 1.5→2.0 и 2.0→1.0, включая отказ restart/rollback; проверить отсутствие потери identity и сохранение предыдущего backup при повторном переходе.
- [ ] Пройти контейнерные protocol tests. До выпуска живым тестом на VM подтвердить работу уже импортированного 1.0 клиента после перехода сервера в 1.5 и работу 1.5 клиента; без этого task не объявлять готовым к релизу.
- [ ] Обновить README/help; коммит `fix: preserve protocol settings and avoid unnecessary restarts`.

### Task 6: Обновление с восстановлением — релиз C

**Files:** Modify `update.sh`, `uninstall.sh`, reliability `update`, README.

**Interfaces:** `runtime_healthy()` = successful `systemctl is-active --quiet awg-quick@awg0` + `awg show awg0`; это local liveness, не traffic proof. Транзакция `$DIR/transactions/update.XXXXXX`, 0700; содержит старые бинарники, `versions`/`kit-version` с отметкой отсутствующих файлов и устанавливаемые manager/README. `/opt/amneziawg/prev` обновляется полным согласованным набором после успешной транзакции.

- [ ] Написать failing tests: недостающий binary, повреждённый versions, сбой install второго файла, restart exit nonzero, `is-active=true` при неработающем `awg show`. Проверять хеши всех заменяемых файлов до/после, отсутствие ложного `Done.`.
- [ ] До замены подготовить все файлы, проверить executable/type/версии и сохранить backup. Обычный rebuild обязан записать SHA обеих upstream-компонент; для `--bin-dir` без versions разрешить установку с явным `unknown`, но не сохранять старые SHA как будто это новый комплект. Не исполнять неподтверждённые бинарники ради проверки версии вне согласованного тестового окружения.
- [ ] При обновлении с restart сначала требовать здоровый исходный runtime. Если он нездоров/сервис остановлен — отказ без замены с советом восстановить сервис либо явно выбрать `--no-restart`. Под lock повторно проверить версии после продолжительной сборки.
- [ ] После замены явно обработать restart и liveness failure, не оставлять их под неуправляемым `set -e`. Восстановить binaries, manager/docs и metadata; повторно запустить старый комплект. Выход всегда ненулевой при откате; различать `rolled back` и `rollback failed`.
- [ ] Добавить tests: отсутствующий исходный versions восстанавливается отсутствующим; отказ второго restart сохраняет transaction; повторное изменение блокируется; неудачная попытка не перезаписывает предыдущий успешный `/opt/amneziawg/prev`.
- [ ] Для `--no-restart` подтвердить отсутствие service-команд и сообщить `installed, runtime not verified`; это установка на диск, не подтверждённый рабочий комплект. При прерывании после частичной замены сохранять материалы восстановления.
- [ ] Добавить regression check, что config, protocol, endpoint, все keys и peer files побайтно сохранены. Уточнить uninstall `--keep-config`: сохраняет recovery-материалы вместе с конфигом; help не обещает автоматическую переустановку поверх существующего `awg0.conf`.
- [ ] Выполнить `update` и все контейнерные тесты. VM: здоровая старая установка → update → реальные TCP/UDP/DNS запросы клиента; затем контролируемый отказ restart → восстановление старого комплекта → повторные запросы. Коммит `fix: roll back failed binary updates with matching metadata`.

### Task 7: VM-матрица firewall и жизненного цикла — отдельный исследовательский этап

**Files:** Create `docs/testing/reliability-vm.md`; modify STATUS/TODO. Production firewall/unit не менять в этом task.

**Interfaces:** инструкция фиксирует OS, kit/core SHA, исходный firewall, команды, ожидаемый результат, фактический результат и cleanup; никаких IP/секретов production. Каждый кейс начинается с snapshot одноразовой VM; внешний тестовый клиент имеет отдельные синтетические ключи.

- [ ] Составить последовательность baseline: install, reboot, add/show/remove, update, uninstall/keep-config; проверить реальный IPv4 TCP, UDP и DNS и сохранение доступа администратора через отдельный management-интерфейс.
- [ ] Проверить повторный `nft -f nat-up.nft`, отсутствие таблицы при down, restart/reload nftables, UFW active с неанглийской локалью; записать фактические ошибки и число правил, без предположения об идемпотентности.
- [ ] На отдельных snapshots проверить Docker/iptables-nft FORWARD DROP и firewalld; каждый результат описать как supported/unsupported/unverified для конкретной конфигурации. Не добавлять универсальный DOCKER-USER workaround без решения.
- [ ] После разрешения на fault injection только этой VM завершить userspace-процесс и проверить отличие systemd active от фактического runtime/трафика. Не имитировать OOM загрузкой памяти; для build memory записать измерения при штатной сборке.
- [ ] Проверить IPv6 клиента отдельно: явно показать, что текущий IPv4-only профиль не гарантирует защиты IPv6; не менять AllowedIPs или forwarding в рамках опыта.
- [ ] По доказанным сбоям предложить отдельный дизайн: идемпотентный NAT, безопасный down, интеграция reload либо watchdog/unit. Для каждого изменения установленных файлов определить точный migration manifest, backup и восстановление. До одобрения этого дизайна schema/migrate_N не добавлять.
- [ ] Обновить STATUS/TODO ссылкой на результаты; коммит `docs: record firewall and lifecycle validation`.

## Проверки перед каждым релизом

Команды ниже выполняются в одноразовом Linux-окружении, не в Windows checkout и не на production:

```bash
bash -n install.sh update.sh uninstall.sh awg-client tests/test-install.sh tests/test-reliability.sh tests/helpers/reliability.sh
shellcheck install.sh update.sh uninstall.sh awg-client tests/test-install.sh tests/test-reliability.sh tests/helpers/reliability.sh
bash install.sh --build-only /opt/awg-bin
bash tests/test-install.sh /opt/awg-bin
bash tests/test-reliability.sh /opt/awg-bin all
```

Ожидание: все команды exit 0; оба suite печатают явный итог успеха. CI matrix: debian:12 и ubuntu:24.04. Проверка build требует сеть; failure tests используют стабы и не зависят от доступности GitHub. Зафиксировать отдельно какие live checks действительно исполнены.

После каждого релиза обновить STATUS/DECISIONS/TODO только фактическими изменениями, README синхронизировать с help. `AGENTS.md` менять только если изменились структура/правила проекта. Не повышать VERSION и не создавать tag без принятой процедуры выпуска/разрешения пользователя.

## Последующие решения, не включённые в реализацию

- Pinning проверенных upstream SHA и процесс их обновления.
- DNS настройки, расширенный list/status, split tunnel и экспорт.
- IPv6 kill switch/полноценный IPv6, изоляция клиентов и cloud metadata.
- MTU/MSS и рандомизация J/I только после совместимости и измерений.
- Автоматические миграции unit/NAT — только по результатам task 7.

## Самопроверка плана

- CLI/bootstrap/cleanup: tasks 1–2; синхронизация и peer recovery: tasks 3–4; protocol: task 5; update/rollback: task 6; реальные firewall/systemd проверки: task 7.
- Все пять Review Focus привязаны к негативным тестам соответствующих tasks.
- `runtime_healthy` обозначает только liveness; traffic proof требует VM и клиента.
- Необратимые сетевые изменения и универсальная миграция сознательно не специфицированы до отдельного решения.
- Этот документ — план, а не свидетельство пройденных тестов. Реализация и runtime-проверки ещё не выполнялись.
