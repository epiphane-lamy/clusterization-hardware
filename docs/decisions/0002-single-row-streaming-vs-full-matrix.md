# ADR-0002 — Streaming ligne par ligne de la matrice P plutôt que stockage complet

## Statut
Retenu

## Contexte
Le modèle logiciel de référence construit et stocke intégralement une matrice `P` de taille `N × N` à chaque itération de l'algorithme, où `N` est le nombre de points. Pour un jeu de test raisonnable de 1000 points, cela représente 1 000 000 de coefficients — même codés sur 16 bits (Q0.16), cela correspond à 2 Mo à reconstruire à chaque itération. Sur une cible FPGA de taille modeste, ou en vue d'un flot ASIC où chaque bit de mémoire a un coût direct en surface, cette approche est inenvisageable telle quelle.

## Options considérées

1. **Stocker la matrice `P` complète en mémoire (reproduction directe de l'algorithme logiciel).**
   - Fidèle à l'algorithme d'origine, aucune restructuration de l'ordre des calculs nécessaire.
   - Empreinte mémoire en `O(N²)`, rédhibitoire dès que `N` dépasse quelques dizaines de points.

2. **Produire et consommer la matrice `P` ligne par ligne, sans jamais la matérialiser en entier.**
   - Le bloc `exp` produit une ligne de `P` (les `N` coefficients relatifs à un point `i`), le bloc `grad` la consomme immédiatement pour calculer la contribution au gradient du point `i`, puis la ligne suivante peut être produite.
   - Empreinte mémoire en `O(N)` (une seule ligne à la fois), au prix d'une restructuration du flux de calcul par rapport au modèle logiciel d'origine.

## Décision
Option 2 : le bloc `exp` produit `P` ligne par ligne, consommée au fil de l'eau par le bloc `grad`. Aucune mémoire ne stocke la matrice `P` complète à aucun moment de l'exécution.

## Conséquences

**Positives**
- Empreinte mémoire réduite de `O(N²)` à `O(N)` — pour 1000 points, passage de 2 Mo à quelques ko.
- Rend l'architecture viable aussi bien en FPGA qu'en vue d'un flot ASIC où la surface mémoire est directement coûteuse.
- Ce choix structure toute l'architecture mémoire du projet (voir [ADR-0003](0003-ping-pong-buffering.md) pour la suite directe de cette décision).

**Négatives / limites**
- Le simple enchaînement séquentiel (exp écrit → grad lit → exp écrit à nouveau) introduit un temps mort entre les deux blocs, qui a nécessité une solution complémentaire de recouvrement (voir ADR-0003).
- Le calcul de la somme de normalisation d'une ligne, qui nécessitait auparavant une deuxième passe sur la matrice complète dans le modèle logiciel, doit être recalculé différemment pour rester compatible avec un flux ligne par ligne (accumulation à la volée par le bloc `exp`, voir ARCHITECTURE.md §6).
