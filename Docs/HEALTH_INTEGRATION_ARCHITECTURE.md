# Health Data Integration Architecture

## Overview
This document outlines the architecture for integrating WorkoutTracker with health platforms across multiple ecosystems: Apple (HealthKit), Android (Health Connect), Garmin Connect, and other popular fitness trackers.

---

## 0. What is actually wired (2026-08-29)

Everything below this section is the original design survey. This section is
the ground truth for the code in the repo.

### Wired now

| Piece | Where | Notes |
|---|---|---|
| HealthKit manager | `App/Sources/EndgameFitness/HealthKitManager.swift` | `#if os(iOS) && canImport(HealthKit)`; macOS gets a same-surface no-op stub so both targets compile from one codebase. `HealthKitManager.shared`, `@MainActor`, `ObservableObject`. |
| Authorization | `requestAuthorization()` | Read: steps, activeEnergyBurned, heartRate, bodyMass. Write: HKWorkout. "Connected" is remembered in UserDefaults (`healthKitConnected`) because HealthKit never reveals read-permission status. |
| Today's steps + active kcal | `refreshToday()` | Two `HKStatisticsQuery` cumulative sums from `startOfDay`. |
| Auto-refresh | `startObservingSteps()` | `HKObserverQuery` on stepCount + hourly background delivery; re-reads today's totals on every callback. |
| Save finished session as HKWorkout | `saveStrengthWorkout(start:durationSecs:name:activeKcal:)`, called from `WorkoutManager.completeWorkout()` in `WorkoutTrackerMac_Enhanced.swift` | `HKWorkoutBuilder`, `.traditionalStrengthTraining`, indoor; adds an active-energy sample only if a kcal value is passed (the tracker does not estimate kcal today, so none is written). Skipped when duration is 0, when not connected, or when the toggle is off. |
| Dashboard "Health" card (iOS only) | `HealthCard` in `WorkoutTrackerMac_Enhanced.swift`, inserted after `TodaysQuestsCard` in `DashboardView` | Shows steps, active kcal, an 8,000-step progress bar; shows a **Connect Apple Health** button until authorised. |
| Settings toggle | `SettingsView` → section "Apple Health" (iOS only) | "Sync workouts to Apple Health" (`healthSyncWorkoutsToAppleHealth`, default on). Shows the connect button when not yet connected. |
| Sync payload | `GameProfileService.sync()` in `GameProfile.swift` | Calls `refreshToday()` then adds `steps_today` (Int) and `active_kcal_today` (Double) to the `fitness/sync` body. Only present once connected. |
| Backend quest | `App/Backend/functions/_lib/game.js` + `functions/api/fitness/[[path]].js` | New daily quest `steps_8k` "Step Count" (8,000 steps, 50 XP, metric `steps`, `absolute: true`). `advance()` takes max(progress, reading) for absolute metrics so a re-sync cannot double-count. `handleSync` calls `advanceQuests(eventForHealth(body))` on every sync, with or without sessions. Covered by `tests/game-rules.test.mjs`. |
| Entitlements / capability | `App/Support/EndgameFitness-iOS.entitlements` (`com.apple.developer.healthkit` = true, `.access` = []) and `App/project.yml` iOS target `attributes.SystemCapabilities.com.apple.HealthKit` | iOS target only. macOS untouched. |
| Usage strings | `App/Support/Info-iOS.plist` | `NSHealthShareUsageDescription` / `NSHealthUpdateUsageDescription` were already present. |

### Not wired / not verified

- **Never run on a device or simulator.** Both targets typecheck
  (`swiftc -typecheck`, macOS 14 + iOS 17 simulator); the permission sheet,
  the queries and the workout write have not been exercised.
- **Provisioning.** The App ID `org.batesai.endgamefitness` must have the
  HealthKit capability enabled and the `Endgame Fitness IOS_APP_STORE` profile
  regenerated, or the signed build will be rejected for the new entitlement.
  Signing/ship scripts were deliberately not touched.
