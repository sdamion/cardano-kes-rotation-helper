# Cardano KES Rotation Helper

Een begeleid Bash-script dat een KES-rotatie voor een Cardano block producer in één flow uitvoert. Het script zoekt de relevante paden automatisch, maakt de nieuwe KES-sleutel op de block producer, pauzeert voor ondertekening op de offline cold node en gaat na een toetsdruk verder met validatie, installatie, herstart en controle.

> **Belangrijk:** test dit eerst op een testnet en lees de samenvatting vóór iedere bevestiging. De `cold.skey` mag de cold node nooit verlaten. Bewaar altijd een actuele, offline back-up van `cold.counter`.

## Wat het automatisch vindt

- `cardano-cli` via `PATH`;
- de draaiende `cardano-node` en zijn startargumenten;
- node socket, Shelley genesis, actieve `kes.skey`, `kes.vkey` en `node.cert`;
- de systemd-service en de ingestelde gebruiker/groep;
- aangekoppelde USB- of andere verwisselbare media;
- na terugkomst de juiste transfermap aan de hand van de unieke rotatie-ID.

Als er precies één geldige kandidaat is, gebruikt het script die. Bij meerdere kandidaten laat het ze zien en moet je kiezen. Voor security-kritieke bestanden wordt nooit willekeurig een kandidaat gekozen.

De bestaande `kes.vkey` hoeft niet aanwezig te zijn: `cardano-node` gebruikt tijdens bedrijf de KES signing key en het operational certificate. Het script leidt het bijbehorende `.vkey`-pad automatisch af van `kes.skey`, back-upt een bestaand bestand en schrijft daar bij installatie de nieuwe verificatiesleutel. Build- en testbestanden onder bijvoorbeeld `.cabal/store` worden bij het zoeken genegeerd.

## Ubuntu: downloaden en starten

Download de laatste release op de **block producer**:

```bash
curl -fLO https://github.com/sdamion/cardano-kes-rotation-helper/releases/latest/download/cardano-kes-rotate.sh
chmod 700 cardano-kes-rotate.sh
sudo ./cardano-kes-rotate.sh
```

Of download de broncode van de releasepagina, pak die uit en voer hetzelfde script uit:

```bash
chmod 700 cardano-kes-rotate.sh
sudo ./cardano-kes-rotate.sh
```

Benodigde Ubuntu-tools worden bij het starten op de block producer automatisch gecontroleerd. Als er iets ontbreekt, voert het script zelf het volgende uit:

```bash
sudo apt-get update
sudo apt-get install -y jq coreutils util-linux procps
```

Als alles al aanwezig is, wordt `apt-get` niet aangeroepen. In `cold`-modus wordt `apt-get` nooit aangeroepen, zodat de cold node offline kan blijven. Daar moeten `sha256sum` (normaal standaard aanwezig via `coreutils`) en een compatibele `cardano-cli` vooraf beschikbaar zijn. `cardano-cli` moet ook op de block producer al geïnstalleerd zijn en compatibel zijn met je draaiende `cardano-node`.

Het script zoekt `cardano-cli` ook buiten de beperkte `sudo`-`PATH`, waaronder `~/.local/bin`, `~/.cabal/bin`, `/usr/local/bin`, `/usr/bin` en gangbare `/opt/cardano`-locaties. Met een afwijkende installatie kun je het pad expliciet meegeven:

```bash
sudo CARDANO_CLI=/volledig/pad/naar/cardano-cli ./cardano-kes-rotate.sh
```

## De volledige flow

1. Start `sudo ./cardano-kes-rotate.sh` op de block producer.
2. Controleer de automatisch gevonden paden en bevestig ze.
3. Kies de aangekoppelde USB/transfermap. Het script maakt daar `kes-rotation-<UTC-tijd>/` aan.
4. Ontkoppel de media veilig en verbind deze met de offline cold node.
5. Ga op de cold node naar de transfermap en voer uit:

   ```bash
   cd /pad/naar/kes-rotation-*
   sudo ./cardano-kes-rotate.sh cold "$PWD"
   ```

6. Het script vindt `cold.skey` en de actuele `cold.counter`, toont alles ter controle, maakt een counter-back-up en schrijft `node.cert` in de transfermap.
7. Verplaats de media terug naar de block producer en koppel deze aan.
8. Druk daar op Enter in de wachtende flow. Het script vindt de map, controleert hashes en de koppeling met de lokaal bewaarde KES key, maakt een back-up, installeert de credentials, herstart de service en controleert node tip en KES-status.

Als de terminal tussentijds is gesloten, hervat je op de block producer met:

```bash
sudo ./cardano-kes-rotate.sh install
```

## Veiligheidsmaatregelen

- Nieuwe `kes.skey` blijft op de block producer en wordt niet naar USB gekopieerd.
- `cold.skey` en `cold.counter` blijven op de offline cold node.
- SHA-256-controles beschermen de overgedragen `kes.vkey` en `node.cert`.
- De geretourneerde `kes.vkey` moet exact bij de lokaal bewaarde pending key horen.
- De actieve credentials worden vóór installatie geback-upt onder `~/kes-rotation/backups/` (bij `sudo` doorgaans `/root/kes-rotation/backups/`).
- `cold.counter` wordt vóór en na `issue-op-cert` geback-upt.
- Bestanden worden met beperkte rechten geïnstalleerd.

## Opties en probleemoplossing

Een afwijkende werkmap kan met:

```bash
sudo KES_ROTATION_HOME=/var/lib/cardano-kes-rotation ./cardano-kes-rotate.sh
```

Bekijk de help:

```bash
./cardano-kes-rotate.sh --help
```

Bij een fout stopt het script onmiddellijk. Verwijder een `pending`-map niet zonder eerst vast te stellen of daarin de enige nieuwe KES signing key staat. Wanneer een herstart mislukt, staat het exacte back-uppad in de foutmelding.

## Licentie

MIT
