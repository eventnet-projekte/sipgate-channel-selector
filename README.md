# sipgate Channel Selector

Hält die sipgate Desktop App dauerhaft auf dem Channel **„Hotline"** — automatisch, im Hintergrund, ohne Benutzereingriff.

## Wie es funktioniert

Der Watcher verbindet sich über das [Chrome DevTools Protocol](https://chromedevtools.github.io/devtools-protocol/) mit der sipgate Electron App und injiziert ein kleines Skript, das sofort reagiert, sobald jemand den Channel wechselt.

- **Kein Channel-Wechsel möglich** — der Watcher korrigiert es innerhalb einer Sekunde
- **Dock-Start wie gewohnt** — wenn sipgate ohne Debug-Port gestartet wird (z.B. per Dock-Klick), erkennt der Watcher das automatisch und startet sipgate kurz neu
- **Autostart nach Reboot** — läuft als macOS Hintergrunddienst (launchd), startet automatisch beim Login
- **Keine Accessibility-Berechtigungen nötig**

## Installation

Einmal im Terminal ausführen:

```bash
curl -fsSL https://raw.githubusercontent.com/eventnet-projekte/sipgate-channel-selector/main/install.sh | bash
```

Das war's. Ab sofort läuft der Watcher im Hintergrund.

## Update

Gleichen Befehl nochmal ausführen — der Installer erkennt eine bestehende Installation und aktualisiert sie.

```bash
curl -fsSL https://raw.githubusercontent.com/eventnet-projekte/sipgate-channel-selector/main/install.sh | bash
```

## Deinstallation

```bash
bash ~/Library/Application\ Support/SipgateHotlineWatcher/uninstall.sh
```

## Logs

```bash
tail -f /tmp/sipgate-hotline-watcher.log
```

## Voraussetzungen

- macOS
- sipgate Desktop App installiert unter `/Applications/sipgate.app`
- Node.js — wird automatisch mitinstalliert falls nicht vorhanden

## Technischer Hintergrund

| Komponente | Beschreibung |
|---|---|
| `watcher.js` | Node.js Daemon, verbindet sich via CDP, injiziert MutationObserver |
| `install.sh` | Selbst-enthaltener Installer (kein Git-Clone nötig) |
| launchd plist | Autostart bei Login, automatischer Neustart bei Absturz |

**Robustheit bei App-Updates:** Die Erkennung basiert auf `document.title` (`"Hotline - sipgate App"`) und `aria-label="Hotline"` — beides sind semantische Eigenschaften, keine internen CSS-Klassen. Ändern sich diese bei einem sipgate-Update, reicht es, den Installer erneut auszuführen sobald eine neue Version verfügbar ist.