- **Heart rate and body mass** are requested but not read anywhere yet.
- **Active kcal on saved workouts** is not written (no estimate exists in the
  tracker). `active_kcal_today` is sent to the server but no quest uses it.
- **Background delivery** is enabled but there is no
  `UIBackgroundModes`/background-fetch handling; refresh happens while the app
  is foregrounded (observer callback, dashboard `.task`, and before each sync).
- **Trust model.** The server trusts `steps_today` the same way it trusts
  session volume: a patched client can lie. Steps are capped at the quest
  target and worth 50 XP, so the blast radius is small.
- Nothing for Android / Garmin / Fitbit exists; sections 2-5 remain proposals.

---

## 1. Apple HealthKit Integration (iOS/iPadOS/watchOS)

### Platform Support
- **iOS/iPadOS**: ✅ Fully supported
- **macOS**: ❌ **NOT** supported (HealthKit unavailable on macOS)
- **watchOS**: ✅ Fully supported

### Important Limitation
⚠️ **The macOS app CANNOT use HealthKit directly**. HealthKit is only available on iOS, iPadOS, and watchOS. In this codebase the iOS target has it (section 0); macOS compiles the no-op stub.

### Architecture Options for Apple Ecosystem

#### Option 1: iOS Companion App (Recommended)
**Create a separate iOS/watchOS app that syncs with the macOS app**

**Pros:**
- Direct HealthKit access on iOS/watchOS
- Native Apple Watch integration
- Real-time workout tracking with heart rate, calories, GPS
- Seamless iCloud sync between macOS and iOS apps

**Implementation:**
```swift
// iOS/watchOS App: HealthKit Manager
import HealthKit

class HealthKitManager {
    let healthStore = HKHealthStore()

    // Request Authorization
    func requestAuthorization(completion: @escaping (Bool, Error?) -> Void) {
        let typesToShare: Set = [
            HKQuantityType.workoutType(),
            HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKQuantityType.quantityType(forIdentifier: .heartRate)!
        ]

        let typesToRead: Set = [
            HKQuantityType.quantityType(forIdentifier: .heartRate)!,
            HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!,
            HKQuantityType.quantityType(forIdentifier: .stepCount)!,
            HKQuantityType.workoutType()
        ]

        healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead, completion: completion)
    }

    // Save Workout Session to HealthKit
    func saveWorkout(type: HKWorkoutActivityType, start: Date, end: Date, duration: TimeInterval,
                    calories: Double, distance: Double? = nil) {
        let workout = HKWorkout(activityType: type,
                               start: start,
                               end: end,
                               duration: duration,
                               totalEnergyBurned: HKQuantity(unit: .kilocalorie(), doubleValue: calories),
                               totalDistance: distance != nil ? HKQuantity(unit: .meter(), doubleValue: distance!) : nil,
                               metadata: ["AppName": "WorkoutTracker"])

        healthStore.save(workout) { success, error in
            if success {
                print("✅ Workout saved to HealthKit")
            }
        }
    }

    // Read Heart Rate Data
    func readHeartRate(completion: @escaping ([Double]) -> Void) {
        guard let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }

        let query = HKSampleQuery(sampleType: heartRateType, predicate: nil, limit: 100, sortDescriptors: nil) { query, samples, error in
            guard let samples = samples as? [HKQuantitySample] else { return }
            let heartRates = samples.map { $0.quantity.doubleValue(for: HKUnit(from: "count/min")) }
            completion(heartRates)
        }

        healthStore.execute(query)
    }
}
```

**iCloud Sync Strategy:**
```swift
// Shared Data via CloudKit
struct CloudSyncManager {
    // Use NSUbiquitousKeyValueStore for small data
    let store = NSUbiquitousKeyValueStore.default

    // Or use CloudKit for larger datasets
    let container = CKContainer.default()

    func syncWorkoutSession(_ session: WorkoutSession) {
        // Upload to CloudKit
        let record = CKRecord(recordType: "WorkoutSession")
        record["date"] = session.date
        record["duration"] = session.duration
        record["exercises"] = session.exercises.map { $0.name }

        container.publicCloudDatabase.save(record) { _, _ in }
    }
}
```

