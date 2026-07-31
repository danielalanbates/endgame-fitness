# 🎮 Avatar System Integration Guide

## Files Created

✅ **AvatarSystem.swift** - Core 3D blob avatar logic
- `AvatarBodyProfile` - Data model for avatar appearance
- `AvatarEvolutionEngine` - Updates avatar based on progress
- `BlobAvatar3D` - SceneKit 3D rendering and animations

✅ **AvatarViews.swift** - SwiftUI views
- `AvatarQuestionnaireView` - Initial setup questionnaire
- `AvatarPreviewView` - Preview before confirming
- `AvatarDisplayView` - Main app avatar display
- `AvatarEvolutionNotification` - Progress celebration

---

## Integration Steps

### Step 1: Add Avatar to UserProfile

In `WorkoutTrackerMac_Enhanced.swift`, add to `UserProfile` struct (around line 200):

```swift
struct UserProfile: Codable {
    // ... existing fields ...

    // NEW: Avatar system
    var avatarProfile: AvatarBodyProfile?
    var avatarCreated: Bool = false
}
```

### Step 2: Add Avatar to WorkoutManager

In `WorkoutManager` class, add:

```swift
class WorkoutManager: ObservableObject {
    // ... existing @Published properties ...

    // NEW: Avatar state
    @Published var showAvatarQuestionnaire = false
    @Published var showAvatarEvolution = false
    @Published var previousAvatarProfile: AvatarBodyProfile?

    // ... existing code ...
}
```

### Step 3: Update Avatar After Workouts

In `WorkoutManager.finishWorkout()`, add before saving:

```swift
func finishWorkout() {
    guard var session = currentWorkout else { return }

    // ... existing workout completion code ...

    // NEW: Update avatar based on workout
    if var avatarProfile = userProfile.avatarProfile {
        let oldProfile = avatarProfile

        AvatarEvolutionEngine.updateAvatar(
            &avatarProfile,
            totalVolume: totalVolume,
            weightChange: calculateWeightChange(),
            level: userProfile.level
        )

        userProfile.avatarProfile = avatarProfile

        // Show evolution notification if significant change
        if avatarProfile.muscleLevel != oldProfile.muscleLevel ||
           avatarProfile.leanLevel != oldProfile.leanLevel {
            previousAvatarProfile = oldProfile
            showAvatarEvolution = true
        }
    }

    // ... rest of existing code ...
}
```

### Step 4: Add Avatar Tab to Main UI

In `ContentView` (around the TabView), add a new tab:

```swift
TabView(selection: $selectedTab) {
    // ... existing tabs ...

    // NEW: Avatar tab
    VStack {
        if let avatarProfile = workoutManager.userProfile.avatarProfile {
            AvatarDisplayView(
                profile: Binding(
                    get: { avatarProfile },
                    set: { workoutManager.userProfile.avatarProfile = $0 }
                ),
                showFullScreen: true
            )
        } else {
            VStack(spacing: 20) {
                Image(systemName: "person.circle")
                    .font(.system(size: 72))
                    .foregroundColor(.gray)

                Text("No Avatar Yet")
                    .font(.title)

                Button("Create Your Avatar") {
                    workoutManager.showAvatarQuestionnaire = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
    .tabItem {
        Label("Avatar", systemImage: "person.circle.fill")
    }
    .tag(6)
}
```

### Step 5: Add Questionnaire Sheet

In `ContentView.body`, add the sheet modifier:

```swift
.sheet(isPresented: $workoutManager.showAvatarQuestionnaire) {
    if let binding = Binding(
        get: { workoutManager.userProfile.avatarProfile ?? .defaultBlob },
        set: { workoutManager.userProfile.avatarProfile = $0 }
    ) {
        AvatarQuestionnaireView(
            profile: binding,
            isComplete: $workoutManager.userProfile.avatarCreated
        )
    }
}
.alert("Avatar Evolved!", isPresented: $workoutManager.showAvatarEvolution) {
    Button("Awesome!") { }
} message: {
    if let old = workoutManager.previousAvatarProfile,
       let new = workoutManager.userProfile.avatarProfile {
        Text(AvatarEvolutionEngine.getProgressDescription(new))
    }
}
```

### Step 6: Show Questionnaire on First Launch

In `WorkoutManager.init()` or `onAppear` of main view:

```swift
.onAppear {
    // Check if avatar has been created
    if !workoutManager.userProfile.avatarCreated {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            workoutManager.showAvatarQuestionnaire = true
        }
    }
}
```

