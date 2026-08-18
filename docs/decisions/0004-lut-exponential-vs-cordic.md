# ADR-0004 — LUT pour l'exponentielle et l'inverse, plutôt que CORDIC

## Statut
Retenu

## Contexte
Le calcul du noyau gaussien de la matrice `P` nécessite une exponentielle (`exp(argument)`), et la normalisation de chaque ligne nécessite une division, implémentée comme une multiplication par l'inverse de la somme de ligne. Ces deux fonctions non linéaires n'ont pas d'implémentation matérielle triviale.

## Options considérées

1. **CORDIC** (ou algorithme itératif équivalent) pour le calcul de l'exponentielle et de l'inverse.
   - Solution générique, couvre n'importe quelle plage d'entrée sans hypothèse préalable sur la distribution des arguments.
   - Coût en architecture significatif : pipeline itératif à plusieurs étages, lourd à intégrer pour un gain de généralité qui n'est pas nécessaire ici (voir ci-dessous).

2. **LUT (table de correspondance), dimensionnée après étude de la plage réelle des arguments observés sur le modèle logiciel de référence.**
   - Nécessite une analyse préalable de la distribution des arguments pris par `exp()` sur des cas réels, pour vérifier qu'une LUT de taille raisonnable peut couvrir la plage utile sans perte excessive.
   - Coût matériel très inférieur à CORDIC (une mémoire adressée directement, pas de pipeline itératif).

## Analyse ayant motivé la décision
Une étude de la plage de valeurs prise par l'argument de `exp()` sur le modèle logiciel de référence a montré que cet argument, toujours négatif, reste **borné et sature rapidement vers 0** en dessous d'un certain seuil (au-delà duquel la contribution au noyau gaussien est de toute façon négligeable). Cette plage étroite rend une LUT directement adressée par l'argument quantifié à la fois précise et de taille raisonnable.

Pour l'inverse (utilisé dans la normalisation), la plage dynamique de la somme de ligne à inverser est en revanche large. Un adressage direct par la valeur aurait demandé une LUT surdimensionnée. La solution retenue adresse la LUT inverse par la **mantisse** de la somme (après extraction du bit de poids fort et décalage), ce qui permet de couvrir toute la plage dynamique utile avec une LUT de taille fixe et raisonnable (1024 entrées).

## Décision
Implémentation de `exp()` et de l'inverse par LUT :
- LUT `exp`, adressée directement par l'argument quantifié (Q6.10), 10241 entrées en Q0.16.
- LUT inverse, adressée par la mantisse de la somme de ligne, 1024 entrées en Q0.16.

## Conséquences

**Positives**
- Coût matériel très inférieur à une implémentation CORDIC : simple mémoire adressée, pas de pipeline itératif multi-étages.
- Latence de calcul fixe et connue (accès mémoire simple), plutôt que le nombre d'itérations variable ou fixe mais élevé d'un CORDIC.
- L'adressage par mantisse pour l'inverse permet de couvrir une large plage dynamique sans faire croître la taille de la LUT.

**Négatives / limites**
- Solution spécifique à la distribution des arguments observée sur ce jeu de données et cet algorithme — contrairement à CORDIC, elle n'est pas généralisable telle quelle à un autre contexte de calcul sans revalider l'étude de plage.
- Précision limitée par la résolution de la LUT (quantification supplémentaire par rapport à un calcul direct), dont l'impact a été mesuré dans la chaîne de quantification globale (voir [ADR-0001](0001-fixed-point-quantization-chain.md)).
- Coût mémoire fixe des deux LUT (au total environ 20 ko), à mettre en balance avec la surface qu'aurait occupée un CORDIC — jugé favorable ici étant donné le gain de simplicité de contrôle.
