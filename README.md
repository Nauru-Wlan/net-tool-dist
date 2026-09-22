Nauru-Wlan – MAC-Adressen-Wechsler

Ein Windows-Tool, das per Klick eine neue, zufällige MAC-Adresse für den aktiven Netzwerkadapter setzt. Ein-Klick-Bedienung, Open Source, mit transparenter Sicherheitsprüfung.

Was das Tool tut
Erzeugt eine zufällige, lokal administrierte MAC-Adresse (Bit-Maske 0x02 gesetzt, 0x01 gelöscht – gültig für LAN und WLAN)
Schreibt sie in den Registry-Wert NetworkAddress des aktiven Netzwerkadapters und startet den Adapter neu, damit sie aktiv wird
Merkt sich bereits vergebene Adressen lokal, damit keine doppelt vorkommt
Prüft beim Start automatisch auf eine neuere Version dieses Skripts (siehe version.json) und aktualisiert sich selbst
Was das Tool nicht tut
Es verändert nichts an deiner Internetverbindung selbst, keinem VPN- oder Tor-Verhalten, keiner IP-Adresse
Es umgeht keine Zugangskontrollen, Netzwerksperren, Zeitkontingente oder Geräte-Whitelists Dritter. Es ändert ausschließlich die lokale Hardware-Kennung des Adapters; wie diese Kennung anderswo verwendet wird, liegt außerhalb der Kontrolle des Tools
Es sammelt, sendet oder speichert keine Nutzungsdaten. Die einzige Netzwerkkommunikation ist die Update-Prüfung (dieses Repo) und die Lizenzprüfung (siehe Quellcode, Funktion Test-LicenseOnline)
Warum Adminrechte nötig sind

Windows erlässt Änderungen am NetworkAddress-Registrierungswert nur mit Administratorrechten. Das ist eine Vorgabe des Betriebssystems, keine Entscheidung dieses Tools. MacChanger.ps1 fordert die Rechte per UAC-Dialog an (Start-Process -Verb RunAs), nicht heimlich.

Warum ein Klartext-Skript statt einer kompilierten .exe

Bewusste Entscheidung: Ein PowerShell-Skript kann jeder vor der Ausführung in einem Texteditor öffnen und lesen. Der Nachteil ist, dass Skripte, die Adminrechte anfordern und sich selbst aktualisieren, bei Virenscannern häufiger heuristisch auffallen – auch ohne echten Fund. Siehe nächster Abschnitt.

Sicherheitsprüfung

Das komplette Auslieferungspaket wird vor jedem Release bei VirusTotal geprüft. Das Ergebnis wird unverändert in der Kundendokumentation (Anleitung.txt) und auf der Website verlinkt, auch wenn es nicht makellos ist. Treffer sind bisher ausschließlich generische Heuristik-Meldungen (z. B. „Trojan.Script.Generic“), keine bestätigten Funde – typisch für Skripte mit Adminrechten und Selbst-Update, aber jeder soll sich selbst ein Bild machen können.

Auto-Update

MacChanger.ps1 prüft bei jedem Start und einmal täglich im Hintergrund (über eine Windows-Aufgabenplanung, -SilentUpdateOnly) gegen version.json auf eine neuere Version. Der Hintergrund-Check ersetzt nur diese Datei, startet keinen Dauerprozess und führt keinen Code aus, der nicht ebenfalls hier im Repo einsehbar ist.

Aufbau dieses Repos
Datei	Zweck
MacChanger.ps1	Haupttool. Enthält die komplette Logik: MAC-Wechsel, Lizenzprüfung, Auto-Update, GUI
version.json	Update-Manifest: aktuelle Versionsnummer + Download-URL dieses Skripts

Das vollständige Kundenpaket (inkl. Installer, Deinstaller und Anleitung) wird als Release als ZIP bereitgestellt.

Lizenz

Der Quellcode in diesem Repository dient der Transparenz und Nachvollziehbarkeit. Verkauft wird eine Nutzungslizenz für das fertige Tool, kein Recht zur Weiterverbreitung oder Nutzung ohne gültigen Lizenzschlüssel. Bei Fragen: siehe Kontaktweg in der Kundendokumentation.

Kontakt

Fragen vor dem Kauf oder zu diesem Code: siehe Discord-Link auf der Landingpage bzw. in Anleitung.txt.
