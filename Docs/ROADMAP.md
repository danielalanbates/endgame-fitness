# WorkoutTracker Development Roadmap

## Completed Features ✅

### 1. Core Application
- ✅ Onboarding system with 8-step questionnaire
- ✅ Pre-filled test data for quick testing
- ✅ Checkbox system for medical conditions
- ✅ Post-workout feedback questionnaire
- ✅ App icon in dock/menu bar

### 2. Exercise Library
- ✅ 60+ consolidated exercises (no duplicates)
- ✅ 14 body part categories including Cardiovascular
- ✅ Equipment specifications (Barbell, Dumbbell, Cable, etc.)
- ✅ Difficulty ratings (Beginner, Intermediate, Advanced)
- ✅ Search and filter by body part
- ✅ Equipment tracking system added to UserProfile

### 3. Workout Management
- ✅ Auto-load exercises when starting from a program
- ✅ Programs tab with clickable program cards
- ✅ Week 1 preview before starting program
- ✅ "Start My Program" jumps to first workout with pre-loaded exercises

## In Progress / Planned Features 🚧

### Priority 1: Workout Customization
**User Story**: "I need to add/remove exercises from my workout"

#### Features to Implement:
1. **Add Exercises to Active Workout from Library**
   - ✅ Already has "+ button" when workout is active
   - ⏳ Needs: Select which day of the week to add to
   - ⏳ Needs: Add to future workout days, not just current

2. **Edit Workout Days**
   - Location: New "Edit Day" button in ProgramsView week preview
   - Features needed:
     - Reorder exercises (drag & drop)
     - Remove exercises
     - Edit sets/reps/rest for each exercise
     - Save changes to program

3. **Workout Day Selector in Exercise Library**
   - When user clicks "+" on an exercise:
     - Show modal: "Add to which day?"
     - List upcoming 7 days from program
     - Or "Add to current workout"
   - Implementation: New `WorkoutDayPickerSheet` view

### Priority 2: At-Home Workout Generator
**User Story**: "I want workouts based on equipment I have at home"

#### Equipment System (✅ Partially Complete):
- ✅ `AvailableEquipment` enum with 19 equipment types
- ✅ `EquipmentLevel` with `defaultEquipment` mapping
- ✅ UserProfile now has `specificEquipment: [AvailableEquipment]`

#### Remaining Work:
1. **Equipment Selection UI**
   - Add to EquipmentStep in onboarding
   - Checkbox grid showing all equipment
   - Pre-select based on chosen EquipmentLevel
   - Allow customization

2. **Equipment-Based Exercise Filtering**
   - Update `ExerciseLibrary.exercisesFor(equipment:)`
   - Filter exercises by user's available equipment
   - Show "Requires: X" badge for unavailable exercises

3. **Home Workout Program Generator**
   - Duplicate `AIProgramGenerator.generatePersonalizedProgram()`
   - Filter exercise selection by `profile.specificEquipment`
   - Prioritize bodyweight and dumbbell exercises for home
   - Progressive overload strategies for limited equipment

### Priority 3: WOD (Workout of the Day) Randomizer
**User Story**: "I want a random workout each day with variety"

#### Design:
1. **WOD Generator Algorithm**
   ```swift
   class WODGenerator {
       func generateDailyWOD(profile: UserProfile) -> WorkoutSession {
           // 1. Choose WOD type (AMRAP, EMOM, For Time, Strength Focus)
           // 2. Select exercises based on:
           //    - Body parts worked in last 3 days (avoid overlap)
           //    - Equipment available
           //    - Experience level
           //    - Time available (profile.sessionDuration)
           // 3. Apply exercise science:
           //    - Compound before isolation
           //    - Heavy before light
           //    - Proper muscle group pairing
           // 4. Set appropriate volume/intensity
       }
   }
   ```

2. **WOD Types**:
   - **AMRAP** (As Many Rounds As Possible): Time cap, repeat circuit
   - **EMOM** (Every Minute On the Minute): Time-based intervals
   - **For Time**: Complete prescribed work as fast as possible
   - **Chipper**: Long list of exercises done once
   - **Strength Focus**: 5x5, 3x8, pyramid schemes
   - **Hero WOD**: Famous benchmark workouts

3. **Smart Randomization**:
   - Track last 7 days of work
   - Avoid hitting same muscle groups consecutive days
   - Ensure balance over week (push/pull/legs ratio)
   - Respect recovery needs

4. **UI Components**:
   - "Random WOD" button on Dashboard
   - WOD preview with estimated time
   - "I like this"/"Generate another" options
   - Save favorites

### Priority 4: Mesocycle & Periodization
**User Story**: "I want proper progressive overload and deload weeks"

