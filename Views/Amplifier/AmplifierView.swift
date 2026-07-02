//
//  AmplifierView.swift
//  Musicae
//
//  3D "MA-90" amplifier panel rendered with RealityView (macOS 15+). Meters are
//  driven live from `AudioVisualizationProvider`; the volume knob, LEDs, the
//  clickable source buttons and the transport overlay are wired to the real
//  playback managers.
//
//  Rotation axes: after the Z-up → Y-up upright fix the *local* axes of the
//  imported parts are ambiguous, so the knob and needles are spun around the
//  WORLD Z axis (toward the viewer) via `setOrientation(_:relativeTo: nil)`.
//  For a front-facing dial/needle that is always the correct swing axis,
//  independent of how the mesh was authored. Bars still scale along their local
//  grow axis (that already looked right on the first run).
//

import AppKit
import QuartzCore
import RealityKit
import SwiftUI

fileprivate typealias RKEntity = RealityKit.Entity

// MARK: - Entity rig

/// Caches the addressable entities of the loaded model (remembering base
/// transforms / materials) and applies the live visualization + interaction
/// state to them. Kept separate from the View so the SwiftUI side stays declarative.
@MainActor
final class AmplifierRig {
    // Meters
    private var bars: [(entity: RKEntity, baseScale: SIMD3<Float>)] = []
    private var needleL: (entity: RKEntity, baseWorld: simd_quatf)?
    private var needleR: (entity: RKEntity, baseWorld: simd_quatf)?
    private var volumeKnob: (entity: RKEntity, baseWorld: simd_quatf)?

    // Smoothed current values, interpolated toward the provider's targets each frame.
    private var curBars = [Float](repeating: 0, count: 12)
    private var curLevelL: Float = 0
    private var curLevelR: Float = 0

    #if DEBUG
    private var frameCount = 0
    private var lastFPSTime: Double = 0
    #endif

    // LEDs
    private var powerLED: RKEntity?
    private var cdLED: RKEntity?
    private var lastPlaying: Bool?

    // Clickable buttons
    private let buttonNames = ["Power_Button", "Btn_Phono", "Btn_CD", "Btn_Tuner", "Btn_Aux", "Btn_Tape"]
    private var buttons: [String: RKEntity] = [:]
    private var originalMaterials: [String: [any RealityKit.Material]] = [:]
    private var activeSource: String?

    // TUNE: motion ranges.
    private let barGrowAxis = SIMD3<Float>(0, 1, 0)   // bars grow along local Y (looked right on run 1)
    private let barMaxGrow: Float = 2.5
    private let worldSwingAxis = SIMD3<Float>(0, 0, 1) // world Z = toward the viewer
    private let needleSwing: Float = -.pi / 3         // level 0 = rest (built pose); sign sets swing direction
    private let knobTravel: Float = -.pi * 1.5        // ~270° across 0…1; negative so louder = clockwise
    // Per-frame ballistics (~60fps): fast attack, slow decay for an analog feel.
    private let attack: Float = 0.45
    private let decay: Float = 0.08

    var isBound: Bool { !bars.isEmpty || needleL != nil }

    fileprivate func bind(to root: RKEntity) {
        bars = (0..<12).compactMap { index in
            root.findEntity(named: String(format: "Spectrum_Bar_%02d", index)).map { ($0, $0.scale) }
        }
        needleL = root.findEntity(named: "VU_Needle_L").map { ($0, $0.orientation(relativeTo: nil)) }
        needleR = root.findEntity(named: "VU_Needle_R").map { ($0, $0.orientation(relativeTo: nil)) }
        volumeKnob = root.findEntity(named: "Volume").map { ($0, $0.orientation(relativeTo: nil)) }

        powerLED = root.findEntity(named: "Power_LED")
        cdLED = root.findEntity(named: "LED_CD")
        setGlow(powerLED, color: .systemGreen, on: true)   // power stays lit
        setGlow(cdLED, color: .systemRed, on: false)

        for name in buttonNames {
            guard let button = root.findEntity(named: name) else { continue }
            buttons[name] = button
            if let model = firstModelEntity(button), let component = model.components[ModelComponent.self] {
                originalMaterials[name] = component.materials
            }
            let bounds = button.visualBounds(relativeTo: button)
            let shape = ShapeResource.generateBox(size: bounds.extents).offsetBy(translation: bounds.center)
            button.components.set(CollisionComponent(shapes: [shape]))
            button.components.set(InputTargetComponent())
        }
    }

