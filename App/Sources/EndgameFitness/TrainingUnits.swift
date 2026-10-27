//
//  TrainingUnits.swift
//  Endgame Fitness
//
//  Copyright (c) 2026 Daniel Bates / Bates LLC. All rights reserved.
//  https://batesai.org · help@batesai.org
//
//  One unit setting for the whole app. Weights are stored and synced in pounds
//  (Docs/API_V2.md); this file converts at the edges for display and entry,
//  and holds the plate math used by the inline breakdown and the Tools tab.
//

import Foundation

enum WeightUnit: String, CaseIterable, Identifiable {
    case lb, kg
    var id: String { rawValue }
    var label: String { rawValue }
}

enum TrainingUnits {
    /// Shared with onboarding: "imperial" or "metric".
    static let preferenceKey = "unitPreference"
    static let lbPerKg = 2.20462262

    static var current: WeightUnit { unit(forPreference: UserDefaults.standard.string(forKey: preferenceKey)) }

    static func unit(forPreference value: String?) -> WeightUnit { value == "metric" ? .kg : .lb }

    /// Older builds had a second, unused toggle (`useMetric`). Fold it into the
    /// one setting once so a lifter who flipped it keeps kilograms.
    static func migrateLegacySetting() {
        let d = UserDefaults.standard
        guard d.object(forKey: preferenceKey) == nil, d.bool(forKey: "useMetric") else { return }
        d.set("metric", forKey: preferenceKey)
    }

    static func toDisplay(_ pounds: Double, _ unit: WeightUnit = current) -> Double {
        unit == .kg ? pounds / lbPerKg : pounds
    }

    static func toPounds(_ value: Double, from unit: WeightUnit = current) -> Double {
        unit == .kg ? value * lbPerKg : value
    }

    /// "135", "102.5", "1.25" — no trailing zeros, at most two decimals.
    static func number(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// A stored weight (lb) in the chosen unit, e.g. "61.2 kg".
    static func weight(_ pounds: Double, _ unit: WeightUnit = current, withUnit: Bool = true) -> String {
        var value = toDisplay(pounds, unit)
        // Kilograms read best to a tenth; pounds to a quarter.
        value = unit == .kg ? (value * 10).rounded() / 10 : (value * 4).rounded() / 4
        let text = number(value)
        return withUnit ? "\(text) \(unit.label)" : text
    }

    /// Total volume (lb stored), whole numbers with grouping.
    static func volume(_ pounds: Double, _ unit: WeightUnit = current) -> String {
        let value = Int(toDisplay(pounds, unit).rounded())
        return "\(value.formatted()) \(unit.label)"
    }

    /// Double-progression load step, in pounds: +5 lb upper / +10 lb lower,
    /// or +2.5 kg / +5 kg when the lifter trains in kilograms.
    static func progressionStepPounds(lowerBody: Bool, unit: WeightUnit = current) -> Double {
        switch unit {
        case .lb: return lowerBody ? 10 : 5
        case .kg: return toPounds(lowerBody ? 5 : 2.5, from: .kg)
        }
    }

    /// "1:30" for 90 seconds; "45s" under a minute.
    static func duration(_ seconds: Int) -> String {
        guard seconds >= 60 else { return "\(max(seconds, 0))s" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

// MARK: - Plate math

struct PlateBreakdown: Equatable {
    struct Plate: Equatable, Identifiable {
        let weight: Double
        let count: Int
        var id: Double { weight }
    }
    let unit: WeightUnit
    let target: Double
    let bar: Double
    let perSide: [Plate]
    /// Load per side that the available plates cannot make.
    let remainderPerSide: Double

    var loadable: Double { target - remainderPerSide * 2 }
    var isExact: Bool { remainderPerSide < 0.001 }
    var isBelowBar: Bool { target < bar }

    /// "45 + 25 + 5 per side".
    var summary: String {
        if isBelowBar { return "Less than the \(TrainingUnits.number(bar)) \(unit.label) bar" }
        if perSide.isEmpty { return "Empty bar" }
        let parts = perSide.flatMap { Array(repeating: TrainingUnits.number($0.weight), count: $0.count) }
        return parts.joined(separator: " + ") + " per side"
    }
}

enum PlateMath {
    static func plates(for unit: WeightUnit) -> [Double] {
        unit == .kg ? [25, 20, 15, 10, 5, 2.5, 1.25] : [45, 35, 25, 10, 5, 2.5]
    }

    static func defaultBar(for unit: WeightUnit) -> Double { unit == .kg ? 20 : 45 }

    /// Greedy breakdown, largest plates first. All values in `unit`.
    static func breakdown(total: Double, bar: Double, unit: WeightUnit, plates: [Double]? = nil) -> PlateBreakdown {
        let available = (plates ?? self.plates(for: unit)).sorted(by: >)
        guard total >= bar else {
            return PlateBreakdown(unit: unit, target: total, bar: bar, perSide: [], remainderPerSide: 0)
        }
        var remaining = (total - bar) / 2
        var result: [PlateBreakdown.Plate] = []
        for plate in available where plate > 0 {
            let count = Int((remaining + 0.0001) / plate)
            if count > 0 {
                result.append(.init(weight: plate, count: count))
                remaining -= Double(count) * plate
            }
        }
        return PlateBreakdown(unit: unit, target: total, bar: bar, perSide: result,
                              remainderPerSide: max(0, (remaining * 1000).rounded() / 1000))
    }
}
