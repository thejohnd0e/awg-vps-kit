# Протокол AmneziaWG 3.1 в awg-vps-kit: план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** добавить opt-in уровень протокола AmneziaWG 3.1 (HeaderProtectionKey, равные S1–S4, H1–H4 = 1/2/3/4, RandomTrailers, ContentPaddingAddition, таймеры) в `install.sh` и `awg-client`, с переключением, откатом и предохранителями.

**Architecture:** генераторы и дефолты 3.1 — в `lib/common.sh` (как H/S-генераторы сегодня); `install.sh` пишет серверные поля 3.1 в `awg0.conf` и клиентские дефолты в `$DIR/protocol`; `awg-client` экспортирует поля в клиентские конфиги через `extra_fields()` и переключает уровень через существующий механизм `protocol` (бэкап → перезапись → рестарт → откат). Кит кладёт свой `upstream.lock` в `$DIR`, чтобы `awg-client` мог проверить движок перед включением 3.1.

**Tech Stack:** Pure Bash (`set -euo pipefail`), awk, systemd, nftables; тесты — `tests/test-install.sh` и `tests/test-reliability.sh` в контейнерах debian:12 / ubuntu:24.04.

**Spec:** `docs/superpowers/specs/2026-11-11-awg-protocol-3.1-design.md` (план исходит из спеки; исполнители читают обе).

## Global Constraints

- Bash, `set -euo pipefail`; скрипты работают от root на Debian/Ubuntu (apt).
- `upstream.lock` не меняется: пины `amneziawg-go=b5928ef…`, `amneziawg-tools=ee0f0a9…` уже 3.1.
- Поведение 1.0/1.5/2.0 не меняется: `awg_s34_values` (S3 8–64, S4 4–32), генераторы S1/S2 15–150, H-диапазоны 2.0, метаданные-переключение 1.0↔1.5 — как были.
- `Jc/Jmin/Jmax` остаются 5/40/900; формат `awg0.conf` (`[Peer]` + `# <name>` + `AllowedIPs = x/32`) неизменен.
- Секреты: `HeaderProtectionKey` (HPK) живёт только в `awg0.conf` (600) и клиентских конфигах (600); не печатается в `list`, `list -v`, `version`, `protocol`, логи.
- 3.1 — opt-in: дефолт установки остаётся 1.0; `update.sh` протокол не меняет.
- Серверы под контейнер AmneziaWG-to-Proxy на 3.1 не переводятся — только заметка в README и сообщение переключения, без детекта в коде.
- shellcheck и `bash -n` чисты для всех изменённых файлов.
- Запуск тестов (dev-машина Windows, тесты только в Linux; один контейнер можно переиспользовать на все шаги задачи, сборка бинарников ~5–10 мин):

```bash
# WSL Debian, из /mnt/d/MyProjects/awg-vps-kit
docker run --rm -v /mnt/d/MyProjects/awg-vps-kit:/kit -w /kit debian:12 \
  bash -lc 'bash install.sh --build-only /opt/awg-bin && bash tests/test-install.sh /opt/awg-bin'
docker run --rm -v /mnt/d/MyProjects/awg-vps-kit:/kit -w /kit debian:12 \
  bash -lc 'bash install.sh --build-only /opt/awg-bin && AWG_TEST_ALLOW_DESTRUCTIVE=1 bash tests/test-reliability.sh /opt/awg-bin all'
```

## Review Focus

Пять классов входов, которые спека подразумевает, но отдельные задачи могут не покрыть; тест на каждую строку уже вписан в задачу-владельца:

1. `--protocol 3.0` и `awg-client protocol 3.0` отклоняются с сообщением, называющим 3.1 (не молча и не «незнакомая версия») — тесты в Task 2 (install) и Task 5 (client).
2. Старый/незаписанный движок + `protocol 3.1`: отказ ДО любых изменений файлов (`awg0.conf` не тронут, exit ≠ 0, сообщение про `update.sh`) — Task 5.
3. Даунгрейд 3.1 → 2.0/1.0 не оставляет в `awg0.conf` ни одного ключа 3.x (`HeaderProtectionKey`, `RandomTrailers`, `ContentPaddingAddition`): старый движок на них умирает — Task 5.
4. MTU: без `$DIR/client-mtu` клиент 3.1 получает 1280, клиент ≤2.0 — 1420; явный файл перекрывает и при значении >1320 на 3.1 печатается предупреждение — Task 3 (дефолт) и Task 5 (предупреждение).
5. Утечка HPK: `list`, `list -v`, `version`, вывод `protocol` не содержат значения HPK — Task 5.

