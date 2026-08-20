# Architecture — Moteur de clustering 2D basé sur l'entropie

Ce document détaille le cheminement complet du projet : du modèle logiciel de référence fourni par le laboratoire jusqu'à l'architecture matérielle SystemVerilog qui en découle, en passant par la quantification et les arbitrages de conception. Pour une vue d'ensemble rapide, voir le [README](../README.md). Pour le détail argumenté de chaque choix fort, voir les [ADR](decisions/).

> **Périmètre de ce document** : architecture toplevel et décisions de conception qui structurent le projet. Le détail micro-architectural interne des blocs de calcul [exp](blocks/exp_block.md), [grad](blocks/grad_block.md), [ping_pong_arbiter](blocks/ping_pong_arbiter.md), [upd](blocks/upd_block.md), [cluster_assign](blocks/cluster_assign.md) est couvert dans [blocks](blocks/).

---

## 1. Le modèle logiciel de référence

Le point de départ est un algorithme de clustering 2D développé par un collègue du laboratoire (Elias De Almeida Ramos), écrit en C, en flottant double précision. Sa particularité, et la raison pour laquelle il a été retenu comme candidat au portage matériel, est qu'il **n'a pas besoin de connaître à l'avance le centre du nuage de points** pour fonctionner : le regroupement se fait par un mécanisme itératif basé sur le calcul d'entropie de chaque point par rapport à ses voisins, plutôt que par une distance à un centroïde fixé a priori (contrairement à k-means par exemple).

À chaque itération (`step`), l'algorithme :
1. Calcule une matrice de similarité `P` entre tous les points, via un noyau gaussien appliqué à la distance euclidienne entre chaque paire de points.
2. Normalise chaque ligne de `P` (somme = 1).
3. Calcule l'entropie de chaque ligne, utilisée pour moduler l'intensité du déplacement du point correspondant.
4. Calcule un gradient (déplacement pondéré vers les voisins similaires) et met à jour la position de chaque point.
5. Répète sur `N` itérations, jusqu'à convergence des points en amas distincts.
6. Une passe finale associe un numéro de cluster à chaque point regroupé.

C'est cette structure en deux temps — **la boucle itérative qui déplace les points** puis **l'association finale des clusters** — qui a directement guidé le découpage de l'architecture matérielle en deux parties (voir §3).

---

## 2. Le constat qui a orienté toute l'architecture : la matrice O(n²)

En analysant le code de référence, le premier problème saute aux yeux : à chaque itération, l'algorithme construit et stocke intégralement une matrice `P` de taille `N × N` avec `N` le nombre de points du benchmark.

Pour un jeu de test raisonnable de 1000 points, cela représente **1 000 000 de coefficients**. Même codés sur 16 bits (format Q0.16 après quantification), cela correspond à **2 Mo de mémoire, à reconstruire à chaque itération, pour une seule des N itérations de l'algorithme**. Sur une cible FPGA de taille modeste, ou a fortiori en vue d'un flot ASIC où chaque bit de mémoire a un coût en surface, cette approche telle quelle est inenvisageable.

Ce constat a fixé l'objectif numéro un de l'architecture avant même de commencer à découper les blocs de calcul : **ne jamais stocker la matrice `P` complète**. Tout le reste des choix de conception (streaming ligne par ligne, ping-pong, calcul de la somme de normalisation à la volée) découle de cette contrainte.

Voir [ADR-0002](decisions/0002-single-row-streaming-vs-full-matrix.md) pour le détail de ce choix et l'alternative écartée.

---

## 3. Vue d'ensemble : deux parties fonctionnelles

L'architecture matérielle reprend la structure du modèle logiciel en deux blocs de plus haut niveau, correspondant chacun à une des étapes de l'algorithme d'origine.

### Partie 1 — Boucle itérative (répétée `N` fois)

![Architecture logicielle de référence, partie 1](img/archi_part1_software.png)

*Modèle logiciel de référence pour une itération : construction de `P`, calcul du gradient, mise à jour des coordonnées.*

Cette étape est traduite matériellement par le pipeline suivant, exécuté une fois par itération :

![Architecture matérielle toplevel, une itération](img/archi_part1.png)

Le flux de données suit la même logique que le modèle logiciel (`exp` → matrice `P` → `grad` → mise à jour des coordonnées), mais **sans jamais matérialiser `P` en entier** : c'est tout l'objet du bloc `ping pong arbiter` au centre du schéma, détaillé au §4.

### Partie 2 — Association finale des clusters

![Architecture logicielle de référence, partie 2](img/archi_part2_software.png)

Une fois les `N` itérations terminées, les coordonnées finales des points ont convergé en amas. Le bloc `cluster assign` associe alors un numéro de cluster à chaque point à partir de leur position finale :

![Architecture matérielle toplevel, association des clusters](img/archi_part2.png)