---

## Avatar Features Summary

### Initial Setup
1. User opens app for first time
2. Questionnaire appears (3 questions)
3. Avatar is created based on answers
4. Starting blob: Blue, no eyes/mouth, proportions match user

### Evolution System
**Automatic updates after each workout:**
- **Muscle Level** (0-100): Based on total volume lifted
  - Every 10,000 lbs = +10 points
- **Lean Level** (0-100): Based on weight loss
  - Every 10 lbs lost = +10 points

### Visual Unlocks
- **Level 3**: Eyes + Mouth appear
- **Level 5**: Green color unlocked
- **Level 10**: Purple color + Gym Shirt outfit
- **Level 15**: Orange color + Tank Top
- **Level 20**: Red color + Hoodie
- **Level 30**: Gold color + Champion Belt
- **Level 50**: Rainbow color + Legend Crown

### Animations
- **Idle**: Gentle bouncing (automatic)
- **Squat**: Squatting motion (button)
- **Jump**: Jumping jacks (button)
- **Celebrate**: Spin + jump (button, auto on level up)

### Body Morphing
Avatar changes dimensions as user progresses:
- **Belly shrinks** as user loses weight
- **Arms/legs thicken** as muscle increases
- **Shoulders widen** with upper body work
- **Overall scale** adjusts with body composition

---

## Testing the System

### Test Avatar Creation
1. Delete user data to simulate first launch
2. Open app
3. Questionnaire should appear
4. Select: Tall + Heavy + Large belly
5. Preview should show larger blue blob
6. Confirm and check Avatar tab

### Test Evolution
1. Complete a workout with high volume (10,000+ lbs)
2. Finish workout
3. Avatar should show +10 muscle level
4. Check Avatar tab - blob should look slightly more defined

### Test Animations
1. Go to Avatar tab
2. Click "Squat" - blob should squat
3. Click "Jump" - blob should jump
4. Click "Celebrate" - blob should spin and jump

### Test Unlocks
1. Manually set `userProfile.level = 3` in code
2. Avatar should gain eyes and mouth
3. Set `userProfile.level = 5`
4. Green color should be available in profile

---

## File Structure

```
Workout_Tracker_Enhanced/
├── AvatarSystem.swift          # ✅ DONE - Core logic
├── AvatarViews.swift           # ✅ DONE - SwiftUI views
├── WorkoutTrackerMac_Enhanced.swift  # 🔲 TODO - Add integration
└── AVATAR_INTEGRATION_GUIDE.md # 📄 This file
```

---

## Code Snippets for Quick Copy-Paste

### Add to UserProfile
```swift
var avatarProfile: AvatarBodyProfile?
var avatarCreated: Bool = false
```

### Add to WorkoutManager
```swift
@Published var showAvatarQuestionnaire = false
@Published var showAvatarEvolution = false
@Published var previousAvatarProfile: AvatarBodyProfile?
```

### Weight Change Calculator (helper)
```swift
private func calculateWeightChange() -> Double {
    // Compare current weight to starting weight
    let recentWeights = workoutSessions
        .prefix(10)
        .compactMap { $0.bodyWeight }

    guard let currentWeight = recentWeights.first,
          let startingWeight = recentWeights.last else {
        return 0
    }

    return currentWeight - startingWeight
}
```

---

## Next Steps

1. ✅ Create `AvatarSystem.swift`
2. ✅ Create `AvatarViews.swift`
3. 🔲 Integrate into `WorkoutTrackerMac_Enhanced.swift`
4. 🔲 Test avatar creation flow
5. 🔲 Test evolution after workouts
6. 🔲 Add exercise demonstration animations (Phase 2)
7. 🔲 Add AR mode (Phase 3)

---

## Future Enhancements (Phase 2+)

### Exercise Demonstrations
- Avatar performs each exercise before user starts
- Real-time form comparison
- Rep counting with avatar

### AR Integration
- Place avatar in real environment
- Walk around to see different angles
- Side-by-side comparison (user vs avatar)

### Customization
- Unlock new colors via achievements
- Outfit system (gym clothes, accessories)
- Special effects (glow, particles on level up)

### Social Features
- Share avatar transformations
- Compare with friends
- Avatar races (who lifts more volume)

---

**The avatar system is READY!** Just needs integration into main app. Let's do that next! 🎮💪
