# ADR-0005 — Entropie de Gini plutôt que Shannon

## Statut
Retenu

## Contexte
Le modèle logiciel de référence utilise l'entropie de Shannon pour mesurer la dispersion de chaque ligne normalisée de `P`, valeur ensuite utilisée pour moduler l'intensité du déplacement de chaque point. Le calcul de l'entropie de Shannon nécessite un `log()`, ce qui pose exactement le même problème d'implémentation matérielle que l'exponentielle traitée en [ADR-0004](0004-lut-exponential-vs-cordic.md).

## Options considérées

1. **LUT pour `log()`, sur le même principe que la LUT `exp()`.**
   - Cohérent avec l'approche déjà retenue pour l'exponentielle.
   - Nécessite une deuxième LUT dédiée, avec sa propre étude de plage d'arguments, doublant la surface consacrée aux fonctions non linéaires.

2. **Entropie de Gini, comme mesure de dispersion alternative.**
   - Existe comme mesure de dispersion utilisable à la place de Shannon pour cet usage (moduler l'intensité de déplacement selon la dispersion des similarités d'un point à ses voisins).
   - Se calcule directement à partir d'une somme de carrés des coefficients normalisés de la ligne (`1 - Σ p_ij²`), sans fonction non linéaire supplémentaire — uniquement des multiplications déjà présentes dans le pipeline de calcul.

## Décision
Utilisation de l'entropie de Gini (`H_fixed = 1 - Σ p_ij²`, calculée en Q0.16) à la place de l'entropie de Shannon, comme critère de modulation de la force de déplacement de chaque point.

## Conséquences

**Positives**
- Aucune LUT ni étage combinatoire supplémentaire dédié à une fonction non linéaire : le calcul de Gini se fait avec les multiplieurs déjà utilisés par le pipeline `exp`/`grad`.
- Calcul entièrement compatible avec le flux en pipeline sans buffer caché (voir ARCHITECTURE.md §6) : l'accumulation `Σ p_ij²` se fait au fil de l'eau, comme la somme de normalisation.
- Réduit d'autant la surface totale dédiée aux fonctions non linéaires du design.

**Négatives / limites**
- Introduit une **divergence assumée** par rapport au modèle logiciel de référence, qui utilise Shannon : le seuil de déclenchement de la modulation de force (`limiar_cirurgico`) doit être recalibré spécifiquement pour l'échelle de valeurs de Gini plutôt que d'être repris tel quel du seuil Shannon.
- L'écart de comportement entre les deux mesures d'entropie sur les cas limites (distributions très proches de l'équiprobabilité ou très concentrées) n'a pas encore été caractérisé de façon exhaustive — à documenter au fur et à mesure des tests de convergence.
