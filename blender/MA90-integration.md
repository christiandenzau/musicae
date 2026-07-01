# MA90 — 3D-Verstärker-Panel · Integrations-Notiz für Musicae

Diese Notiz gehört zur Datei `MA90.usdz`. Beide zusammen an den App-Chat geben.

## Was ist das
Ein **abgewandeltes** 90er-HiFi-Verstärker-Panel (eigenes Design „MUSICAE MA-90",
kein Marken-Logo → copyright-sicher), gebaut in Blender, exportiert als **USDZ**.
Das ist die **einfache Blockout-Version**: Struktur/Proportionen/Hierarchie stehen,
Feindetails (VU-Skalen, gebürstetes Alu, farbige Balken-Zonen, Beschriftung) folgen
in einer späteren Blender-Runde. Ein Re-Export ersetzt die USDZ einfach — **die
Objekt-Namen bleiben stabil**, der Swift-Code muss dafür nicht angefasst werden.

## Dateien
- `MA90.usdz` — das Modell → in die App einbinden
- `MA90.blend` — Blender-Quelle → bleibt beim Blender-Chat, **nicht** in die App

## Ansteuerbare Teile (Namen bleiben bei jedem Re-Export gleich)
| Entity-Name | Anzahl | Bewegung zur Laufzeit | Datenquelle | Pivot |
|---|---|---|---|---|
| `VU_Needle_L`, `VU_Needle_R` | 2 | **Rotation** (schwenken) | Pegel L/R | am Drehpunkt (unten) |
| `Spectrum_Bar_00` … `Spectrum_Bar_11` | 12 | **Skalierung** (Höhe) | FFT-Frequenzbänder | an der Unterkante |
| `Volume`, `Bass`, `Treble`, `Balance` | 4 | **Rotation** (Achse) | Nutzer / State | Mitte |
| `Btn_Phono/CD/Tuner/Aux/Tape` | 5 | Material/Highlight | aktive Quelle | — |
| `LED_CD`, `Power_LED` | 2 | **Emission** an/aus | Status | — |

Alles hängt unter einem Root-Xform `MA90_Root`. Zugriff per Namen ist rekursiv möglich.
Die Pivots sind bewusst gesetzt: Balken **wachsen nach oben** (scale-y bzw. -z), Nadeln
**schwenken um ihren Drehpunkt** statt um die Mitte.

## ⚠️ macOS-Target beachten — Framework-Entscheidung
Projekt-Target ist aktuell **macOS 14.0**. Das ist relevant:
- **`RealityView`** (die moderne SwiftUI-3D-View) braucht **macOS 15+** → mit Target 14 **nicht** verfügbar.
- Optionen:
  1. **Target auf macOS 15 anheben** → `RealityView` nutzen (sauberste RealityKit-API).
  2. **Bei 14 bleiben** → `ARView` (RealityKit) via `NSViewRepresentable` einbetten.
  3. **SceneKit** (`SCNView`) — auf dem Mac am ausgereiftesten, lädt **dasselbe USDZ**, sehr einfach per Code zu animieren. Pragmatischer Plan B, falls RealityKit auf macOS zickt.

**Wichtig:** Das USDZ funktioniert bei **allen drei** Wegen identisch — die Blender-Arbeit
ist also nicht an eine Entscheidung gebunden. Der App-Chat wählt anhand des Setups.

## Einbinden in Xcode
`MA90.usdz` ins Projekt ziehen → Target-Membership der App-Zielscheibe anhaken.

## Laden + Ansteuern — RealityKit (macOS 15, RealityView)
```swift
import SwiftUI
import RealityKit

struct AmplifierPanel: View {
    @State private var amp: Entity?
    var body: some View {
        RealityView { content in
            if let e = try? await Entity(named: "MA90", in: .main) {
                content.add(e); amp = e
            }
        }
    }
}

// pro Frame aus der Audio-Engine:
amp?.findEntity(named: "VU_Needle_L")?
   .setOrientation(simd_quatf(angle: angleRad, axis: [0, 1, 0]), relativeTo: nil) // Achse im Test bestimmen
amp?.findEntity(named: "Spectrum_Bar_03")?
   .scale = SIMD3<Float>(1, level, 1)                                             // Achse im Test bestimmen
```

## Laden + Ansteuern — SceneKit (macOS 14+, universell)
```swift
import SwiftUI
import SceneKit

struct AmplifierPanel: NSViewRepresentable {
    func makeNSView(context: Context) -> SCNView {
        let v = SCNView()
        if let url = Bundle.main.url(forResource: "MA90", withExtension: "usdz") {
            v.scene = try? SCNScene(url: url)
        }
        v.autoenablesDefaultLighting = true
        v.backgroundColor = .clear
        v.allowsCameraControl = true   // nur zum Testen
        return v
    }
    func updateNSView(_ v: SCNView, context: Context) {}
}

// Ansteuern:
let bar = scnView.scene?.rootNode.childNode(withName: "Spectrum_Bar_03", recursively: true)
bar?.scale.y = level                          // Achse ggf. .z, je nach Import
let needle = scnView.scene?.rootNode.childNode(withName: "VU_Needle_L", recursively: true)
needle?.eulerAngles.y = angleRad              // Achse im Test bestimmen
```

## Achsen / Orientierung — erste Testaufgabe
Der Export hat `upAxis = "Z"` (Blender-Konvention). RealityKit/SceneKit erwarten Y-up.
**Erst laden und schauen:**
- Steht das Panel aufrecht? Falls es „liegt": Root um -90° um X drehen
  (`amp?.transform.rotation = simd_quatf(angle: -.pi/2, axis: [1,0,0])`).
- Dann **eine** Nadel schwenken + **einen** Balken skalieren und die *richtige* Achse
  (y vs. z) empirisch bestimmen. Danach gilt sie für alle gleichartigen Teile.

## Durchstich-Ziel (erst das, dann Schönheit)
Minimales Erfolgskriterium: **Modell lädt → steht aufrecht → eine VU-Nadel schwenkt per
Code → ein Spectrum-Balken ändert die Höhe.** Sobald das läuft, ist die komplette
Pipeline (Blender → USDZ → App → Live-Animation) bewiesen. Dann zurück in den
Blender-Chat für Details + Re-Export.
