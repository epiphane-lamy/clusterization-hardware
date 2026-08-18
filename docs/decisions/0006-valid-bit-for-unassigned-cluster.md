# ADR-0006 — Bit de validité plutôt que valeur sentinelle pour les clusters non assignés

## Statut
Retenu

## Contexte
Dans le modèle logiciel de référence, chaque point se voit attribuer un numéro de cluster initialisé à `-1`, utilisé comme valeur sentinelle pour signifier "pas encore assigné à un cluster". Ce mécanisme repose sur le fait qu'un tableau logiciel peut être initialisé à une valeur arbitraire au démarrage, et que `-1` est trivialement distinguable de tout numéro de cluster valide (toujours positif ou nul).

Cette hypothèse ne tient pas directement en hardware : une mémoire ne possède pas d'état "non initialisé" observable et fiable au moment de la lecture — son contenu au reset dépend de la technologie cible et ne peut pas être supposé nul ou constant de façon portable. Reproduire `-1` comme sentinelle nécessiterait soit une initialisation explicite de toute la mémoire au reset (coût en cycles, ou en logique dédiée selon la cible), soit de réserver une valeur du champ numéro-de-cluster comme sentinelle.

## Options considérées

1. **Réserver une valeur du champ numéro-de-cluster comme sentinelle** (ex. la valeur maximale représentable), équivalent direct du `-1` logiciel.
   - Ne nécessite pas de bit supplémentaire.
   - Réduit le nombre de clusters effectivement représentables de un (une valeur du champ est "consommée" par la sentinelle).
   - Nécessite tout de même une initialisation explicite de la mémoire à cette valeur sentinelle au reset, pour que l'état "non assigné" soit garanti au démarrage.

2. **Bit de validité dédié, un par ligne de la mémoire cluster, séparé du champ numéro-de-cluster.**
   - Le contenu du champ numéro-de-cluster lui-même n'a besoin d'aucune initialisation particulière : sa valeur n'est significative que lorsque le bit de validité associé est à 1.
   - Le bit de validité est initialisé à 0 au reset (coût minime : un bit par point, largement plus simple à garantir qu'une initialisation complète du champ numéro-de-cluster).
   - Le champ numéro-de-cluster garde l'intégralité de sa plage de représentation disponible pour de vrais numéros de cluster.

## Décision
Option 2 : un bit de validité dédié par ligne de la mémoire cluster (`valid_cluster`, visible sur le schéma toplevel de la partie 2), initialisé à 0 au reset. Un point est considéré comme non assigné tant que son bit de validité vaut 0, indépendamment du contenu du champ numéro-de-cluster à cette adresse.

## Conséquences

**Positives**
- Aucune contrainte d'initialisation sur le champ numéro-de-cluster lui-même — seul le bit de validité doit être garanti à 0 au reset, ce qui est trivial à assurer quelle que soit la cible (FPGA ou ASIC).
- Toute la plage du champ numéro-de-cluster reste disponible pour représenter de vrais clusters, sans valeur sacrifiée comme sentinelle.
- Sémantique explicite et sans ambiguïté à la lecture du RTL : la validité d'une donnée est portée par un signal dédié plutôt que déduite d'une convention sur le contenu.

**Négatives / limites**
- Un bit supplémentaire par point dans la mémoire cluster (coût mémoire marginal comparé au champ numéro-de-cluster lui-même).
- Introduit une divergence de représentation avec le modèle logiciel de référence (`-1` vs `valid = 0`), à garder en tête lors de la comparaison des résultats du testbench avec le modèle de référence bit-exact (voir ARCHITECTURE.md, §9) : la comparaison doit interpréter `valid = 0` comme équivalent à `-1`, pas comparer les deux champs bruts terme à terme.