#### Option 2: macOS App Reads from HealthKit via iOS
**Use the iOS app as a bridge to read HealthKit data and expose it via iCloud/CloudKit**

**Flow:**
1. iOS app reads HealthKit data
2. iOS app uploads to CloudKit
3. macOS app downloads from CloudKit
4. macOS app displays health metrics

---

## 2. Android Health Connect Integration

### Overview
**Health Connect** (formerly Google Fit) is Android's unified health data platform as of 2025.

### Platform Support
- Android 9.0+ (API level 28+)
- Replaces Google Fit API

### Architecture

```kotlin
// Android: Health Connect Manager
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.records.*

class HealthConnectManager(context: Context) {
    private val healthConnectClient = HealthConnectClient.getOrCreate(context)

    // Request Permissions
    suspend fun requestPermissions() {
        val permissions = setOf(
            HealthPermission.createReadPermission(HeartRateRecord::class),
            HealthPermission.createReadPermission(StepsRecord::class),
            HealthPermission.createWritePermission(ExerciseSessionRecord::class)
        )

        healthConnectClient.permissionController.requestPermissions(permissions)
    }

    // Save Workout Session
    suspend fun saveWorkout(type: Int, start: Instant, end: Instant, calories: Double) {
        val session = ExerciseSessionRecord(
            startTime = start,
            endTime = end,
            exerciseType = type,
            title = "WorkoutTracker Session"
        )

        healthConnectClient.insertRecords(listOf(session))
    }

    // Read Heart Rate
    suspend fun readHeartRate(): List<Double> {
        val request = ReadRecordsRequest(
            recordType = HeartRateRecord::class,
            timeRangeFilter = TimeRangeFilter.before(Instant.now())
        )

        val response = healthConnectClient.readRecords(request)
        return response.records.map { it.samples.first().beatsPerMinute.toDouble() }
    }
}
```

### Cross-Platform Sync (Android ↔ macOS)
**Use Firebase Realtime Database or Firestore**

```kotlin
// Android: Upload to Firebase
class FirebaseSyncManager {
    private val database = Firebase.database.reference

    fun uploadWorkout(userId: String, workout: WorkoutSession) {
        database.child("users").child(userId).child("workouts").push().setValue(workout)
    }

    fun listenForUpdates(userId: String, callback: (WorkoutSession) -> Unit) {
        database.child("users").child(userId).child("workouts")
            .addValueEventListener(object : ValueEventListener {
                override fun onDataChange(snapshot: DataSnapshot) {
                    snapshot.children.forEach {
                        val workout = it.getValue(WorkoutSession::class.java)
                        workout?.let(callback)
                    }
                }

                override fun onCancelled(error: DatabaseError) {}
            })
    }
}
```

```swift
// macOS: Read from Firebase
import FirebaseDatabase

class FirebaseSyncManager {
    let ref = Database.database().reference()

    func downloadWorkouts(userId: String, completion: @escaping ([WorkoutSession]) -> Void) {
        ref.child("users").child(userId).child("workouts").observe(.value) { snapshot in
            var workouts: [WorkoutSession] = []
            for child in snapshot.children {
                if let snapshot = child as? DataSnapshot,
                   let data = snapshot.value as? [String: Any],
                   let workout = WorkoutSession(from: data) {
                    workouts.append(workout)
                }
            }
            completion(workouts)
        }
    }
}
```

---

## 3. Garmin Connect Integration

### Overview
Garmin now supports **Health Connect** on Android (July 2025) and has its own **Garmin Connect API** for web/server integration.

### Option 1: Android Health Connect (Easiest)
Since Garmin syncs to Health Connect, use the Health Connect integration above.

### Option 2: Garmin Connect API (Advanced)
**Requires OAuth 2.0 and server-side integration**

