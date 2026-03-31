# Terrain — Lissage adaptatif des zones plates

## Problème

Le RGE ALTI IGN 1m capture le micro-relief urbain (escaliers, bordures, mobilier) même là où le sol est plat. Résultat : des creux/bosses irréalistes en zone urbaine dense (ex: devant la Fnac place Victor Hugo, et autres zones sans changement réel de niveau).

## Solution envisagée : lissage conditionnel par gradient

Appliquer un Gaussian blur **uniquement sur les zones plates**, détectées par un seuil de gradient local.

### Étapes

1. Calculer la magnitude du gradient sur l'array elevation (post-reprojection UTM)
2. Générer un masque `is_flat` : `gradient_magnitude < seuil`
3. Appliquer un Gaussian blur fort sur l'array entier
4. Blender : `result = blur * mask + original * (1 - mask)`
   - Les bords du masque assurent une transition douce entre zones plates et pentues

### Paramètres à tuner

| Paramètre | Valeur de départ suggérée | Rôle |
|---|---|---|
| Seuil gradient | 0.5 – 1.0 m/px | Définit ce qui est "plat" |
| Sigma blur | 3.0 – 5.0 | Force du lissage sur zones plates |
| Transition mask | gaussien sur les bords | Éviter les artefacts de jonction |

### Emplacement dans le code

Nouvelle fonction `_smooth_flat_areas(elevation, sigma, gradient_threshold, water_mask)` dans `process_dem.py`, appelée à la place ou en complément de `_smooth_elevation`.

### ⚠️ Exclusion des rivières du masque plat

Les berges de rivière (Isère en plaine notamment) ont un faible gradient et seraient incluses dans le masque "plat" — ce qui lisserait les berges et atténuerait visuellement la dépression eau appliquée ensuite.

**Fix** : construire le water mask depuis `landuse.geojson` (déjà disponible, même logique que `_depress_water`) et l'exclure du masque plat avant d'appliquer le blur.

**Ordre des opérations à respecter dans `main()` :**
1. `_smooth_flat_areas` (avec exclusion water)
2. `_depress_water`

## Zones de test à vérifier

- Devant la Fnac, place Victor Hugo
- Autres zones piétonnes plates du centre-ville

## Notes

- Ne pas toucher au lissage DSM existant (`_smooth_elevation` avec sigma=6) — il ne s'applique que sur le fallback Copernicus, pas sur IGN
- Le seuil de gradient sera à ajuster selon le rendu in-game — prévoir un paramètre dans `config.py`

---

# Bâtiments — Ancrage au sol (flottement en zone montagneuse)

## Problème

Certains bâtiments en pente (notamment en montagne) flottent au-dessus du terrain. Cause : l'altitude est samplée au centroïde du bâtiment sur une heightmap 1024px (~10m/px), trop imprécise pour capturer le micro-relief local sous la footprint.

## Solution envisagée : sample multi-point sur footprint

Au lieu de sampler l'altitude au centroïde, sampler sur plusieurs points de la footprint OSM et prendre le **minimum** — le bâtiment se pose sur le point le plus bas, éliminant le flottement.

### Emplacement dans le code

`BuildingSpawner.gd` ou `BuildingMeshFactory.gd` — là où l'altitude est actuellement assignée au bâtiment.

## ⚠️ Dépendance

**À implémenter après le lissage adaptatif des zones plates.** Sans ça, en ville les bâtiments s'ancreraient sur un terrain troué et se retrouveraient enterrés.

---

# Routes — Aplatissement du terrain sous les routes

## Problème

En zone montagneuse, les routes ont une pente transversale (un côté plus haut que l'autre) car le terrain sous la route est lui-même incliné latéralement.

## Solution envisagée : aplatir le terrain sous les routes perpendiculairement au spline

Dans `process_dem.py`, après le lissage adaptatif et avant la dépression eau :

- Extraire les centerlines de route depuis `roads.geojson`
- Pour chaque point du spline, sampler l'altitude **au centre** de la route à ce point
- Écraser tous les pixels sur la largeur de la route perpendiculairement au spline avec cette altitude — pas de moyenne, pas d'interpolation latérale
- Buffer latéral = demi-largeur de route selon le tag `lanes` / `highway`

Le résultat : la route peut monter et descendre longitudinalement, mais elle est toujours **horizontale transversalement**.

## ⚠️ Dépendances

- À faire après `_smooth_flat_areas`
- À faire avant `_depress_water`
- Nécessite que `roads.geojson` soit disponible au moment du traitement DEM — vérifier l'ordre d'exécution du pipeline global
