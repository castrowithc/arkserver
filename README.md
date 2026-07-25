# arkserver — ARK: Survival Evolved Dedicated Server (Docker)

Gehärteter, eigenständiger Docker-Server für ein selbst gehostetes ARK: Survival Evolved
(2 Spieler), betrieben per Docker Compose. Primär für Linux-VPS, sekundär Windows/WSL2.

## Quickstart
```bash
cd deploy
cp example.env .env        # Werte setzen – insbesondere Passwörter
docker compose up -d       # zieht das Image von GHCR und startet (bzw. baut lokal, wenn build: aktiv)
docker compose logs -f ark # Fortschritt verfolgen (Erstdownload via SteamCMD dauert)
```
Voraussetzungen: Docker + Compose, **≥12 GB RAM** (`MEM_LIMIT`), ~40 GB freier SSD-Speicher
für die ARK-SE-Vollinstallation (Details: `../arkserver-ops/docs/hardware-requirements.md`).
Netzwerk/Port-Forwarding: `../arkserver-ops/docs/networking.md`.

## Container-Image (GHCR)
Statt lokal zu bauen, kann das vorgebaute Image gezogen werden:
```bash
docker pull ghcr.io/castrowithc/arkserver:latest    # neuestes Release
docker pull ghcr.io/castrowithc/arkserver:0.1.1     # feste Version (empfohlen für Produktion)
docker pull ghcr.io/castrowithc/arkserver:edge      # Spitze von main (Vorschau)
```
Das Image wird per CI gebaut, mit Trivy gescannt und nach GHCR gepusht.

## Releases / Versionierung
[SemVer](https://semver.org/lang/de/) als Git-Tag `vX.Y.Z`. Ein Tag löst Build + Push der
Image-Tags `X.Y.Z` / `X.Y` / `latest` sowie ein GitHub-Release aus. `edge` folgt `main`,
`sha-<kurz>` jedem Commit. Für stabilen Betrieb auf eine feste Version pinnen (einfacher Rollback).

## Dokumentation
Einrichtung, Netzwerk/Port-Forwarding, Karten, Backup/Restore und Fehlerbehebung sind im
Steuer-Repo dokumentiert: **`../arkserver-ops/docs/`** (Übersicht: `../arkserver-ops/project.md`).

## Lizenz
[MIT](./LICENSE) © 2026 Christian Castro.