---

### Task 1: Генераторы и дефолты 3.1 в lib/common.sh

**Files:**
- Modify: `lib/common.sh:60-73` (рядом с существующими генераторами)
- Test: `tests/test-install.sh:36-49` (блок lib-проверок)

**Interfaces:**
- Consumes: `AWG_I1_DEFAULT` (lib/common.sh:15).
- Produces (используют Task 2 и Task 3/5):
  - `awg_s31_value` — печатает одно случайное целое 15–32 (`shuf -i 15-32 -n 1`).
  - `awg_h_values 3.1` — печатает `1`, `2`, `3`, `4` (по значению в строке, как остальные ветки).
  - `awg_31_client_defaults` — печатает строки `key=value` для `$DIR/protocol`:
    `I1=<AWG_I1_DEFAULT>`, `ContentPaddingAddition=10-100`, `DisableCookies=on`, `RekeyAfterTime=100-120`, `RekeyTimeout=3-7`, `RejectAfterTime=150-180`, `KeepaliveTimeout=5-15`, `MaxHandshakeAttempts=15-20`.

- [ ] **Step 1: Дописать падающие проверки в lib-блок test-install.sh**

После существующих проверок `awg_s34_values` (tests/test-install.sh:44-45):

```bash
v=$(awg_s31_value); [[ "$v" =~ ^(1[5-9]|2[0-9]|3[0-2])$ ]] || fail "lib: 3.1 S value out of range: $v"
mapfile -t h31 < <(awg_h_values 3.1)
[ "${h31[*]}" = "1 2 3 4" ] || fail "lib: 3.1 H must be 1 2 3 4"
awg_31_client_defaults | grep -q '^ContentPaddingAddition=10-100$' || fail "lib: 3.1 default CPA missing"
[ "$(awg_31_client_defaults | grep -cE '^(I1|ContentPaddingAddition|DisableCookies|RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts)=')" = 8 ] \
  || fail "lib: 3.1 client defaults must have exactly 8 keys"
```

- [ ] **Step 2: Запустить тест, убедиться в падении**

Run: контейнер debian:12, только `bash tests/test-install.sh /opt/awg-bin` (бинарники из `--build-only`, см. Global Constraints).
Expected: FAIL «awg_s31_value: command not found» (или аналогично про первый новый символ).

- [ ] **Step 3: Реализовать в lib/common.sh**

`awg_s31_value` — одна строка `shuf`. В `awg_h_values` добавить ветку `3.1` перед существующим `if` (печать четырёх констант). `awg_31_client_defaults` — восемь `echo`-строк, значения дословно из Interfaces; I1 подставить из `$AWG_I1_DEFAULT`. Никакой новой логики.

- [ ] **Step 4: Тест зелёный**

Run: тот же.
Expected: PASS, в т.ч. старые проверки `awg_h_values 2.0`/`awg_s34_values` не изменились.

- [ ] **Step 5: Commit**

```bash
git add lib/common.sh tests/test-install.sh
git commit -m "lib: AWG 3.1 generators and client-field defaults"
```

---

### Task 2: install.sh — установка с протоколом 3.1

**Files:**
- Modify: `install.sh:24` (help), `:97` и `:149` (валидация), `:136-147` (меню), `:293-298` (параметры S/H), `:328-343` (ключи, файл protocol), `:368-387` (awg0.conf), место установки файлов кита (рядом с `:388`, куда ставится README)
- Test: `tests/test-install.sh:228-250` (цикл протоколов), `:280-285` (отклонение неизвестных)

**Interfaces:**
- Consumes: `awg_s31_value`, `awg_h_values`, `awg_31_client_defaults` (Task 1); значение пина `amneziawg-go`, которое `install.sh` уже читает из `upstream.lock` для pinned fetch.
- Produces: `awg0.conf` сервера 3.1 с полями `S1 = S2 = S3 = S4` (равные, 15–32), `H1..H4 = 1/2/3/4`, `HeaderProtectionKey = <awg genkey>`, `RandomTrailers = on`, `ContentPaddingAddition = 10-100`; `$DIR/protocol` уровня 3.1 с дефолтами Task 1; `$DIR/upstream.lock` (копия китовского, 644) — её читает Task 4/5.