Un point de conception toplevel mérite d'être noté ici : la mémoire `memory cluster` associe à chaque point son numéro de cluster, mais un point peut ne pas encore avoir été assigné. Là où le modèle logiciel de référence utilise une valeur sentinelle (`-1`) pour représenter cet état, l'architecture matérielle porte cette information via un **bit de validité dédié** (`valid_cluster`, visible sur le schéma ci-dessus) plutôt que par une valeur réservée dans le champ numéro-de-cluster. Voir [ADR-0006](decisions/0006-valid-bit-for-unassigned-cluster.md).

---

## 4. Architecture mémoire de la boucle itérative

C'est le cœur technique du projet. Trois problèmes s'enchaînent, chacun résolu par un choix d'architecture spécifique.

### 4.1 Ne stocker qu'une ligne de `P` à la fois

Plutôt que de construire `P` en entier, le bloc `exp` produit `P` **ligne par ligne** : pour un point `i` donné, il calcule les `N` coefficients `P[i][0..N-1]` et les écrit dans une mémoire tampon ne pouvant contenir qu'une seule ligne. Le bloc `grad` vient ensuite lire cette ligne pour calculer la contribution au gradient du point `i`. Une fois cette ligne consommée, `exp` peut écrire la suivante.

Cela fait chuter l'empreinte mémoire de `O(N²)` à `O(N)` — pour 1000 points, on passe de 2 Mo à quelques ko.

### 4.2 Le ping-pong entre deux mémoires de ligne

Le simple enchaînement séquentiel décrit ci-dessus (exp écrit → grad lit → exp écrit à nouveau) introduit un temps mort important : `grad` doit attendre que `exp` ait fini d'écrire, et `exp` doit attendre que `grad` ait fini de lire avant de réutiliser le buffer.

Pour recouvrir ces deux phases, l'architecture utilise **deux mémoires de ligne (A et B)** pilotées par un bloc `ping pong arbiter` : pendant que `exp` écrit la ligne `i+1` dans la mémoire A, `grad` lit simultanément la ligne `i` (déjà produite) dans la mémoire B. Une fois les deux terminés, l'arbitre échange les rôles des deux mémoires, sans copie de données — seule la table d'aiguillage change.

Voir [ADR-0003](decisions/0003-ping-pong-buffering.md).

### 4.3 Duplication des mémoires de coordonnées

Ce recouvrement introduit à son tour une contrainte annexe : les blocs `exp` et `grad` ont besoin de lire les coordonnées des points **simultanément** (chacun pour sa propre ligne en cours de traitement). Une seule mémoire de coordonnées à un seul port de lecture les ferait entrer en conflit d'accès.

La solution retenue est de **dupliquer** la mémoire de coordonnées (une copie pour `exp`, une pour `grad`). C'est un choix qui va, en apparence, à l'encontre de l'objectif initial de sobriété mémoire — mais le coût est marginal : les coordonnées sont codées sur 16 bits en Q8.8, donc même dupliquée, cette mémoire reste largement plus petite que l'aurait été la matrice `P` complète. En contrepartie, les deux blocs de calcul peuvent travailler en parallèle, ce qui divise le temps de calcul par deux. Ce compromis est détaillé dans le même ADR-0003.

### 4.4 Organisation "dual-port" des mémoires de coordonnées

Chaque mémoire de coordonnées est organisée pour qu'une seule adresse (l'indice du point) retourne en sortie **les deux composantes `x` et `y`** de ce point simultanément, plutôt que d'avoir à faire deux accès séparés. Les deux valeurs d'un même point restent ainsi toujours accédées ensemble, ce qui simplifie l'interface avec `exp` et `grad`.

### 4.5 Mémoire de mise à jour (`memory update`)

Au fur et à mesure que `grad` calcule les contributions de mise à jour pour chaque point, les résultats sont accumulés dans une mémoire `memory update`, de taille comparable aux mémoires de coordonnées (deux valeurs Q8.8 par point : mise à jour de `x` et de `y`). Une fois que tous les points de l'itération ont été traités, cette mémoire est pleine, et le bloc `upd` peut appliquer la mise à jour aux deux mémoires de coordonnées pour clore l'itération en cours.

### 4.6 Format de la ligne de `P`

Chaque mémoire de ligne (A ou B) contient `N` coefficients codés sur 16 bits en format **Q0.16** (valeurs de similarité normalisées entre 0 et 1).

---

## 5. Fonctions non linéaires : `exp()` et l'inverse, sans CORDIC

