# ADR-0001 — Quantification fixed-point étage par étage, avec modèle de référence bit-exact

## Statut
Retenu

## Contexte
Le modèle logiciel de référence effectue tous ses calculs en flottant double précision (distance euclidienne, argument gaussien, exponentielle, normalisation, gradient, mise à jour de position). Une implémentation matérielle flottante de cette chaîne est disproportionnée en surface et en consommation par rapport au besoin réel de précision de l'algorithme.

## Options considérées

1. **Conversion flottant → fixed-point globale et approximative** : choisir un format Q unique "confortable" (ex. Q16.16 partout) pour toute la chaîne, sans analyse fine.
   - Simple à mettre en œuvre, mais risque de sur-dimensionner certains bus (surface gaspillée) ou de sous-dimensionner d'autres étages (perte de précision non maîtrisée, risque de divergence de l'algorithme).

2. **Quantification étape par étage, avec mesure d'erreur à chaque étage par rapport au calcul flottant de référence.**
   - Demande plus de travail d'analyse en amont (établir le format Q le plus juste à chaque étage : distance, argument, exponentielle, somme de normalisation, gradient, mise à jour).
   - Permet de dimensionner chaque bus au plus juste, en connaissance de l'erreur induite.
   - Sous-produit direct : une fois toute la chaîne quantifiée, il devient possible de faire tourner un **modèle logiciel entièrement en fixed-point**, qui reproduit exactement les calculs qui seront faits en hardware.

## Décision
Quantification étage par étage (option 2), avec mesure systématique de l'écart au flottant à chaque étage. Le modèle logiciel fixed-point qui en résulte sert de modèle de référence bit-exact pour les testbenchs RTL : chaque signal intermédiaire produit par la simulation matérielle est comparé directement aux résultats intermédiaires produits par ce modèle, plutôt qu'à une resimulation flottante.

## Conséquences

**Positives**
- Chaque bus de données est dimensionné au plus juste, ce qui limite le coût en surface/registres sans sacrifier la précision nécessaire.
- Le modèle de référence bit-exact élimine toute ambiguïté lors du débogage de testbench : un écart entre RTL et modèle de référence est nécessairement un bug RTL, pas un artefact d'arrondi de comparaison flottant/fixed-point.
- La démarche est documentée et reproductible pour d'éventuelles évolutions du format Q sur un étage donné.

**Négatives / limites**
- Travail d'analyse initial plus long qu'une conversion globale approximative.
- Le modèle de référence fixed-point doit être maintenu en cohérence avec le RTL à chaque évolution de l'architecture (tout changement de format Q côté hardware doit être répercuté côté modèle logiciel).