- [ ] **Step 1: Падающие проверки серверной стороны в test-install.sh**

В цикл протоколов (tests/test-install.sh:229) добавить `for proto in 1.5 2.0 3.1` и ветку:

```bash
3.1)
  s=$(awk '$1=="S1"{print $3}' "$DIR/awg0.conf")
  [ "$(grep -cE "^S[1-4] = $s\$" "$DIR/awg0.conf")" = 4 ] || fail "3.1: S1-S4 must be one equal value"
  [[ "$s" =~ ^(1[5-9]|2[0-9]|3[0-2])$ ]] || fail "3.1: S out of 15-32"
  [ "$(awk '$1 ~ /^H[1-4]$/{print $3}' "$DIR/awg0.conf" | paste -sd,)" = "1,2,3,4" ] || fail "3.1: H must be 1/2/3/4"
  grep -Eq '^HeaderProtectionKey = [A-Za-z0-9+/]{43}=$' "$DIR/awg0.conf" || fail "3.1: HPK missing"
  has "$DIR/awg0.conf" '^RandomTrailers = on$'
  has "$DIR/awg0.conf" '^ContentPaddingAddition = 10-100$'
  has "$DIR/protocol" '^ContentPaddingAddition=10-100$' ;;
```

Утверждение про клиентский конфиг (HPK, таймеры, MTU) НЕ добавлять — это Task 3. Обновить тест отклонения (tests/test-install.sh:282-284): `--protocol 3.0` по-прежнему падает, но теперь с текстом, содержащим `1.0, 1.5, 2.0 or 3.1`.

- [ ] **Step 2: Запустить, убедиться в падении ветки 3.1**

Run: debian:12, `bash tests/test-install.sh /opt/awg-bin`.
Expected: FAIL «--protocol must be 1.0, 1.5 or 2.0» (установщик ещё не знает 3.1).

- [ ] **Step 3: Реализовать в install.sh**

- Валидация (строки 97, 149) и help (24): `1.0|1.5|2.0|3.1`; сообщение `--protocol must be 1.0, 1.5, 2.0 or 3.1`.
- Меню: 4-й пункт `4 - version 3.1  header protection, equal S, RandomTrailers; needs a client with 3.1 support (Amnezia VPN >= 5.0.1.5)`; `Choose 1-4 [1]`; `case` для `4) PROTOCOL=3.1`.
- Параметры (293-298): при 3.1 — `S1=$(awg_s31_value)` и `S2=$S1` (без проверки `S1+56≠S2` — значения равны); `mapfile -t H < <(awg_h_values "$PROTOCOL")` уже даст 1/2/3/4.
- HPK: перед heredoc `awg0.conf` — `HPK=$([ "$PROTOCOL" != 3.1 ] || awg genkey)`; переменную не логировать.
- Файл `protocol` (339-343): при 3.1 дописать вывод `awg_31_client_defaults`.
- `awg0.conf` (368-387): при 3.1 дописать после heredoc (по образцу строки 387): `S3 = $S1`, `S4 = $S1`, `HeaderProtectionKey = $HPK`, `RandomTrailers = on`, `ContentPaddingAddition = 10-100`.
- Рядом с установкой README (388): `install -m 644 "$HERE/upstream.lock" "$DIR/upstream.lock"` (безусловно, для любого протокола — понадобится Task 4/5).
- Предохранитель `--bin-dir`: при `PROTOCOL=3.1`, если `$BIN_DIR/versions` нет или его `amneziawg-go` ≠ пину из lock — `warning:` в stderr (не отказ).

- [ ] **Step 4: Тест зелёный**

Run: debian:12 и ubuntu:24.04, `bash tests/test-install.sh /opt/awg-bin`.
Expected: PASS, включая «unknown protocol rejected» с новым сообщением; ветки 1.5/2.0 не изменились.

- [ ] **Step 5: Commit**

```bash
git add install.sh tests/test-install.sh
git commit -m "install: AWG 3.1 server profile, ship upstream.lock into /etc/amnezia/amneziawg"
```

---

### Task 3: awg-client — клиентские конфиги и дефолты 3.1

**Files:**
- Modify: `awg-client:40-71` (usage), `:96-98` (`client_mtu`), `:124-129` (`extra_fields`)
- Test: `tests/test-install.sh` (расширение цикла протоколов из Task 2)

