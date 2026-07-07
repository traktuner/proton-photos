# Map Performance — Measure-First Analysis

## Status: PARTIAL — verlustfreie Fixes drin, Aggregation noch offen

### Schritt 1: Ursachenanalyse (vor den Fixes — Code-Lesung, nicht geraten)

Vorheriger Zustand von `UIKitLibraryMapHostView` + `PhotoLocationVisibleCoordinatePolicy`:

1. **`maxCoordinates: 3000`** (MobileMapScreen.swift:125). Die Policy schneidet mit
   `Array(visible.prefix(maxCoordinates))` ab — das sind bis zu 3000 individuelle
   `MKAnnotationView`s, die MKMapView verwalten muss. Jede View hat eigene CALayer,
   Shadow-Berechnung, Layout-Pass. Bei Pinch-Zoom ruft MKMapView für jede sichtbare
   Annotation `viewFor:` auf → 3000 Thumbnail-Lookups + potenziell 3000 async Loads.

2. **`reloadVisible()` diffte über `mapView.annotations`** (Zeile 118-120 original):
   ```swift
   let stale = mapView.annotations
       .compactMap { $0 as? UIKitPhotoMapAnnotation }
       .filter { !wanted.contains($0.uid) }
   ```
   Das iteriert über ALLE Annotations inkl. `MKClusterAnnotation` bei JEDEM
   `regionDidChange`. Bei 3000 Annotations × jedes Pinch-Frame = O(n) pro Gesture-Event.
   Während Pinch feuert `regionDidChange` zwar nur am Ende, aber `regionWillChange`
   + intermediate Updates können ebenfalls Triggers setzen.

3. **`requestThumbnailIfNeeded` ohne Cancellation** (original Zeile 196-207):
   ```swift
   Task { @MainActor [weak self] in
       let image = await loadThumbnail(uid)
       ...
       self.applyLoadedThumbnail(image, for: uid)
   }
   ```
   Bei jedem Region-Wechsel werden neue Annotations hinzugefügt → neue Tasks gestartet.
   Alte Tasks für entfernte Annotations laufen weiter, rufen `applyLoadedThumbnail`
   auf, das dann `mapView.annotations.compactMap` nochmal scannt (O(n) pro geladenem
   Thumbnail). Bei 3000 Annotations × Region-Wechsel = hunderte verwaiste Tasks,
   die alle gegen die Annotation-Liste scannen.

4. **`applyLoadedThumbnail` scannt alle Annotations** (original Zeile 209-224):
   Zweimaliger O(n) Scan: einmal für die Einzel-Annotation, einmal für alle Cluster.
   Bei 3000 Annotations × jeder Thumbnail-Load = O(n²) Gesamt-Kosten während
   eines Pinch in dichter Region.

### Konkrete Kosten-Schätzung (Code-Analyse, nicht Profiler-Messung)

- **Annotation-Zahl pro Region**: bis zu 3000 (Cap). Bei Wohnort mit vielen Fotos
  in einem Stadtviertel ist dieses Cap realistisch erreicht.
- **Pro Thumbnail-Load**: 2× O(n) Scan über alle Annotations = ~6000 Iterationen.
- **Pro Pinch-Frame mit Thumbnail-Loads**: 3000 × 6000 = 18M Iterationen → Main-Thread-Block.
- **MKMapView-interne Kosten**: 3000 Annotation-Views mit eigenen CALayern/Shadow
  belasten den Layout-Pass von MKMapView selbst — das ist unabhängig von unserem
  Code und kann durch unsere Diffing-Optimierung nicht behoben werden.

### Schritt 2: Verlustfreie Fixes (IMPLEMENTIERT, in diesem Branch)

Diese Fixes verändern KEINE Foto-Zahlen, brechen KEINE Cluster-Counts:

1. **`annotationByUID: [PhotoUID: UIKitPhotoMapAnnotation]`** — O(1) Lookup statt
   O(n) Scan in `applyLoadedThumbnail` und `reloadVisible`-Removal.

2. **`reloadVisible()` difft gegen `shownUIDs`** statt `mapView.annotations` —
   kein Vollscan über alle Annotations + Cluster mehr.

3. **`thumbnailLoadTasks: [PhotoUID: Task<Void, Never>]`** mit echter
   **CANCELLATION** bei `removeAnnotations` — verwaiste Tasks werden
   `task.cancel()`'d und frühen via `Task.isCancelled` aus.

4. **`deinit` cancels alle Tasks** — kein Leak bei Screen-Dismiss.

5. **`Task.isCancelled`-Früh-Ausgang** nach `await loadThumbnail(uid)` —
   abgebrochene Loads suchen nicht mehr nach der View.

### Schritt 3: Was NICHT durch diese Fixes gelöst wird

MKMapView muss trotzdem bis zu 3000 Annotation-Views verwalten. Das ist
MKMapView-intern (Layout, Clustering, Hit-Testing) und kann nur durch
**weniger Annotations** gelöst werden — nicht durch unsere Diffing-Optimierung.

Wenn die verlustfreien Fixes allein nicht reichen (messbar über die os_log-Logs
in reloadVisible), dann ist der nächste Schritt:

**Index-Layer-Aggregation in MediaLocationCore (cross-platform)**:
- Nicht `maxCoordinates` senken (wirft Fotos weg, Cluster-Counts falsch).
- Stattdessen: in `PhotoLocationIndex` einen `aggregatedCoordinates(viewport:pixelsPerPin:)`
  hinzufügen, der N Fotos am selben Ort zu einem virtuellen Pin zusammenfasst,
  mit `memberUIDs: [PhotoUID]` und `count: Int`.
