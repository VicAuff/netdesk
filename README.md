# NetDesk

Nettoyeur pour macOS, écrit de zéro en SwiftUI. Il retrouve les caches, les gros fichiers, les doublons, les restes d'apps et les traces de navigation, puis met à la Corbeille ce qu'on a choisi.

Il ne demande jamais les droits administrateur et ne laisse rien tourner en arrière-plan : fermer la fenêtre quitte l'app.

## Modules

- **Analyse express** : un passage sur tout le Mac, et un clic pour nettoyer les caches, journaux et réglages cassés.
- **Nettoyage** : caches et journaux, déchets de développement (Xcode, npm), pièces jointes Mail, sauvegardes iPhone, modèles d'IA locaux.
- **Corbeilles** : vide la Corbeille du Mac et celles des disques branchés.
- **Confidentialité** : historique, cookies et saisie des navigateurs, éléments récents, autorisations des apps.
- **Performance** : apps ouvertes à la connexion et agents en arrière-plan.
- **Applications** : désinstalleur qui emporte les fichiers laissés par l'app, restes d'apps déjà supprimées, installeurs oubliés.
- **Fichiers à trier** : gros fichiers, doublons, téléchargements classés par provenance.
- **Carte du disque** : ce qui prend de la place, dossier par dossier.
- **Moniteur** : processeur, mémoire, disque et batterie, aussi dans la barre des menus tant que l'app est ouverte.
- **Nettoyage d'écran** : clavier et trackpad bloqués le temps d'essuyer l'écran.
- **Journal** : tout ce qui a été fait, avec remise en place depuis la Corbeille.

## Garde-fous

- Tout part à la Corbeille, après un aperçu et une confirmation. Vider la Corbeille est la seule suppression définitive, et la touche Entrée ne suffit pas à la valider.
- Les exclusions sont inscrites dans le code (`Sources/CleanCore/SafetyPolicy.swift`) : iCloud Drive, `~/Library/CloudStorage`, les trousseaux, `~/.ssh`, `~/.gnupg`, `~/.local`, Syncthing, Homebrew, `/Library`, les fichiers système et tout ce que protège SIP. Les liens symboliques sont résolus avant le contrôle.
- Une app ouverte garde ses fichiers. L'app le revérifie juste avant d'agir, au cas où elle aurait été ouverte après l'analyse.
- La carte du disque montre tout le disque, mais ne met à la Corbeille que les fichiers du dossier perso, hors bibliothèque et dossiers cachés.
- Les autorisations, mots de passe et sauvegardes se cochent un par un : la case d'un groupe les ignore.
- Seule exception aux droits administrateur : macOS demande lui-même le mot de passe pour désinstaller une app qui appartient au système, comme celles de l'App Store.

## Protections personnelles

Les dossiers et apps propres à une machine se déclarent hors du code, dans `~/Library/Application Support/NetDesk/protections.json` :

```json
{ "folders": ["~/Sync", "~/.private"], "apps": ["com.example.dictation"] }
```

Les `folders` sont exclus comme ceux du code. Les `apps` sont des préfixes d'identifiants : leurs fichiers ne passent jamais pour des restes, et leurs autorisations ne peuvent pas être retirées.

## Construire

Les Command Line Tools suffisent, sans Xcode.

```sh
./scripts/build-app.sh            # .build/NetDesk.app
./scripts/build-app.sh --install  # copie aussi l'app dans ~/Applications
```

Sans réglage, l'app est signée « ad hoc », et macOS lui retire l'accès complet au disque à chaque compilation. Pour le garder, il faut une identité de signature stable (un certificat auto-signé dans un trousseau suffit), déclarée dans `local.env` sur le modèle de `local.env.example`.

Avec le SDK macOS 27, `@State` est une macro dont le greffon n'est livré qu'avec Xcode. L'app passe par l'alias `LocalState` (`Sources/NetDesk/LocalState.swift`).

## Tester

```sh
NETDESK_TEST_ROOT=/tmp/netdesk-tests swift test
```

Les tests montent un faux dossier perso et une fausse Corbeille sous `NETDESK_TEST_ROOT`, sans jamais toucher au vrai disque. Il faut passer par `swift test` : `swift build --build-tests` ne charge pas le greffon de Swift Testing.

`swift run netdesk-scan <module>` lance une analyse en lecture seule. Modules : junk, trash, large, duplicates, downloads, installers, apps, orphans, privacy, performance, space, monitor.

Pour contrôler la mise en page sans capture d'écran : `open -n --env NETDESK_DUMP_VIEWS=/chemin/fichier.txt NetDesk.app`. L'app passe sur chaque module et note la taille de ses conteneurs, qui doivent égaler celle de la fenêtre.

## Accès complet au disque

L'app tourne sans, mais elle ne voit alors ni Mail, ni Safari, ni la Corbeille, ni les autorisations. Elle s'ajoute dans Réglages Système > Confidentialité et sécurité > Accès complet au disque.

## Licence

NetDesk est sous double licence, [MIT](LICENSE-MIT) ou [Apache-2.0](LICENSE-APACHE), au choix.

Le nom NetDesk et son logo ne sont pas couverts par cette licence.