**Interfaces:**
- Consumes: серверные поля 3.1 в `awg0.conf` и ключи в `$DIR/protocol` (Task 2), `AWG_I1_DEFAULT` (lib).
- Produces: клиентский конфиг 3.1 содержит `S1-S4`, `H1-H4`, `HeaderProtectionKey` (копию серверного), `RandomTrailers = on`, `DisableCookies = on`, `ContentPaddingAddition`, пять таймеров, `I1-I5`; `client_mtu` без файла `$DIR/client-mtu` возвращает 1280 при протоколе 3.1 и 1420 иначе.

- [ ] **Step 1: Падающие проверки клиентской стороны**

В ветку `3.1` цикла (после утверждений сервера из Task 2) добавить:

```bash
has "$cfg" '^MTU = 1280$'
srvhpk=$(awk '$1=="HeaderProtectionKey"{print $3}' "$DIR/awg0.conf")
grep -q "^HeaderProtectionKey = $srvhpk\$" "$cfg" || fail "3.1: client HPK must equal the server one"
has "$cfg" '^RandomTrailers = on$'
has "$cfg" '^DisableCookies = on$'
has "$cfg" '^ContentPaddingAddition = 10-100$'
[ "$(grep -cE '^(RekeyAfterTime|RekeyTimeout|RejectAfterTime|KeepaliveTimeout|MaxHandshakeAttempts) = ' "$cfg")" = 5 ] || fail "3.1: client timers missing"
has "$cfg" '^I1 = <b 0x'
```

И отдельная проверка после цикла: на сервере 1.0 без `$DIR/client-mtu` клиентский конфиг содержит `MTU = 1420`; `awg-client mtu` на 3.1 печатает `1280`, после `awg-client mtu 1400` — `1400` (файл перекрывает).

- [ ] **Step 2: Запустить, убедиться в падении**

Run: debian:12, `bash tests/test-install.sh /opt/awg-bin`.
Expected: FAIL «3.1: client HPK must equal the server one» (или первое несошедшееся поле клиента).

- [ ] **Step 3: Реализовать**

- `client_mtu()` (96-98): непустой `$DIR/client-mtu` перекрывает как раньше; иначе дефолт — `1280` при `kv "$DIR/protocol" protocol` = 3.1, иначе `1420`.
- `extra_fields()` (124-129): после цикла `S3/S4` дописать `HeaderProtectionKey` и `RandomTrailers` из `iface_val` (эмитировать только если непустые — на ≤2.0 их нет); затем вместо `return` по «не 1.5» — `case` по протоколу: `1.5` → `I1-I5` (как сейчас); `3.1` → `DisableCookies`, `ContentPaddingAddition`, `RekeyAfterTime`, `RekeyTimeout`, `RejectAfterTime`, `KeepaliveTimeout`, `MaxHandshakeAttempts`, затем `I1-I5` (все из `$DIR/protocol` через `kv`).
- `usage` (~50): строку про `protocol` дополнить `3.1`; упомянуть, что клиент 3.1 требует Amnezia VPN ≥ 5.0.1.5 и MTU 1280 по умолчанию.

- [ ] **Step 4: Тест зелёный**

Run: debian:12 и ubuntu:24.04, `bash tests/test-install.sh /opt/awg-bin`.
Expected: PASS; ветки 1.5/2.0 без изменений.

- [ ] **Step 5: Commit**

```bash
git add awg-client tests/test-install.sh
git commit -m "awg-client: export AWG 3.1 fields to client configs, protocol-aware MTU default"
```

---

### Task 4: upstream.lock в установленном состоянии + проверка движка

**Files:**
- Modify: `install.sh` (уже кладёт `$DIR/upstream.lock` — Task 2), `update.sh:299` (список управляемых файлов) и место отката рядом, `awg-client` (новый хелпер рядом с `iface_val`, `:119`)
- Test: `tests/test-reliability.sh` (кейс `update` — сохранность нового файла), `tests/test-install.sh` (файл существует после установки)

**Interfaces:**
- Consumes: `kv` (lib/common.sh), `$DIR/versions`, `$DIR/upstream.lock`.
- Produces: `engine_is_31` (функция в awg-client) — exit 0, только если `kv "$DIR/versions" amneziawg-go` равен `kv "$DIR/upstream.lock" amneziawg-go` (оба 40-hex); иначе 1. Использует Task 5.