    /// Called every render frame. Interpolates cached values toward the provider's
    /// raw targets (ballistics) and writes the transforms — decoupled from the audio
    /// tap rate, so motion stays smooth regardless of update cadence.
    func apply(spectrum: [Float], levelL: Float, levelR: Float, volume: Float, isPlaying: Bool) {
        // When stopped, targets fall to rest — guards against a stale value when
        // the tap stops delivering buffers (otherwise the meters freeze mid-air).
        let barTargets = isPlaying ? spectrum : []
        let lTarget = isPlaying ? levelL : 0
        let rTarget = isPlaying ? levelR : 0
        for i in curBars.indices {
            let t = i < barTargets.count ? barTargets[i] : 0
            curBars[i] += (t - curBars[i]) * (t > curBars[i] ? attack : decay)
        }
        curLevelL += (lTarget - curLevelL) * (lTarget > curLevelL ? attack : decay)
        curLevelR += (rTarget - curLevelR) * (rTarget > curLevelR ? attack : decay)

        for (index, item) in bars.enumerated() where index < curBars.count {
            let grow = curBars[index] * barMaxGrow
            item.entity.scale = item.baseScale * (SIMD3<Float>(repeating: 1) + barGrowAxis * grow)
        }
        if let needleL {
            needleL.entity.setOrientation(spin(curLevelL * needleSwing) * needleL.baseWorld, relativeTo: nil)
        }
        if let needleR {
            needleR.entity.setOrientation(spin(curLevelR * needleSwing) * needleR.baseWorld, relativeTo: nil)
        }
        if let volumeKnob {
            let angle = (volume - 0.5) * knobTravel
            volumeKnob.entity.setOrientation(spin(angle) * volumeKnob.baseWorld, relativeTo: nil)
        }
        if lastPlaying != isPlaying {
            lastPlaying = isPlaying
            setGlow(cdLED, color: .systemRed, on: isPlaying)
        }
        #if DEBUG
        frameCount += 1
        let now = CACurrentMediaTime()
        if lastFPSTime == 0 {
            lastFPSTime = now
        } else if now - lastFPSTime >= 1 {
            Logger.info("[Amp] fps=\(frameCount) specMax=\(String(format: "%.2f", curBars.max() ?? 0)) L=\(String(format: "%.2f", curLevelL)) R=\(String(format: "%.2f", curLevelR))")
            frameCount = 0
            lastFPSTime = now
        }
        #endif
    }

    // MARK: - Interaction

    /// Walks up from a tapped entity to the nearest named, addressable button.
    fileprivate func buttonName(for tapped: RKEntity) -> String? {
        var current: RKEntity? = tapped
        while let entity = current {
            if buttonNames.contains(entity.name) { return entity.name }
            current = entity.parent
        }
        return nil
    }

    /// Highlights the chosen source button and restores the others.
    func selectSource(_ name: String) {
        activeSource = name
        for (key, button) in buttons where key.hasPrefix("Btn_") {
            if key == name {
                setGlow(button, color: .systemOrange, on: true)
            } else {
                restore(button, name: key)
            }
        }
    }

    // MARK: - Helpers

    private func spin(_ angle: Float) -> simd_quatf {
        simd_quatf(angle: angle, axis: worldSwingAxis)
    }

    private func firstModelEntity(_ entity: RKEntity) -> RKEntity? {
        if entity.components.has(ModelComponent.self) { return entity }
        for child in entity.children {
            if let found = firstModelEntity(child) { return found }
        }
        return nil
    }

