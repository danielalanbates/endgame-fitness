// HealthKitManager.swift
// Endgame Fitness — Apple Health bridge.
//
// HealthKit exists only on iOS/iPadOS/watchOS. Both targets compile this file:
// the iOS half talks to HKHealthStore, the macOS half is an inert stub with the
// same surface so call sites never need their own #if. Everything the rest of
// the app touches goes through `HealthKitManager.shared`.
//
// What it does:
//   • asks for read access to steps and active energy (the only types it
//     reads), and write access for strength-training workouts
//   • reads today's step count and active kilocalories (HKStatisticsQuery)
//   • keeps an HKObserverQuery on steps so the dashboard refreshes itself
//   • writes a finished session as an HKWorkout (.traditionalStrengthTraining)
//     when the "Sync workouts to Apple Health" setting is on. Only sessions
//     with at least one completed set are ever saved (WorkoutManager.
//     completeWorkout returns before this point otherwise).
//
// The step/energy numbers also ride along on the sync payload
// (`steps_today`, `active_kcal_today`) so server-side quests can use them.

import Foundation
import Combine

private let healthConnectedKey = "healthKitConnected"
private let healthSyncWorkoutsKey = "healthSyncWorkoutsToAppleHealth"

#if os(iOS) && canImport(HealthKit)
import HealthKit

@MainActor
final class HealthKitManager: ObservableObject {
    static let shared = HealthKitManager()

    /// False on iPad models / configurations without a health store.
    let isAvailable: Bool = HKHealthStore.isHealthDataAvailable()

    /// True once the user has been through the authorization sheet. HealthKit
    /// never reveals whether *read* access was granted, so this is the best
    /// signal we have for "connected"; the numbers simply stay at 0 if denied.
    @Published private(set) var isConnected: Bool =
        UserDefaults.standard.bool(forKey: healthConnectedKey)

    @Published private(set) var stepsToday: Int = 0
    @Published private(set) var activeKcalToday: Double = 0
    @Published private(set) var lastRefreshed: Date?
    @Published private(set) var lastError: String?

    /// Settings toggle. Defaults on; only matters once connected.
    @Published var syncWorkoutsToHealth: Bool {
        didSet { UserDefaults.standard.set(syncWorkoutsToHealth, forKey: healthSyncWorkoutsKey) }
    }

    private let store = HKHealthStore()
    private var stepObserver: HKObserverQuery?

    private var stepType: HKQuantityType { HKQuantityType(.stepCount) }
    private var energyType: HKQuantityType { HKQuantityType(.activeEnergyBurned) }
    private var readTypes: Set<HKObjectType> {
        // Only what is read: asking for more than the app uses is an App
        // Review problem and a privacy one.
        [
            HKQuantityType(.stepCount),
            HKQuantityType(.activeEnergyBurned),
        ]
    }
    private var shareTypes: Set<HKSampleType> { [HKWorkoutType.workoutType()] }

    private init() {
        if UserDefaults.standard.object(forKey: healthSyncWorkoutsKey) == nil {
            syncWorkoutsToHealth = true
        } else {
            syncWorkoutsToHealth = UserDefaults.standard.bool(forKey: healthSyncWorkoutsKey)
        }
        if isConnected { startObservingSteps() }
    }

    // MARK: Authorization

    /// Presents the Health permission sheet. Returns true if the request went
    /// through (not whether every type was granted — Apple hides that).
    @discardableResult
    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        do {
            try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
            isConnected = true
            UserDefaults.standard.set(true, forKey: healthConnectedKey)
            lastError = nil
            startObservingSteps()
            await refreshToday()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Whether we may write workouts. Read status is never disclosed.
    var canWriteWorkouts: Bool {
        isAvailable && store.authorizationStatus(for: HKWorkoutType.workoutType()) == .sharingAuthorized
    }

    // MARK: Today's numbers

    func refreshToday() async {
        guard isAvailable, isConnected else { return }
        async let steps = sumToday(stepType, unit: .count())
        async let kcal = sumToday(energyType, unit: .kilocalorie())
        let (s, k) = await (steps, kcal)
        stepsToday = Int(s.rounded())
        activeKcalToday = k
        lastRefreshed = Date()
    }

    private func sumToday(_ type: HKQuantityType, unit: HKUnit) async -> Double {
        let start = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: .strictStartDate)
        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                          options: .cumulativeSum) { _, stats, _ in
                continuation.resume(returning: stats?.sumQuantity()?.doubleValue(for: unit) ?? 0)
            }
            store.execute(query)
        }
    }

    // MARK: Observer

    /// Long-running query: Health calls back whenever new step samples land
    /// (phone motion coprocessor, Watch sync), and we re-read today's totals.
    func startObservingSteps() {
        guard isAvailable, stepObserver == nil else { return }
        let query = HKObserverQuery(sampleType: stepType, predicate: nil) { [weak self] _, completion, _ in
            Task { @MainActor in await self?.refreshToday() }
            completion()
        }
        stepObserver = query
        store.execute(query)
        store.enableBackgroundDelivery(for: stepType, frequency: .hourly) { _, _ in }
    }

    // MARK: Writing workouts

    /// Save a finished strength session to Health. No-op unless connected,
    /// the setting is on, and the session has a positive duration.
    func saveStrengthWorkout(start: Date, durationSecs: Int, name: String?, activeKcal: Double? = nil) {
        guard isAvailable, isConnected, syncWorkoutsToHealth, durationSecs > 0, start <= Date() else { return }
        let end = start.addingTimeInterval(TimeInterval(durationSecs))
        Task { await self.writeWorkout(start: start, end: end, name: name, activeKcal: activeKcal) }
    }

    private func writeWorkout(start: Date, end: Date, name: String?, activeKcal: Double?) async {
        guard canWriteWorkouts else {
            lastError = "Apple Health has not allowed workout writing."
            return
        }
        let config = HKWorkoutConfiguration()
        config.activityType = .traditionalStrengthTraining
        config.locationType = .indoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
        do {
            try await builder.beginCollection(at: start)
            if let kcal = activeKcal, kcal > 0 {
                let quantity = HKQuantity(unit: .kilocalorie(), doubleValue: kcal)
                let sample = HKCumulativeQuantitySample(type: energyType, quantity: quantity, start: start, end: end)
                try await builder.addSamples([sample])
            }
            if let name, !name.isEmpty {
                try await builder.addMetadata([HKMetadataKeyWorkoutBrandName: "Endgame Fitness: \(name)"])
            }
            try await builder.endCollection(at: end)
            _ = try await builder.finishWorkout()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Fields appended to the fitness/sync payload.
    var syncFields: [String: Any] {
        guard isConnected else { return [:] }
        return ["steps_today": stepsToday, "active_kcal_today": activeKcalToday]
    }
}

#else

/// macOS (and any platform without HealthKit): same surface, does nothing.
@MainActor
final class HealthKitManager: ObservableObject {
    static let shared = HealthKitManager()

    let isAvailable = false
    @Published private(set) var isConnected = false
    @Published private(set) var stepsToday: Int = 0
    @Published private(set) var activeKcalToday: Double = 0
    @Published private(set) var lastRefreshed: Date?
    @Published private(set) var lastError: String?
    @Published var syncWorkoutsToHealth: Bool = false

    private init() {}

    var canWriteWorkouts: Bool { false }
    @discardableResult func requestAuthorization() async -> Bool { false }
    func refreshToday() async {}
    func startObservingSteps() {}
    func saveStrengthWorkout(start: Date, durationSecs: Int, name: String?, activeKcal: Double? = nil) {}
    var syncFields: [String: Any] { [:] }
}

#endif