- [ ] **Step 1: Падающие проверки**

В test-install.sh (рядом с проверкой `README.md` в списке файлов): после установки `has "$DIR/upstream.lock" '^amneziawg-go='` и сравнение с `upstream.lock` репозитория (`diff`). В test-reliability.sh (кейс `update`, блок проверки отката): после неудачного обновления `$DIR/upstream.lock` восстановлен (равен до-обновлению). Прямая проверка `engine_is_31` — через bash: на тестовой установке с реальными бинарниками `source` недоступен (awg-client — скрипт), поэтому проверять поведенчески в Task 5; здесь только файлы.

- [ ] **Step 2: Запустить, убедиться в падении**

Run: debian:12, оба набора (reliability — с `AWG_TEST_ALLOW_DESTRUCTIVE=1`).
Expected: FAIL «upstream.lock…» (update.sh ещё не управляет файлом).

- [ ] **Step 3: Реализовать**

- `update.sh`: добавить `$DIR/upstream.lock` в список снапшотируемых/восстанавливаемых управляемых файлов везде, где сейчас перечислены `common.sh`, `versions`, `kit-version`, `README.md` (строка 299 и откаты), и в набор файлов новой версии (`$txn/new/...`, из `$HERE/upstream.lock`).
- `awg-client`: хелпер `engine_is_31` рядом с `iface_val` — сравнение через `kv`, как в Interfaces; без побочных эффектов.

- [ ] **Step 4: Тесты зелёные**

Run: debian:12 и ubuntu:24.04, оба набора.
Expected: PASS (включая существующие сценарии отката update).

- [ ] **Step 5: Commit**

```bash
git add update.sh awg-client tests/test-install.sh tests/test-reliability.sh
git commit -m "kit: manage upstream.lock as installed state; engine_is_31 helper"
```

---

### Task 5: awg-client protocol 3.1 — переключение, откат, предохранители

**Files:**
- Modify: `awg-client:158-163` (`protocol_fields`), `:311-325` (`make_protocol_file`), `:420-492` (команда `protocol`: валидация 423, предпроверки, awk 456, генерация HPK, сообщения)
- Test: `tests/test-install.sh:251-279` (цикл переключений), `tests/test-reliability.sh:247-290` (`case_protocol`)

**Interfaces:**
- Consumes: `engine_is_31` (Task 4), `awg_s31_value`/`awg_h_values`/`awg_31_client_defaults` (Task 1), `iface_val`, механизм фейкового systemctl (`SYSTEMCTL_ACTIVE`, `SYSTEMCTL_LOG`; блок неудачного рестарта — test-reliability.sh:282-289).
- Produces: `protocol_fields <target> [<cur>]` — при `target=3.1` или `cur=3.1` эмитирует и `S1/S2` (при `cur=3.1` — текущие значения из `awg0.conf`, т.е. равные остаются), для `3.1` ещё `S3/S4` (равные), `H1-H4`, `HeaderProtectionKey = $(awg genkey)`, `RandomTrailers = on`, `ContentPaddingAddition = 10-100`; для `2.0` без 3.1 — как сегодня (только S3/S4/H). Поведение 2.0↔1.x без 3.1 — байт-в-байт как сейчас.

- [ ] **Step 1: Падающие проверки переключений в test-reliability.sh (case_protocol)**

Добавить в конец кейса (фейковый systemctl, как в существующих блоках):