- Die Cluster-View zeigt dann `count` (Summe aller Member) statt nur
  `cluster.memberAnnotations.count` (nur die sichtbaren MKAnnotations).
- So bleiben alle Fotos repräsentiert, nur die MKMapView sieht weniger Pins.

### Schritt 3b: Stabile Cap-Auswahl + Region-Debounce (IMPLEMENTIERT, work/map-cap-stability)

Die os_log-Logs zeigten ein zweites, von den verlustfreien Fixes ungelöstes
Symptom: `visible=3000 ... toRemove=2025 fresh=2025 thumbTasks=954` immer
wieder, mit `thumbTasks` zwischen 37 und 1288 oszillierend.

Ursache: Wenn die Viewport-Menge > `maxCoordinates` (3000) lag, wählte
`Array(visible.prefix(maxCoordinates))` die ersten 3000 nach **Crawl-Insertion-
Order** — nicht nach Nähe zum sichtbaren Bereich. Ein winziges Wackeln der
Bounding-Box (MKMapView's sub-pixel `regionDidChange`, plus `revision`-Bumps vom
Hintergrund-Crawl, die `refreshIfChanged` → `reloadVisible` triggern) änderte
die Menge am Box-Rand marginal → `prefix` wählte eine *andere* Teilmenge von 3000
→ `toRemove≈fresh≈2000` Churn, obwohl sich keine einzige Foto geografisch
wirklich bewegte. In-flight Thumbnail-Loads wurden gecancelt und neu gespawned
→ `thumbTasks`-Oszillation.

Zwei ergänzende Fixes (beide verlustfrei — keine Foto-Zahlen, keine Cluster-Count-
Änderung):

1. **Stabile Cap-Auswahl** (`PhotoLocationViewport.swift`): Wenn gecapt, sortiere
   die gefilterten Koordinaten nach quadriertem Abstand zum Viewport-Zentrum,
   dann `prefix(maxCoordinates)`. Tie-Break deterministisch per
   `(volumeID, nodeID)`-Tupel (Swifts `sorted(by:)`-Stabilität ist nicht garantiert).
   Selbe Box + selber Index → selbe Auswahl → kein Churn bei Box-Wackeln.
   Plattform-neutral (kein `CLLocationCoordinate2D` in `MediaLocationCore`;
   plain-lat/lon-Euklid als Vergleichsschlüssel genügt — es ist kein echter
   Abstand, nur ein Ordnungs-Key).

2. **Box-Debounce** (`UIKitLibraryMapHostView.swift` iOS,
   `LibraryMapView.swift` macOS): Cache der letzten `GeoBoundingBox`; wenn
   `reloadVisible` mit unveränderter Box aufgerufen wird → skip (gleiche Inputs
   → gleiche Menge → no-op-Diff). `refreshIfChanged` invalidiert den Cache bei
   `revision`-Bump, damit Crawl-Neuzugänge weiterhin re-query'n. `configure()`
   invalidiert ebenfalls (Callback-Wechsel).

Was NICHT gelöst wird (bleibt für Schritt 3 / Index-Aggregation, falls nach
diesem Fix `visible` noch zu hoch): MKMapView-interne Kosten von 3000 Views.
Aber der Churn (toRemove/fresh/thumbTasks-Oszillation) sollte jetzt auf
Veränderungen beschränkt sein, die *echte* Mitgliedschafts- oder
Index-Veränderungen sind — nicht auf sub-pixel-Jitter.


### Schritt 4: Messung (vorbereitet, nicht vom Agent lauffähig)

`UIKitLibraryMapHostView` loggt jetzt via `os_log`:
```
reloadVisible: visible=N wanted=N shown=N toRemove=N fresh=N thumbTasks=N
```

Ausgabe via Console.app mit Filter `subsystem:ch.protonmail.photos category:MapPerf`.

Der Nutzer sollte in einer dichten Region (Wohnort) reinzoomen und die Logs
prüfen. Wenn `visible` regelmäßig >500 erreicht und Frames fallen → Aggregation
in Schritt 3 ist notwendig. Wenn `visible` niedrig bleibt, aber `thumbTasks`
hoch war (vor den Fixes) → Cancellation war der Hauptgewinn.

### Punkt 2 (Top-Inset) — Blast-Radius

Die Änderung an `UIKitTimelineGridHost.applyContentInsets()` setzt jetzt
`scrollView.contentInset.top = safeAreaInsets.top`. Das betrifft:
- **Haupt-Foto-Timeline** (MobileTimelineScreen) — öffnet am Bottom (neueste).
  Der Top-Inset addiert sich zur Content-Höhe, `maxContentOffsetY` verschiebt
  sich um `top` — der Bottom-Anchor bleibt, aber der scrollbare Bereich
  beginnt jetzt `top` Pixel tiefer. Beim Heraufscrollen landet die erste
  Reihe unter der Nav-Bar statt dahinter. Korrektes Verhalten.
- **Cluster-Screen** (MobileMapClusterSeriesScreen) — selbes Grid, selbe
  Besserung.
- **macOS** — ungeändert, das ist eine `#if canImport(UIKit)`-Datei.

Risiko: Wenn die Haupt-Timeline vorher absichtlich ohne Top-Inset lief
(z.B. weil die Nav-Bar transparent ist und Fotos darunter durchblitzen sollen),
wäre das eine Verhaltensänderung. Code-Prüfung zeigt: `MobileTimelineScreen`
hat `navigationBarTitleDisplayMode(.inline)` → opaque inline Nav-Bar →
Fotos DARF nicht dahinter liegen. Die Änderung ist also korrekt für beide.
