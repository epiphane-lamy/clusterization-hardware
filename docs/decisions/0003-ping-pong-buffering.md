# ADR-0003 — Double buffering (ping-pong) entre `exp` et `grad`, et duplication des mémoires de coordonnées

## Statut
Retenu

## Contexte
Suite à [ADR-0002](0002-single-row-streaming-vs-full-matrix.md), `P` est traité ligne par ligne via une mémoire tampon partagée entre `exp` (producteur) et `grad` (consommateur). Un enchaînement strictement séquentiel sur une seule mémoire de ligne (exp écrit → grad lit → exp écrit à nouveau) introduit un temps mort important : chaque bloc doit attendre que l'autre ait terminé avant de commencer son propre accès.

## Options considérées

1. **Une seule mémoire de ligne, accès strictement séquentiel entre `exp` et `grad`.**
   - Architecture la plus simple, empreinte mémoire minimale (une seule ligne stockée).
   - Aucun recouvrement possible entre la production d'une ligne et sa consommation : le temps de traitement total est la somme des deux, ligne après ligne.

2. **Deux mémoires de ligne (A et B) avec un arbitre de ping-pong.**
   - Pendant que `exp` écrit la ligne `i+1` dans la mémoire A, `grad` lit simultanément la ligne `i` (déjà produite) dans la mémoire B. Une fois les deux terminés, l'arbitre échange les rôles des deux mémoires (aiguillage, sans copie de données).
   - Recouvre les deux phases : le temps de traitement se rapproche du plus lent des deux blocs plutôt que de leur somme.
   - Coût : le double de mémoire de ligne par rapport à l'option 1 (deux lignes stockées au lieu d'une), et un bloc arbitre supplémentaire.

## Conséquence annexe et sous-décision : duplication des coordonnées

Le recouvrement de l'option 2 impose que `exp` et `grad` puissent lire les coordonnées des points **simultanément**, chacun pour la ligne qu'il traite. Une mémoire de coordonnées unique à un seul port de lecture entrerait en conflit d'accès entre les deux blocs.

Deux options ont été considérées pour ce sous-problème :
- **Mémoire de coordonnées unique, arbitrage d'accès entre `exp` et `grad`** : réintroduit un temps mort équivalent à celui que le ping-pong cherche justement à éliminer.
- **Dupliquer la mémoire de coordonnées** (une copie dédiée à `exp`, une à `grad`) : chaque bloc a un accès dédié, sans arbitrage ni conflit.

La duplication va, en apparence, à l'encontre de l'objectif de sobriété mémoire fixé par ADR-0002. Le coût réel reste néanmoins marginal : les coordonnées sont codées sur 16 bits en Q8.8, une mémoire de coordonnées dupliquée reste très largement plus petite que ne l'aurait été la matrice `P` complète évitée par ADR-0002.

## Décision
Option 2 (ping-pong à deux mémoires de ligne), combinée à la duplication de la mémoire de coordonnées entre `exp` et `grad`.

## Conséquences

**Positives**
- Recouvrement effectif entre production et consommation d'une ligne de `P` : le temps de calcul total est divisé par deux par rapport à un enchaînement strictement séquentiel.
- Les deux blocs de calcul (`exp` et `grad`) travaillent en parallèle sur des lignes différentes en permanence.
- Le coût mémoire de la duplication des coordonnées reste négligeable comparé au gain apporté par ADR-0002.

**Négatives / limites**
- Empreinte mémoire des lignes de `P` doublée par rapport à un schéma à une seule mémoire (reste cependant en `O(N)`, donc sans remise en cause de l'objectif global d'ADR-0002).
- Complexité de contrôle supplémentaire : le bloc `ping pong arbitrer` doit garantir que l'échange entre mémoires A et B n'intervient qu'une fois les deux accès (écriture par `exp`, lecture par `grad`) effectivement terminés.
- Va explicitement à l'encontre de l'objectif initial "memory light" formulé dans ADR-0002 — assumé comme compromis délibéré et chiffré, pas comme un oubli.