```bash
# 2.0 -> 3.1
SYSTEMCTL_ACTIVE=1 SYSTEMCTL_LOG=$log "$ROOT/awg-client" protocol 3.1 >/dev/null
s=$(awk '$1=="S1"{print $3}' "$CONF")
[ "$(grep -cE "^S[1-4] = $s\$" "$CONF")" = 4 ] || fail "3.1 switch: equal S missing"
grep -qE '^HeaderProtectionKey = [A-Za-z0-9+/]{43}=$' "$CONF" || fail "3.1 switch: HPK missing"
has_kv_31=$(grep -cE '^(ContentPaddingAddition|DisableCookies|RekeyAfterTime)=' "$DIR/protocol")
[ "$has_kv_31" -ge 3 ] || fail "3.1 switch: client defaults not appended to protocol file"
# кастомные значения переживают переход
printf 'ContentPaddingAddition=50-90\nRekeyTimeout=9\n' >> "$DIR/protocol"
SYSTEMCTL_ACTIVE=1 SYSTEMCTL_LOG=$log "$ROOT/awg-client" protocol 2.0 >/dev/null
SYSTEMCTL_ACTIVE=1 SYSTEMCTL_LOG=$log "$ROOT/awg-client" protocol 3.1 >/dev/null
grep -q '^ContentPaddingAddition=50-90$' "$DIR/protocol" || fail "3.1 switch must keep custom CPA"
# 3.1 -> 1.0 вычищает ключи 3.x, S1/S2 остаются равными
SYSTEMCTL_ACTIVE=1 SYSTEMCTL_LOG=$log "$ROOT/awg-client" protocol 1.0 >/dev/null
grep -qE '^(S3|S4|HeaderProtectionKey|RandomTrailers|ContentPaddingAddition) = ' "$CONF" && fail "downgrade must remove all 3.x keys"
[ "$(awk '$1=="S1"{print $3}' "$CONF")" = "$s" ] || fail "downgrade must keep the equal S1/S2"
# отказ при неподходящем движке: conf не тронут
before=$(sha256sum "$CONF" | cut -d' ' -f1)
printf 'amneziawg-go=%040d\namneziawg-tools=%040d\n' 1 2 > "$DIR/versions"
if SYSTEMCTL_ACTIVE=1 "$ROOT/awg-client" protocol 3.1 >/dev/null 2>&1; then fail "3.1 must be refused on an unreviewed engine"; fi
[ "$(sha256sum "$CONF" | cut -d' ' -f1)" = "$before" ] || fail "refused 3.1 must not touch awg0.conf"
# предупреждение про явный MTU > 1320
printf '1400\n' > "$DIR/client-mtu"
printf 'amneziawg-go=%s\namneziawg-tools=%s\n' "$(grep '^amneziawg-go=' "$ROOT/upstream.lock" | cut -d= -f2)" x > "$DIR/versions"
out=$(SYSTEMCTL_ACTIVE=1 "$ROOT/awg-client" protocol 3.1 2>&1)
grep -qi 'mtu' <<<"$out" || fail "explicit large client-mtu must warn on 3.1"
grep -q '^HeaderProtectionKey = ' "$CONF" || fail "3.1 after warning must still apply"
# HPK не утекает в диагностику
hpk=$(awk '$1=="HeaderProtectionKey"{print $3}' "$CONF")
for o in "$("$ROOT/awg-client" list)" "$("$ROOT/awg-client" list -v)" "$("$ROOT/awg-client" version)" "$out"; do
  grep -q "$hpk" <<<"$o" && fail "HPK must not appear in list/version/protocol output"
done
```

(Точные идиомы `has`/`fail` и переменные окружения взять из существующего кода кейса; `log`/`ROOT`/`CONF`/`DIR` уже определены в нём. Заодно убедиться, что неудачный рестарт на пути 3.1→2.0 откатывает файлы — переиспользовать блок :282-289 с заменой версий.)
В test-install.sh цикл переключений (251-279): расширить последовательность до `1.5 → 2.0 → 3.1 → 1.0`; утверждение «S1 changed» (261) выполняется только для шагов без 3.1; для 3.1 добавить счётчик полей `^(S[1-4]|H[1-4]|HeaderProtectionKey|RandomTrailers|ContentPaddingAddition) = ` = 12; `protocol 3.0` по-прежнему отвергается (278) с текстом, содержащим `3.1`.

- [ ] **Step 2: Запустить, убедиться в падении**

Run: debian:12, `AWG_TEST_ALLOW_DESTRUCTIVE=1 bash tests/test-reliability.sh /opt/awg-bin protocol` (и test-install).
Expected: FAIL «protocol must be 1.0, 1.5 or 2.0».

- [ ] **Step 3: Реализовать**

