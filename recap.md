# Grenoble Openworld — Résumé de session

## Phases de développement

Les phases sont ordonnées par priorité visuelle — ce qui a le plus d'impact immédiat en premier.

| Phase | Contenu | Statut |
|---|---|---|
| 1 | LOD — infrastructure commune | À faire |
| 2 | Terrain IGN + Façades atlas | À faire |
| 3 | Routes, trottoirs & marquages | À faire |
| 4 | Ponts & Eau | À faire |
| 5 | Végétation enrichie & Mobilier urbain | À faire |
| 6 | Ciel & Atmosphère | À faire |
| 7 | Cycle jour/nuit | Plus tard |

---

## Phase 1 — LOD

Tous les systèmes suivants doivent être conçus avec le LOD en tête dès le départ.

- Niveaux de détail par distance : mesh haute densité (proche) → mesh simplifié → imposteur / billboard (loin)
- `ChunkManager.gd` comme base du streaming — chaque système (bâtiments, routes, arbres, mobilier) s'y branche
- Bâtiments : mesh détaillé proche, boîte texturée au loin
- Arbres : mesh 3D proche, billboard au loin (déjà MultiMesh, compatible)
- Mobilier urbain : visible uniquement en dessous d'une distance seuil
- Routes : marquages et profil détaillé proche, ribbon simplifié au loin

---

## Phase 2 — Terrain & Façades

### Terrain — Remplacement du DEM
**Problème** : Copernicus GLO-30 est un DSM — les toits et bâtiments proches créent des creux sur les routes.

**Solution** : Remplacer par l'IGN RGE ALTI® 1m — vrai DTM (sol pur, bâtiments exclus), gratuit, couvre toute la France, compatible rasterio.

**Post-processing additionnel** : déprimer les pixels sous les polygones `natural=water` OSM de ~2-3m dans `process_dem.py`.

### Façades des bâtiments
**Approche** : Texture atlas CC0 (Poly Haven, ambientCG) — ~20-30 variations (haussmannien, béton 70s, moderne, industriel), UV-mappé selon les tags OSM.

**Mapping tags OSM → atlas**
- `building=residential/commercial/industrial` → famille de texture
- `building:material=brick/concrete/glass` → matériau
- `building:levels` → répétition verticale
- `building:colour` → tint shader par-dessus

**Landmarks** : photogrammétrie ou modèles manuels pour 5-10 bâtiments reconnaissables (Bastille, gare, Palais de Justice…).

---

## Phase 3 — Routes & Trottoirs

**Objectif** : Routes et trottoirs réalistes au niveau du sol. Les détails lointains seront gérés par le LOD.

### Routes
- Shader PBR avec texture asphalte tuilée (normal map + roughness)
- Profil transversal extrudé le long du spline (chaussée bombée + bordures en L) — remplace les ribbon meshes plats
- Marquages au sol aux **normes françaises IISR** dérivés des tags OSM :
  - Lignes longitudinales (tirets 3m/10m, continues selon contexte)
  - Passages piétons (bandes blanches 50cm, espacées 50cm, largeur min 2.5m)
  - Stop (ligne continue + marquage sol) / Cédez-le-passage (sharks teeth)
  - Tout en blanc sauf zones jaunes (livraison, stationnement)

### Trottoirs
- Mesh séparé surélevé +15cm, texture béton/dalle
- Géométrie inférée depuis `sidewalk=left/right/both` via offset polygon

### Chantiers pipeline & code
- `extract_roads.py` — extraire `sidewalk`, `lanes`, `oneway`, `highway=crossing`
- `RoadMeshSpawner.gd` — profil transversal extrudé
- Nouveau shader route PBR
- Nouveau spawner trottoir

---

## Phase 4 — Ponts & Eau

### Ponts
- Tags OSM `bridge=yes` + `layer` pour les niveaux
- `RoadMeshSpawner` : ignorer le sample terrain sur les segments bridge, interpoler une hauteur fixe entre les deux berges
- Mesh : tablier extrudé + garde-corps — piles dans l'eau en bonus

### Eau
- Shader eau : normal map animée, réflexion environnement, légère transparence teinte bleue-verte
- Lit des rivières géré en Phase 1 (dépression DEM sous polygones `natural=water`)

---

## Phase 5 — Végétation & Mobilier urbain

### Végétation — Enrichissement des arbres
**Tags OSM à extraire** (en plus de `species` et `height` déjà présents) :
- `species:fr`, `genus` → choix du mesh (conifère, feuillu, platane…)
- `circumference` → rayon du tronc, proxy pour l'âge
- `diameter_crown` → scale horizontal de la canopée
- `start_date` → silhouette jeune (chétif) vs vieux (massif)

**Utilisation dans Godot**
- `height` + `circumference` → scale global du mesh
- `species` / `genus` → sélection du bon modèle
- `start_date` → variation de silhouette selon l'âge
- `diameter_crown` → scale horizontal indépendant de la hauteur

### Mobilier urbain
**Approche** : MultiMesh depuis positions OSM + scatter procédural pour combler les lacunes.

- Lampadaires (`highway=street_lamp`) → scatter procédural le long des routes si pas de nœud OSM
- Poubelles (`amenity=waste_basket`)
- Bancs (`amenity=bench`)
- Arrêts de bus (`highway=bus_stop`)
- Panneaux de signalisation (`traffic_sign`, `highway=stop|give_way`) → rotation alignée sur l'axe de la route
- Vélos Métrovélo (bien couvert dans OSM)

**Numéros de rue** : secondaire, traité plus tard.

---

## Phase 6 — Ciel & Atmosphère

- Skybox HDR via `PanoramaSkyMaterial` — assets CC0 Poly Haven (vrais nuages, brouillard lointain)
- Pas de nuages volumétriques (trop lourd)
- Compatible avec le cycle jour/nuit prévu en Phase 6 (plusieurs HDRIs selon l'heure + `DirectionalLight3D`)

---

## Phase 7 — Cycle jour/nuit *(plus tard)*

- Animer la direction du `DirectionalLight3D`
- Switcher les HDRIs selon l'heure