#### Periodization Model:
```swift
struct Mesocycle {
    var name: String  // e.g., "Hypertrophy Phase 1"
    var weeks: Int    // Typically 4-6 weeks
    var focusType: FocusType  // Strength, Hypertrophy, Power, Endurance
    var volumeProgression: VolumeProgression
    var intensityProgression: IntensityProgression
}

enum FocusType {
    case strength      // 3-5 reps, 85%+
    case hypertrophy   // 8-12 reps, 65-85%
    case muscularEndurance  // 15+ reps, 50-65%
    case power         // 1-5 reps, explosive
}

struct VolumeProgression {
    var week1: Double  // % of max volume
    var week2: Double
    var week3: Double
    var week4: Double  // Usually deload (60-70%)

    static let standard = VolumeProgression(
        week1: 0.7,
        week2: 0.85,
        week3: 1.0,  // Peak volume
        week4: 0.6   // Deload
    )
}
```

#### Implementation Plan:
1. **Program Structure Update**:
   - WorkoutProgram gets `mesocycles: [Mesocycle]`
   - Each mesocycle has 4-6 weeks
   - Total program = 12-16 weeks (2-3 mesocycles)

2. **Auto-Progression**:
   - Track completed workouts
   - Auto-calculate next week's weights
   - Based on RPE from feedback questionnaire
   - If RPE consistently low → increase weight
   - If RPE too high → deload or reduce volume

3. **Deload Weeks**:
   - Every 4th week
   - 60-70% volume
   - Same exercises, reduced sets/weight
   - Active recovery focus

4. **Phase Transitions**:
   - Strength → Hypertrophy → Power
   - Or Hypertrophy → Strength → Functional
   - User chooses or AI recommends

### Priority 5: Workout History & Analytics
1. **Track Progression**:
   - Volume progression over time (chart)
   - 1RM estimations for main lifts
   - PR tracking (Personal Records)

2. **Recovery Insights**:
   - Based on feedback questionnaires
   - Recommend deload if fatigue high
   - Suggest rest days

3. **Body Part Analysis**:
   - Heatmap of muscle groups trained
   - Identify imbalances
   - Suggest exercises to balance

## Technical Architecture Notes

### Data Models Needed:
```swift
// Already have: WorkoutSession, Exercise, ExerciseSet, WorkoutProgram

// Need to add:
struct WOD: Codable {
    let id: UUID
    var type: WODType
    var name: String
    var exercises: [WODExercise]
    var scheme: String  // "21-15-9", "5 rounds", "20 min AMRAP"
    var difficulty: Int
}

enum WODType: String, Codable {
    case amrap, emom, forTime, chipper, strength
}

struct Mesocycle: Codable {
    var name: String
    var weeks: Int
    var focus: FocusType
    var volumeProgression: [Double]  // Per week multipliers
}
```

### Algorithm Considerations:
1. **Exercise Selection**:
   - Must respect equipment constraints
   - Must respect injuries/limitations
   - Must provide progressive overload
   - Must avoid overtraining patterns

2. **Volume Calculations**:
   - Sets × Reps × Weight = Volume
   - Track per muscle group per week
   - Optimal hypertrophy: 10-20 sets/muscle/week
   - Beginners: Lower end, Advanced: Higher end

3. **Intensity Management**:
   - Use feedback (difficulty, energy, form) to adjust
   - Auto-regulate based on performance
   - Implement RPE or RIR tracking

## Next Steps - What to Build First

### Immediate (This Session):
1. ✅ Equipment tracking (DONE)
2. Add Equipment selection to onboarding EquipmentStep
3. Filter Exercise Library by user equipment
4. Add "Choose Day" modal when adding exercise from library

### Short Term (Next Session):
1. WOD Randomizer basic version
2. Edit workout day functionality
3. Equipment-based program filtering

### Medium Term:
1. Mesocycle system
2. Auto-progression algorithm
3. Deload week implementation
4. Advanced analytics

### Long Term:
1. AI-powered recommendations
2. Movement pattern analysis
3. Nutrition integration
4. Social features (share workouts)

## Questions for User:
1. Which feature is highest priority?
   - Workout customization (edit/add exercises)?
   - WOD randomizer?
   - At-home workout filtering?
   - Mesocycle/periodization?

2. For WOD randomizer:
   - Should it be CrossFit-style (AMRAP, EMOM)?
   - Or more traditional strength training?
   - Or mix of both?

3. For equipment at home:
   - Should Equipment selection be part of onboarding?
   - Or in Settings for later customization?

---
Generated: 2025-11-04
Status: Planning & Architecture Complete
Ready for: Implementation