- Валидация (423): `1.0|1.5|2.0|3.1`, сообщение «protocol must be 1.0, 1.5, 2.0 or 3.1».
- Предпроверки при `$name = 3.1` (после `pending_txn`, до создания транзакции): `engine_is_31 || die "installed amneziawg-go is not the reviewed 3.1 build; run update.sh first"`; предупреждение, если `$DIR/client-mtu` непуст и > 1320 (`warning: client MTU $m plus padding may fragment; consider awg-client mtu 1280`).
- `protocol_fields <target> [<cur>]`: см. Interfaces; HPK генерировать внутри неё (`awg genkey`), значение нигде не логировать.
- awk-перезапись (456): два режима. Замешана 3.1 (target или cur): вырезать в `[Interface]` строки `^(S[1-4]|H[1-4]|HeaderProtectionKey|RandomTrailers|ContentPaddingAddition) =`, вставить блок полей после строки `^Jmax = `. Иначе — существующий вырез `^(S3|S4|H[1-4]) =` и вставка после `^S2 = ` (не трогать). Режим задать переменными (regex-строки) в один awk.
- `make_protocol_file` (311-325): рядом с веткой 1.5/I1 — при `ver=3.1` дописывать из `awg_31_client_defaults` только отсутствующие ключи (кастом не перезаписывать).
- Сообщения (после успешного рестарта на 3.1): дополнительно `client MTU default on 3.1 is 1280 (awg-client mtu overrides)` и `every client needs AWG 3.1 support (Amnezia VPN >= 5.0.1.5); container bridges like AmneziaWG-to-Proxy do not (see README)`.

- [ ] **Step 4: Тесты зелёные**

Run: debian:12 и ubuntu:24.04: test-install полностью; reliability — `protocol` и `all`.
Expected: PASS; метаданные-переключение 1.0↔1.5 и сценарий 2.0 без 3.1 не изменились.

- [ ] **Step 5: Commit**

```bash
git add awg-client tests/test-install.sh tests/test-reliability.sh
git commit -m "awg-client: protocol 3.1 switching with engine precheck, downgrade and MTU warning"
```

---

### Task 6: Документация, VERSION, статусы, финальная проверка

**Files:**
- Modify: `README.md:94-107` (таблица протоколов, замена «3+ unsupported», заметка о AmneziaWG-to-Proxy), `install.sh` help и текст меню (сверить с Task 2), `awg-client` usage (сверить с Task 3), `VERSION` → `1.4.0`, `STATUS.md`, `DECISIONS.md`, `TODO.md:22-26`

**Interfaces:**
- Consumes: всё выше; минимальные версии клиентов из спеки: Amnezia VPN ≥ 5.0.1.5, AmneziaWG Android ≥ v3.1.20260814, Windows ≥ 3.1.0.
- Produces: согласованность README ↔ help ↔ поведение (конвенция AGENTS.md).

- [ ] **Step 1: Обновить тексты**

- README: строка таблицы `| 3.1 | HeaderProtectionKey, equal S1-S4, H1-H4 = 1/2/3/4, RandomTrailers, ContentPaddingAddition, timer ranges | client needs 3.1 support (Amnezia VPN >= 5.0.1.5); values must match; client MTU defaults to 1280 |`; заменить абзац «Later "3+" features…» (105-107) на описание 3.1 и заметку: серверы, чьи конфиги кормят AmneziaWG-to-Proxy, не переводить на 3.1 до обновления движка в образе контейнера (его движок ≤2.0).
- `VERSION`: `1.4.0`.
- DECISIONS.md: новая запись «Протокол 3.1 (opt-in)» — уровень, параметры (равные S 15–32, H 1–4, HPK, RT/CPA, клиентские дефолты), предохранители, правило про контейнер; TODO.md: снять «not "3+"», STATUS.md: краткая запись о 3.1.

- [ ] **Step 2: Финальная проверка**

Run (оба образа): `bash -n` + `shellcheck -x` по списку CI; `bash tests/test-install.sh /opt/awg-bin`; `AWG_TEST_ALLOW_DESTRUCTIVE=1 bash tests/test-reliability.sh /opt/awg-bin all`.
Expected: всё зелёное; в выводе test-install видны `ok protocol 3.1` и новые проверки переключений.

- [ ] **Step 3: Commit**

```bash
git add README.md VERSION STATUS.md DECISIONS.md TODO.md install.sh awg-client
git commit -m "docs: AWG 3.1 support in README, decisions and statuses; kit 1.4.0"
```

---

## Живая проверка (вне плана задач, вручную после мержа)

По спеке: подъём 3.1 на одноразовой VM по `docs/testing/reliability-vm.md` (реальный `amneziawg-go` 3.1, нет `EINVAL`, `awg show`), затем ручной тест с реальным клиентом (Amnezia VPN ≥ 5.0.1.5) — результат в `STATUS.md` отдельной записью. Действующие серверы не переключаются без отдельного решения; серверы под AmneziaWG-to-Proxy — не переключаются вообще до обновления образа контейнера.