```swift
// Garmin OAuth Flow
class GarminAuthManager {
    let consumerKey = "YOUR_GARMIN_CONSUMER_KEY"
    let consumerSecret = "YOUR_GARMIN_CONSUMER_SECRET"

    func authorizeUser() {
        let authURL = "https://connect.garmin.com/oauthConfirm?oauth_token=\(token)"
        // Open in browser for user to authorize
    }

    func fetchActivityData(accessToken: String, completion: @escaping ([Activity]) -> Void) {
        let url = "https://apis.garmin.com/wellness-api/rest/activities"
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, error in
            // Parse activity data
        }.resume()
    }
}
```

**Garmin Health API Endpoints:**
- `GET /activities` - Fetch user activities
- `GET /dailies` - Fetch daily summaries (steps, calories, heart rate)
- `GET /sleeps` - Fetch sleep data
- `GET /stressDetails` - Fetch stress levels

---

## 4. Fitbit Integration

### Overview
Fitbit uses its own **Web API** with OAuth 2.0.

```swift
class FitbitAuthManager {
    let clientId = "YOUR_FITBIT_CLIENT_ID"
    let clientSecret = "YOUR_FITBIT_CLIENT_SECRET"

    func fetchActivities(accessToken: String, completion: @escaping ([Activity]) -> Void) {
        let url = "https://api.fitbit.com/1/user/-/activities/date/\(date).json"
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        URLSession.shared.dataTask(with: request) { data, response, error in
            // Parse activities
        }.resume()
    }
}
```

---

## 5. Unified Health Data Architecture

### Central Sync Manager

```swift
// Unified Health Sync Manager
class UnifiedHealthSyncManager {
    enum Platform {
        case apple      // HealthKit (iOS/watchOS only)
        case android    // Health Connect
        case garmin
        case fitbit
    }

    var enabledPlatforms: Set<Platform> = []

    // Upload workout to all enabled platforms
    func syncWorkout(_ workout: WorkoutSession) {
        if enabledPlatforms.contains(.apple) && canUseHealthKit() {
            // iOS only: Save to HealthKit
        }

        if enabledPlatforms.contains(.android) {
            // Upload to Firebase for Android sync
        }

        if enabledPlatforms.contains(.garmin) {
            // Upload to Garmin API
        }

        if enabledPlatforms.contains(.fitbit) {
            // Upload to Fitbit API
        }
    }

    // Download health metrics from all platforms
    func fetchHealthMetrics(completion: @escaping (HealthMetrics) -> Void) {
        var metrics = HealthMetrics()

        // Aggregate from all sources
        fetchFromHealthKit { healthKitData in
            metrics.heartRate = healthKitData.heartRate
        }

        fetchFromHealthConnect { healthConnectData in
            metrics.steps = healthConnectData.steps
        }

        fetchFromGarmin { garminData in
            metrics.calories = garminData.calories
        }

        completion(metrics)
    }

    private func canUseHealthKit() -> Bool {
        #if os(iOS) || os(watchOS)
        return true
        #else
        return false
        #endif
    }
}

struct HealthMetrics {
    var heartRate: [Double] = []
    var steps: Int = 0
    var calories: Double = 0
    var sleepHours: Double = 0
    var activeMinutes: Int = 0
}
```

---

## 6. Implementation Roadmap

### Phase 1: Apple Ecosystem (iOS/watchOS)
**Goal: Create iOS companion app with HealthKit integration**

**Steps:**
1. Create new iOS/watchOS target in Xcode
2. Implement HealthKit authorization
3. Build workout tracking with heart rate monitoring
4. Add Apple Watch complications
5. Implement CloudKit sync with macOS app
6. Test on iPhone + Apple Watch

**Timeline: 2-3 weeks**

### Phase 2: Android Integration
**Goal: Build Android app with Health Connect integration**

**Steps:**
1. Create Android project (Kotlin + Jetpack Compose)
2. Implement Health Connect permissions
3. Build workout tracking UI
4. Add Firebase sync for cross-platform data
5. Test on Android phone + Wear OS watch

**Timeline: 3-4 weeks**

### Phase 3: Third-Party Integrations
**Goal: Add Garmin, Fitbit, and other trackers**