    private func setGlow(_ entity: RKEntity?, color: NSColor, on: Bool) {
        guard let target = entity.flatMap(firstModelEntity),
              var component = target.components[ModelComponent.self] else { return }
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: on ? color : NSColor(white: 0.08, alpha: 1))
        material.emissiveColor = .init(color: on ? color : .black)
        material.emissiveIntensity = on ? 2.0 : 0.0
        material.roughness = 0.4
        component.materials = Array(repeating: material, count: max(component.materials.count, 1))
        target.components.set(component)
    }

    private func restore(_ button: RKEntity, name: String) {
        guard let target = firstModelEntity(button),
              var component = target.components[ModelComponent.self],
              let originals = originalMaterials[name] else { return }
        component.materials = originals
        target.components.set(component)
    }
}

// MARK: - View

struct AmplifierView: View {
    @EnvironmentObject private var playbackManager: PlaybackManager
    @EnvironmentObject private var playlistManager: PlaylistManager

    @State private var rig = AmplifierRig()
    @State private var loadFailed = false
    @State private var frameSub: EventSubscription?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            RealityView { content in
                guard let amp = try? await RealityKit.Entity(named: "MA90", in: .main) else {
                    loadFailed = true
                    return
                }

                // Upright: the model exports Z-up, RealityKit is Y-up.
                amp.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])

                // Normalize to a predictable size, then recenter on the origin.
                let local = amp.visualBounds(relativeTo: amp)
                let maxDim = max(local.extents.x, local.extents.y, local.extents.z)
                if maxDim > 0 { amp.scale = SIMD3<Float>(repeating: 0.5 / maxDim) }
                let world = amp.visualBounds(relativeTo: nil)
                amp.position -= world.center

                content.add(amp)
                rig.bind(to: amp)

                let camera = PerspectiveCamera()
                camera.camera.fieldOfViewInDegrees = 40
                camera.look(at: .zero, from: [0, 0.05, 1.1], upVector: [0, 1, 0], relativeTo: nil)
                content.add(camera)

                let light = DirectionalLight()
                light.light.intensity = 3000
                light.look(at: .zero, from: [0.4, 0.6, 1.0], upVector: [0, 1, 0], relativeTo: nil)
                content.add(light)

                // Drive the animation from a real 60fps render loop, decoupled from
                // SwiftUI. Reading provider state here (instead of via @ObservedObject)
                // avoids a full view re-render on every audio update.
                let provider = AudioVisualizationProvider.shared
                let manager = playbackManager
                frameSub = content.subscribe(to: SceneEvents.Update.self) { _ in
                    MainActor.assumeIsolated {
                        rig.apply(
                            spectrum: provider.spectrum,
                            levelL: provider.levelL,
                            levelR: provider.levelR,
                            volume: manager.volume,
                            isPlaying: manager.isPlaying
                        )
                    }
                }
            } update: { _ in
            }
            .gesture(
                SpatialTapGesture()
                    .targetedToAnyEntity()
                    .onEnded { value in handleTap(value.entity) }
            )

            if loadFailed {
                Text("MA90.usdz konnte nicht geladen werden")
                    .foregroundStyle(.white)
            }

            transportControls
        }
        .frame(minWidth: 480, minHeight: 360)
        .onAppear { playbackManager.startVisualization() }
        .onDisappear { playbackManager.stopVisualization() }
    }

    private func handleTap(_ entity: RKEntity) {
        guard let name = rig.buttonName(for: entity) else { return }
        switch name {
        case "Power_Button":
            playbackManager.togglePlayPause()
        default:
            // Source buttons: highlight the selection (visual only — the app has
            // no HiFi "sources", so this proves the click path without faking one).
            rig.selectSource(name)
        }
    }

    private var transportControls: some View {
        HStack(spacing: 18) {
            Button { playlistManager.playPreviousTrack() } label: {
                Image(systemName: "backward.fill")
            }
            Button { playbackManager.togglePlayPause() } label: {
                Image(systemName: playbackManager.isPlaying ? "pause.fill" : "play.fill")
            }
            Button { playlistManager.playNextTrack() } label: {
                Image(systemName: "forward.fill")
            }
            Slider(
                value: Binding(
                    get: { Double(playbackManager.volume) },
                    set: { playbackManager.setVolume(Float($0)) }
                ),
                in: 0...1
            )
            .frame(width: 140)
        }
        .font(.title3)
        .buttonStyle(.plain)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.bottom, 18)
    }
}
