# Open World Grenoble — OSM + Godot

## Faisabilité

Grenoble est un cas idéal : cuvette plate + montagnes bien définies (Vercors, Chartreuse, Belledonne) bien rendues à 30m de résolution DEM.

---

## Données disponibles

| Source | Contenu |
|---|---|
| OpenStreetMap | Bâtiments, routes, landuse, végétation, eau |
| Copernicus DEM / SRTM | Relief (30m résolution) → heightmap |
| Tags OSM | `building:material`, `building:levels`, `landuse`, `natural`, `surface` |

**Ce qui manque dans OSM :**
- Textures réelles des façades → générer procéduralement
- Hauteur précise des bâtiments (souvent absent)

---

## Pipeline

```
1. DEM Copernicus (30m) → heightmap PNG → terrain mesh Godot
2. Overpass API → GeoJSON bâtiments / routes / landuse
3. Génération procédurale des meshes bâtiments
4. Mapping tags OSM → textures
5. Streaming par tuiles (~500m)
```

### Mapping tags → textures
| Tag OSM | Texture |
|---|---|
| `building:material=brick` | Brique |
| `landuse=grass` | Herbe |
| `natural=water` | Shader eau |
| `natural=wood` | Forêt |
| `building=industrial` | Béton |

---

## Portes & Fenêtres

OSM ne contient quasiment aucune donnée façade. Trois approches :

### A — Procédural (recommandé phase 1+2)
Génération algorithmique selon la taille de la façade et les tags OSM.

```gdscript
func generate_facade(width, height, floors):
    var windows_per_floor = floor(width / 3.0)  # 1 fenêtre / 3m
    for floor in floors:
        for w in windows_per_floor:
            place_window(x, y)
    place_door(center_x, ground_y)
```

Tags utiles pour varier le style :
- `building:levels` → densité fenêtres
- `building=residential` vs `commercial` vs `industrial`
- `shop=*` → grandes vitrines RDC

### B — Texture atlas baked (recommandé phase 1)
Textures de façade avec fenêtres dessinées, répétées en UV selon hauteur.
- Très performant
- Acceptable de loin — c'est ce que font GTA, Cities Skylines pour les bâtiments secondaires

### C — Modèles manuels
Pour les landmarks (Bastille, gare...) via modélisation manuelle ou photogrammétrie (Meshroom/RealityCapture).

---

## Performance — Points critiques

- **Ne pas instancier 50k fenêtres individuellement** → mort certaine
- Utiliser **MultiMesh** pour les éléments répétitifs (fenêtres, arbres...)
- **LOD** : texture baked au loin, procédural près du joueur
- Streaming par chunks : charger/décharger selon position joueur

---

## Roadmap réaliste

| Phase | Contenu | Durée estimée |
|---|---|---|
| 1 | Terrain heightmap + bâtiments gris + walking simulator | 2–4 semaines |
| 2 | Textures selon tags OSM + streaming fonctionnel | +1–2 mois |
| 3 | Procédural façades + MultiMesh + LOD | +1–2 mois |
| 4 | Landmarks manuels + polish | +selon dispo |