Le calcul du noyau gaussien (matrice `P`) nécessite une exponentielle, et la normalisation de chaque ligne nécessite une division (implémentée comme une multiplication par l'inverse de la somme).

L'implémentation matérielle classique de ces deux fonctions serait CORDIC — mais l'architecture combinatoire ou pipeline que cela demande est lourde à intégrer pour un gain qui n'est pas justifié ici. Une étude de la plage réelle des arguments pris par `exp()` sur le modèle logiciel de référence a montré que cette plage est en réalité **étroite et bornée** (l'argument, toujours négatif, sature rapidement vers 0 en dessous d'un certain seuil). Cela a permis de remplacer CORDIC par deux **LUT** :

- **LUT `exp`** : adressée directement par l'argument quantifié (format Q6.10), 10241 entrées codées en Q0.16.
- **LUT inverse (`inv`)** : utilisée pour la normalisation. Contrairement à la LUT `exp`, son adressage se fait par la **mantisse** de la somme de ligne (extraction de bit de poids fort + décalage), ce qui permet de couvrir une large plage dynamique de valeurs de somme avec seulement 1024 entrées.

Voir [ADR-0004](decisions/0004-lut-exponential-vs-cordic.md).

---

## 6. Normalisation en flux, sans buffer caché

La normalisation d'une ligne de `P` nécessite la somme de tous ses coefficients. Plutôt que de recalculer cette somme dans une passe séparée, elle est accumulée **directement par le bloc `exp`**, au fur et à mesure qu'il produit et écrit les coefficients non normalisés dans la mémoire A ou B. Le bloc `grad`, lorsqu'il lit ensuite cette ligne, applique la normalisation via la LUT inverse décrite au §5.

Ce choix maintient le principe directeur de toute l'architecture : **aucune mémoire cachée dans les blocs de calcul, aucune donnée intermédiaire stockée en dehors des buffers de ligne identifiés** — tout se fait en flux, dans un pipeline.

---

## 7. Entropie : Gini plutôt que Shannon

Le calcul d'entropie de chaque ligne de `P` (utilisé pour moduler la force de déplacement de chaque point) pose, dans le modèle logiciel de référence, le même problème que l'exponentielle : l'entropie de Shannon nécessite un `log()`.

Plutôt que d'ajouter une deuxième LUT non linéaire pour `log()`, l'architecture matérielle utilise l'**entropie de Gini** comme substitut : une mesure de dispersion algébriquement équivalente pour l'usage recherché ici, mais qui se calcule uniquement à partir d'une somme de carrés des coefficients de la ligne — donc directement à partir des multiplieurs déjà présents dans le pipeline, sans fonction non linéaire supplémentaire.

Voir [ADR-0005](decisions/0005-gini-entropy-vs-shannon.md) pour la comparaison chiffrée entre les deux mesures et l'écart accepté par rapport au modèle de référence.

---

## 8. Chaîne de quantification et modèle de référence bit-exact

L'ensemble de la chaîne de calcul (distance, argument de l'exponentielle, coefficients de `P`, gradient, mise à jour de position) a été quantifié **étape par étape**, en mesurant l'erreur introduite à chaque étage par rapport au calcul flottant équivalent, plutôt que par une conversion globale approximative en une seule passe. Cela a permis de dimensionner chaque format Q au plus juste (ni sur-dimensionné en surface, ni sous-dimensionné au point de dégrader la convergence de l'algorithme).

| Grandeur | Format | Remarque |
|---|---|---|
| Coordonnées des points (`X_f`, `Y_f`) | Q8.8, 16 bits | Suffisant après normalisation initiale des points dans la plage [0, 255] |
| Argument de l'exponentielle | Q6.10 | Plage réduite justifiant la LUT (§5) |
| Coefficients de `P` (non normalisés puis normalisés) | Q0.16 | Sortie directe de la LUT `exp`, réutilisée telle quelle après normalisation |
| Somme de ligne / adressage LUT inverse | Mantisse extraite dynamiquement | Couvre une large plage dynamique avec une LUT de taille fixe |
| Entropie de Gini (`H_fixed`) | Q0.16 | Complément à 1 de la somme des carrés normalisés |

Cette quantification étage par étage a un second bénéfice, indépendant du dimensionnement des bus : une fois appliquée intégralement, elle permet de faire tourner le **modèle logiciel de référence entièrement en fixed-point**, en parallèle de sa version flottante d'origine. Ce modèle "bit-exact" produit tous les résultats intermédiaires attendus du hardware (matrice `P`, gradients, entropies, mises à jour), et sert de référence directe pour les testbenchs : les résultats de simulation RTL sont comparés directement à ce modèle plutôt qu'à une resimulation flottante approximative.

Voir [ADR-0001](decisions/0001-fixed-point-quantization-chain.md).

---

## 9. Stratégie de vérification

La vérification du design suit deux niveaux, tous deux comparés au modèle de référence bit-exact décrit au §8 plutôt qu'à une resimulation flottante :

- **Testbenchs unitaires**, un par bloc de calcul (`exp`, `grad`, `upd`, `cluster_assign`), permettant d'isoler et de valider le comportement de chaque bloc indépendamment du reste de la chaîne — utile en particulier pour déboguer un bloc sans dépendre de la disponibilité ou de la correction des autres.
- **Testbench d'intégration global ou partiellement globel**, exerçant des ensembles ou la totalité du pipeline toplevel sur un jeu de points complet, et comparant les résultats de bout en bout — coordonnées finales et clusters assignés — à ceux produits par le modèle de référence.

Dans les deux cas, la comparaison se fait directement contre les résultats intermédiaires produits par le modèle logiciel fixed-point (§8) : matrice `P` ligne par ligne, gradients, entropies, mises à jour de position. Un écart entre simulation RTL et modèle de référence est donc imputable sans ambiguïté au RTL, et non à un artefact de comparaison entre flottant et fixed-point.

