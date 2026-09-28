import AVFoundation
import Foundation

struct EQPreset: Identifiable, Sendable {
    let name: String
    let gains: [Float]
    var id: String { name }
}

@MainActor
final class EqualizerStore: ObservableObject {
    static let frequencies: [Float] = [25,40,63,100,160,250,400,630,1000,1600,2500,4000,6300,10000,16000]
    static let presets: [EQPreset] = [
        .init(name:"Default", gains:Array(repeating:0,count:15)),
        .init(name:"Studio Master", gains:[2.6,2.8,2.2,0.6,-1.8,-2.6,-1.2,0,1.2,2.4,3.6,4,4.2,4.5,4.8]),
        .init(name:"Acoustic", gains:[3,2.5,2,1.5,0.5,1,1.5,2,2,1.5,1,1,1,1.5,1.5]),
        .init(name:"Vocal Clarity", gains:[-1.5,-1,-0.5,0,0.5,1,2,3,3.5,3,2.5,2,1.5,1.5,1]),
        .init(name:"Classical", gains:[3,2.5,2,1.5,0.5,0,0,0,0.5,1,1.5,2,2.5,3,3]),
        .init(name:"Jazz", gains:[2.5,2,1.5,1,0,-0.5,0,0.5,1,1.5,2,2,2.5,2.5,2.5]),
        .init(name:"Rock", gains:[4,3.5,3,1.5,0,-1,-1,-0.5,0.5,1.5,2.5,3,3.5,4,4]),
        .init(name:"Pop", gains:[-1,-0.5,0,1,1.5,2,2,1.5,1,0.5,0.5,1,1.5,2,2.5]),
        .init(name:"Treble Air", gains:[0,0,0,-0.5,-0.5,-0.5,0,0.5,1,1.5,2,3,3.5,4.5,5]),
        .init(name:"Deep Bass Clean", gains:[5,4.5,3.5,2.5,1,0,-0.5,-0.5,0,0,0,0,0.5,0.5,0.5]),
        .init(name:"Electronic", gains:[4.5,4,3,2,0.5,-0.5,0,1,2,2.5,2.5,2.5,3,3.5,4]),
        .init(name:"R&B", gains:[5,4.5,3.5,2,1,-0.5,-1,-0.5,0.5,1.5,2,2.5,3,3,3])
    ]
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey:"eq.enabled") } }
    @Published var presetName: String { didSet { defaults.set(presetName, forKey:"eq.preset") } }
    @Published var gains: [Float] { didSet { defaults.set(gains, forKey:"eq.gains") } }
    private let defaults = UserDefaults.standard

    init() {
        enabled = defaults.bool(forKey:"eq.enabled")
        presetName = defaults.string(forKey:"eq.preset") ?? "Default"
        gains = (defaults.array(forKey:"eq.gains") as? [NSNumber])?.map(\.floatValue) ?? Self.presets[0].gains
        if gains.count != 15 { gains = Self.presets[0].gains }
    }
    func apply(_ preset: EQPreset) { presetName = preset.name; gains = preset.gains; enabled = true }
    func set(_ value: Float, at index: Int) { guard gains.indices.contains(index) else { return }; gains[index] = min(8,max(-8,value)); presetName = "Custom" }
}
