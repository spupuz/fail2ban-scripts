# fail2ban-scripts

Repository degli **script e della configurazione custom di fail2ban**.

Origine: `/zfsfiles/DockerConfig/arcane/projects/fail2ban/data/fail2ban`

## Contenuto

| Percorso | Descrizione |
|---|---|
| `scripts/fail2ban-telegram.sh` | Notifiche Telegram formattate su ban/unban (versione corrente) |
| `scripts/ignorehost.sh` | Lookup host per la whitelist ignorehost, con cache JSON (versione corrente) |
| `scripts/fail2ban-telegram_old.sh` | Versione precedente dello script Telegram (storico) |
| `scripts/ignorehost_old.sh` | Versione precedente di ignorehost (storico) |
| `action.d/telegram.local` | Override dell'action `telegram` |
| `action.d/iptables-nft.local` | Override dell'action `iptables-nft` |
| `action.d/ui-custom-action.conf` | Action custom usata dalla fail2ban-ui |
| `filter.d/npm-docker.conf` | Filtro per errori npm in container Docker |
| `jail.d/npm-docker.local` | Jail per il filtro `npm-docker` |
| `jail.local` | Override `[DEFAULT]` gestito dalla Fail2Ban-UI (bantime, banaction, action con callback UI) |
| `paths-overrides.local` | Override dei banaction/postfix/sshd rispetto ai default dell'immagine |

I file `jail.conf`, `fail2ban.conf` e `paths-*.conf` **non** sono inclusi: sono
configurazioni stock di fail2ban.

## Deploy

I file devono essere copiati nella directory dati di fail2ban mantenendo la
struttura delle sottocartelle, poi il servizio va ricaricato:

```bash
SRC=/zfsfiles/DockerConfig/DockerSource/fail2ban-scripts
DST=/zfsfiles/DockerConfig/arcane/projects/fail2ban/data/fail2ban

cp -p "$SRC"/scripts/*.sh                  "$DST"/scripts/
cp -p "$SRC"/action.d/*                    "$DST"/action.d/
cp -p "$SRC"/filter.d/npm-docker.conf      "$DST"/filter.d/
cp -p "$SRC"/jail.d/npm-docker.local       "$DST"/jail.d/
cp -p "$SRC"/jail.local "$SRC"/paths-overrides.local "$DST"/

fail2ban-client reload
```

> Nota: gli script in `scripts/` hanno permessi `750` e sono eseguiti da root.

## Sincronizzazione manuale (backup → repo)

```bash
SRC=/zfsfiles/DockerConfig/arcane/projects/fail2ban/data/fail2ban
DST=/zfsfiles/DockerConfig/DockerSource/fail2ban-scripts

cp -p "$SRC"/scripts/*.sh "$DST"/scripts/
cp -p "$SRC"/action.d/*.local "$SRC"/action.d/ui-custom-action.conf "$DST"/action.d/
cp -p "$SRC"/filter.d/npm-docker.conf "$DST"/filter.d/
cp -p "$SRC"/jail.d/npm-docker.local "$DST"/jail.d/
cp -p "$SRC"/jail.local "$SRC"/paths-overrides.local "$DST"/
```
