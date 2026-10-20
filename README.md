# fail2ban-scripts

Repository degli **script e della configurazione custom di fail2ban**.

> Nessun path del tuo host è scritto in questo repository: la **directory dati
> di fail2ban** va sempre indicata esplicitamente come argomento
> (`scripts/deploy.sh --dest DIR`, `scripts/redact.sh --src DIR`).

## Contenuto

| Percorso | Descrizione |
|---|---|
| `scripts/fail2ban-telegram.sh` | Notifiche Telegram formattate su ban/unban (bash, versione corrente) |
| `scripts/ignorehost.sh` | Lookup host per la whitelist ignorehost (**Python**, nonostante l'estensione `.sh`) |
| `scripts/fail2ban-telegram_old.sh` | Versione precedente dello script Telegram (storico) |
| `scripts/ignorehost_old.sh` | Versione precedente di ignorehost (storico) |
| `scripts/deploy.sh` | Copia i file nella directory fail2ban **iniettando i segreti** da `secrets.env` |
| `scripts/redact.sh` | Operazione inversa: dalla directory live al repo, sostituendo i segreti con i placeholder |
| `scripts/run_tests.sh` | Entry point locale dei test (stessa suite che gira in CI) |
| `scripts/test_*.sh` | Test: sintassi, struttura config, scan segreti, pipeline deploy, YAML, path host |
| `action.d/telegram.local` | Override dell'action `telegram` |
| `action.d/iptables-nft.local` | Override dell'action `iptables-nft` |
| `action.d/ui-custom-action.conf` | Action custom usata dalla fail2ban-ui (callback su `127.0.0.1`) |
| `filter.d/npm-docker.conf` | Filtro per errori npm in container Docker |
| `jail.d/npm-docker.local` | Jail per il filtro `npm-docker` |
| `jail.local` | Override `[DEFAULT]` gestito dalla Fail2Ban-UI (bantime, banaction, action con callback UI) |
| `paths-overrides.local` | Override dei banaction rispetto ai default dell'immagine |
| `secrets.env.example` | Template dei segreti — copiarlo in `secrets.env` (gitignored) |
| `VERSION` | Versione corrente (`X.Y.Z`) — è lei che triggera la release su GitHub |
| `.github/workflows/` | `ci.yml` (test) e `release.yml` (tag + release) |
| `.agents/skills/`, `.opencode/commands/`, `.opencode/AGENTS.md` | Skill `commit-push` e `pr-push` + linee guida per gli agenti |

I file `jail.conf`, `fail2ban.conf` e `paths-*.conf` **non** sono inclusi: sono
configurazioni stock di fail2ban.

## Segreti

I sorgente contengono **solo placeholder** (`__TELEGRAM_BOT_TOKEN_NOTIFY__`,
`__TELEGRAM_CHAT_ID_NOTIFY__`, `__TELEGRAM_BOT_TOKEN_IGNOREHOST__`,
`__TELEGRAM_CHAT_ID_IGNOREHOST__`, `__FAIL2BAN_UI_CALLBACK_SECRET__`).

I valori reali stanno esclusivamente in `secrets.env`, che è in `.gitignore`
e **non deve mai essere committato**:

```bash
cp secrets.env.example secrets.env
chmod 600 secrets.env
# poi compilare i valori reali nel file
```

`scripts/test_secrets.sh` fallisce il build se un valore reale finisce in un
file tracciato da git.

## Deploy

```bash
# anteprima (non scrive nulla)
scripts/deploy.sh --dest /percorso/della/directory/dati/fail2ban

# scrittura effettiva + reload di fail2ban
scripts/deploy.sh --dest /percorso/della/directory/dati/fail2ban --apply
fail2ban-client reload
```

- `--secrets FILE` permette di usare un file segreti alternativo (default:
  `secrets.env` accanto alla root del repo).
- La struttura delle sottocartelle (`scripts/`, `action.d/`, `filter.d/`,
  `jail.d/`) viene riprodotta nella destinazione.
- I permessi dei file già presenti nella destinazione vengono preservati
  (gli script partono da `750`, `ui-custom-action.conf` da `600`).

## Sincronizzazione inversa (live → repo)

I file nella directory live contengono i segreti reali: **non copiarli mai
direttamente nel repo**. Usa `redact.sh`, che li riscrive con i placeholder:

```bash
scripts/redact.sh --src /percorso/della/directory/dati/fail2ban \
                  --out /percorso/di/un/staging
# oppure un singolo file su stdout
scripts/redact.sh --src DIR --out OUT --file action.d/telegram.local
diff -r . /percorso/di/un/staging   # revisione, poi commit
```

Il round-trip deploy → redact è verificato byte-per-byte da
`scripts/test_deploy.sh`.

## Test

Tutto gira **in locale** con lo stesso comando usato dalla CI:

```bash
bash scripts/run_tests.sh
```

| Test | Cosa verifica |
|---|---|
| `scripts/test_syntax.sh` | `bash -n` sui file bash, `compile()` sui file Python (`ignorehost*.sh`) |
| `scripts/test_configs.sh` | Sezioni INI, `failregex` con `<HOST>` e regex compilabile, riferimenti `/etc/fail2ban/scripts/*` → file presenti, permessi, placeholder, `VERSION` semver |
| `scripts/test_secrets.sh` | Scan leak: token Telegram, chat ID, callback secret, blob ad alta entropia, chiavi private |
| `scripts/test_deploy.sh` | Pipeline deploy/redact completa con segreti fittizi + round-trip byte-identico |
| `scripts/test_no_host_paths.sh` | Nessun path assoluto dell'host nei file del repo |
| `scripts/test_skill_sync.sh` | `.agents/skills/*` e `.opencode/commands/*` restano allineati |
| `scripts/test_yaml.sh` | Parsing YAML dei workflow (in CI con PyYAML installato) |

## CI e release

- **`.github/workflows/ci.yml`** — esegue `scripts/run_tests.sh` su ogni push
  e PR verso `main`.
- **`.github/workflows/release.yml`** — quando una push modifica `VERSION`,
  crea il tag `vX.Y.Z` e pubblica la release GitHub. Il tag **non** va creato
  manualmente.

## Versioning

`VERSION` contiene una versione semver "nuda" (`0.1.0`, senza `v`):

- **PATCH** — fix, tweak, docs
- **MINOR** — nuove funzionalità backward-compatible
- **MAJOR** — cambiamenti breaking (jail rimossi, comportamento cambiato)

## Skills per agenti

- `.agents/skills/commit-push` (e `.opencode/commands/commit-push.md`) —
  verifica i cambiamenti, lancia la suite, bumpa `VERSION`, commit + push e
  conferma la release CI riscrivendone le note.
- `.agents/skills/pr-push` (e `.opencode/commands/pr-push.md`) — merge dei PR
  su un branch di release, verifica, bump di `VERSION`, push e release.

## Changelog

### v0.1.0

- Import iniziale degli script e della configurazione custom di fail2ban.
- Segreti rimossi dai sorgenti (placeholder + `secrets.env` gitignored),
  con pipeline `deploy.sh` / `redact.sh`.
- Suite di test locale (`scripts/run_tests.sh`), workflow CI e release.
- Skill `commit-push` e `pr-push`.