**Steps:**
1. Implement OAuth 2.0 flows
2. Build server-side API proxy (if needed)
3. Add sync UI in Settings
4. Test with real devices

**Timeline: 2-3 weeks**

---

## 7. Free AI Voice Implementation (Current Status)

### ✅ Completed Features

1. **AVSpeechSynthesizer Integration**
   - Using Apple's free, built-in neural TTS
   - No API costs, no internet required
   - High-quality voices on iOS/macOS

2. **Four Coach Personalities**
   - **Motivator**: Energetic, high-energy (Samantha voice)
   - **Mentor**: Wise, thoughtful (Alex voice)
   - **Challenger**: Intense, competitive (Tom voice)
   - **Supporter**: Encouraging, compassionate (Zoe voice)

3. **Coaching Triggers**
   - Daily greeting messages (once per day)
   - Workout start announcements
   - Exercise completion encouragement
   - Workout completion celebrations

4. **Settings UI**
   - Toggle coaching on/off
   - Select personality
   - Test voice button
   - Beautiful SwiftUI interface

### Voice Selection
Apple provides **free, high-quality voices** across all devices:
- **Compact voices**: Always available, lower quality
- **Enhanced voices**: Downloaded via Settings → Accessibility, higher quality
- **Neural voices**: Best quality, requires download

**Recommended Enhanced Voices:**
- **Joelle** (en-US, female) - Warm, natural
- **Noelle** (en-US, female) - Professional
- **Aaron** (en-US, male) - Deep, confident
- **Nicky** (en-US, male) - Friendly

---

## 8. Alternative Voice Solutions (Future)

### Option 1: ElevenLabs (Paid, but Highest Quality)
- **Free Tier**: 10,000 characters/month
- **Pros**: Most realistic voices, emotion control
- **Cons**: Requires internet, API costs for heavy use

### Option 2: Coqui TTS (Open Source, Offline)
- **Free**: Fully open source
- **Pros**: Runs locally, no API costs
- **Cons**: Larger app size, more complex integration

### Option 3: Google Cloud TTS / AWS Polly
- **Free Tier**: Limited free usage
- **Pros**: Good quality, many voices
- **Cons**: Requires internet, costs after free tier

---

## 9. Summary & Recommendations

### Current Capabilities
✅ **AI Coaching**: Fully implemented with 4 personalities
✅ **macOS App**: Native SwiftUI app with world-class training programs
✅ **Free TTS**: Apple AVSpeechSynthesizer (no costs)

### Recommended Next Steps

**Short Term (1-2 months):**
1. ✅ Complete AI coaching (DONE)
2. Create iOS companion app with HealthKit
3. Add Apple Watch app for real-time tracking
4. Implement iCloud sync

**Medium Term (3-6 months):**
1. Build Android app with Health Connect
2. Add Firebase cross-platform sync
3. Implement Garmin integration (via Health Connect)

**Long Term (6-12 months):**
1. Add Fitbit, WHOOP, Oura integrations
2. Build web dashboard
3. Add social features (challenges, leaderboards)
4. Premium voice options (ElevenLabs)

---

## 10. Technical Notes

### HealthKit Limitations
- ❌ **macOS does NOT support HealthKit**
- ✅ iOS/iPadOS/watchOS only
- Must create separate iOS app for HealthKit integration

### Health Connect (Android)
- ✅ Replaces Google Fit in 2025
- ✅ Garmin now supports Health Connect (July 2025)
- ✅ Unified API for all Android health data

### Cross-Platform Strategy
**Use Firebase as the central hub:**
- iOS app → HealthKit → Firebase
- Android app → Health Connect → Firebase
- macOS app → Firebase (read-only for health metrics)
- Garmin → Health Connect → Firebase

---

## Contact & Support
For implementation questions or assistance, consult:
- Apple HealthKit: https://developer.apple.com/documentation/healthkit
- Health Connect: https://developer.android.com/health-connect
- Garmin API: https://developer.garmin.com/health-api/overview/
- AVSpeechSynthesizer: https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer
