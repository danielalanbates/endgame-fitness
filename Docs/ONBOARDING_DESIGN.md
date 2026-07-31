# WorkoutTracker Onboarding Design

## User Experience Flow

### First Launch Experience:
1. **Welcome Screen** - "Let's create your perfect workout program"
2. **Questionnaire** (7 steps)
3. **Generating Program** (AI creates meso + micro cycle)
4. **Preview Week 1** - Show the first week
5. **Start Training!**

---

## Questionnaire Steps

### Step 1: Basic Info
- **Name**: "What should we call you?"
- **Age**: Number picker (13-100)
- **Gender**: Male / Female / Other / Prefer not to say

### Step 2: Body Measurements
- **Current Weight**: Number + unit toggle (lbs/kg)
- **Height**: Number + unit toggle (ft/in or cm)
- **Body Fat %** (optional): Slider 5-50%

### Step 3: Experience Level
**"What's your training experience?"**
- 🌱 **Beginner** - "I'm new to working out"
- 💪 **Intermediate** - "I've been training 6-12 months"
- 🏆 **Advanced** - "I've been training 1+ years consistently"
- 🔥 **Elite** - "I compete or have years of serious training"

### Step 4: Primary Goals (Select up to 2)
- 💪 **Build Muscle** (Hypertrophy)
- ⚡ **Get Stronger** (Strength/Powerlifting)
- 🔥 **Lose Fat** (Cut/Recomp)
- 🏃 **Improve Endurance** (Conditioning)
- 🤸 **Athletic Performance** (Sports-specific)
- 🧘 **General Fitness** (Health & wellness)

### Step 5: Available Equipment
**"What equipment do you have access to?"**
- 🏋️ **Full Gym** - Barbell, dumbbells, machines, cables
- 🏠 **Home Gym** - Barbell, dumbbells, basic equipment
- 🎽 **Minimal Equipment** - Dumbbells, resistance bands
- 💪 **Bodyweight Only** - No equipment

### Step 6: Schedule & Availability
- **Days per week**: Slider 2-7 days
- **Session duration**: Slider 20-120 minutes
- **Preferred days**: Mon/Tue/Wed/Thu/Fri/Sat/Sun (multi-select)

### Step 7: Health & Limitations
- **Injuries**: Text field (optional)
- **Medical conditions**: Text field (optional)
- **Exercises to avoid**: Multi-select or text
- **Notes**: Free text

---

## Data Model

```swift
struct UserProfile: Codable {
    // Basic Info
    var name: String
    var age: Int
    var gender: Gender

    // Body Measurements
    var weight: Double // in lbs (converted if metric)
    var height: Double // in inches (converted if metric)
    var bodyFatPercentage: Double?

    // Experience & Goals
    var experienceLevel: ExperienceLevel
    var primaryGoals: [FitnessGoal] // Max 2

    // Equipment & Schedule
    var availableEquipment: EquipmentLevel
    var daysPerWeek: Int
    var sessionDuration: Int // minutes
    var preferredDays: [Weekday]

    // Health
    var injuries: String?
    var medicalConditions: String?
    var exercisesToAvoid: [String]
    var additionalNotes: String?

    // Calculated/Derived
    var bmi: Double {
        let heightMeters = height * 0.0254
        let weightKg = weight * 0.453592
        return weightKg / (heightMeters * heightMeters)
    }

    var tdee: Double {
        // Calculate Total Daily Energy Expenditure
        // Uses Mifflin-St Jeor equation
    }
}

enum Gender: String, Codable {
    case male, female, other, preferNotToSay
}

enum ExperienceLevel: String, Codable {
    case beginner, intermediate, advanced, elite
}

enum FitnessGoal: String, Codable {
    case buildMuscle, getStronger, loseFat,
         improveEndurance, athleticPerformance, generalFitness
}

enum EquipmentLevel: String, Codable {
    case fullGym, homeGym, minimal, bodyweightOnly
}

enum Weekday: String, Codable, CaseIterable {
    case monday, tuesday, wednesday, thursday,
         friday, saturday, sunday
}
```

---

## AI Program Generation Logic

### Meso Cycle Structure (12 weeks typically):
```
Mesocycle (12 weeks) = 3 Phases
├── Phase 1: Foundation (Weeks 1-4)
│   ├── Build work capacity
│   ├── Learn movement patterns
│   └── Moderate intensity
├── Phase 2: Progression (Weeks 5-8)
│   ├── Increase intensity
│   ├── Add volume
│   └── Progressive overload
└── Phase 3: Peak/Deload (Weeks 9-12)
    ├── Peak performance (Weeks 9-11)
    ├── Deload (Week 12)
    └── Test maxes/reassess
```

### Micro Cycle (1 week):
```
Week 1 Example (Upper/Lower 4-day):
├── Monday: Upper Body A
├── Tuesday: Lower Body A
├── Wednesday: Rest
├── Thursday: Upper Body B
├── Friday: Lower Body B
└── Weekend: Rest
```

### AI Generation Rules:

#### Based on Experience Level:
- **Beginner**: Full body 3x/week, compound movements, linear progression
- **Intermediate**: Upper/Lower or PPL, 4-6 days, periodization
- **Advanced**: Specialized splits, 5-6 days, advanced techniques
- **Elite**: Individualized, 6+ days, competition prep

#### Based on Goals:
- **Build Muscle**: 8-12 reps, 3-5 sets, shorter rest (60-90s)
- **Get Stronger**: 3-6 reps, 5+ sets, longer rest (3-5 min)
- **Lose Fat**: Circuits, supersets, higher volume, shorter rest
- **Endurance**: Lower weight, higher reps (15-20+), minimal rest

#### Based on Equipment:
- **Full Gym**: All exercises available
- **Home Gym**: Focus on barbell/dumbbell movements
- **Minimal**: Dumbbell variations, bodyweight progressions
- **Bodyweight**: Progressive calisthenics, tempo work

#### Based on Schedule:
- **2-3 days**: Full body each session
- **4 days**: Upper/Lower split
- **5 days**: Upper/Lower/Push/Pull/Legs hybrid
- **6 days**: PPL (2x per week)
- **7 days**: PPL + accessories or active recovery

---

## Program Generation Algorithm

```python
def generate_personalized_program(profile: UserProfile) -> MesoCycle:
    # 1. Determine program structure
    split_type = determine_split(profile.experience, profile.days_per_week)

    # 2. Select exercises
    exercises = select_exercises(
        goals=profile.goals,
        equipment=profile.equipment,
        avoid=profile.exercises_to_avoid,
        injuries=profile.injuries
    )

    # 3. Calculate volume & intensity
    volume = calculate_volume(profile.experience, profile.goals)
    intensity = calculate_intensity(profile.goals, profile.experience)

    # 4. Build mesocycle (12 weeks)
    mesocycle = MesoCycle(weeks=12, phases=3)

    for phase in mesocycle.phases:
        for week in phase.weeks:
            for day in week.days:
                workout = generate_workout(
                    split_type=split_type,
                    exercises=exercises,
                    volume=volume,
                    intensity=intensity,
                    phase=phase.type
                )
                day.workout = workout

    return mesocycle
```

---

## Example Generated Program

### User Profile:
- Name: Daniel
- Age: 32, Male
- Weight: 180 lbs, Height: 6'0"
- Experience: Intermediate
- Goals: Build Muscle + Get Stronger
- Equipment: Full Gym
- Schedule: 5 days/week, 60 min sessions
- Days: Mon/Tue/Thu/Fri/Sat

### Generated Program:

**Program Type**: Upper/Lower/Push/Pull/Legs Hybrid
**Duration**: 12 weeks (3 phases of 4 weeks each)
**Focus**: Hypertrophy with strength foundation

#### Week 1 Micro Cycle:

**Monday - Upper Body (Strength Focus)**
1. Bench Press: 4x6-8 @ RPE 8 (3 min rest)
2. Barbell Rows: 4x6-8 @ RPE 8 (3 min rest)
3. Overhead Press: 3x8-10 @ RPE 7 (2 min rest)
4. Pull-ups: 3x8-12 @ RPE 8 (2 min rest)
5. DB Flyes: 3x12-15 @ RPE 7 (90 sec rest)
6. Face Pulls: 3x15-20 @ RPE 6 (60 sec rest)

**Tuesday - Lower Body (Quad Focus)**
1. Squat: 4x6-8 @ RPE 8 (3 min rest)
2. Romanian Deadlift: 3x8-10 @ RPE 7 (2 min rest)
3. Leg Press: 3x12-15 @ RPE 7 (90 sec rest)
4. Leg Curls: 3x12-15 @ RPE 7 (60 sec rest)
5. Calf Raises: 4x15-20 @ RPE 7 (60 sec rest)
6. Planks: 3x45-60s (60 sec rest)

**Wednesday - Rest/Active Recovery**

**Thursday - Push Day (Chest/Shoulders/Triceps)**
1. Incline Bench Press: 4x8-10 @ RPE 7 (2 min rest)
2. DB Overhead Press: 3x10-12 @ RPE 7 (90 sec rest)
3. Cable Flyes: 3x12-15 @ RPE 7 (60 sec rest)
4. Lateral Raises: 3x12-15 @ RPE 6 (60 sec rest)
5. Tricep Pushdowns: 3x12-15 @ RPE 7 (60 sec rest)
6. Overhead Tricep Ext: 3x12-15 @ RPE 6 (60 sec rest)

**Friday - Pull Day (Back/Biceps)**
1. Deadlift: 4x5-6 @ RPE 8 (3 min rest)
2. Weighted Pull-ups: 3x6-8 @ RPE 8 (2 min rest)
3. Cable Rows: 3x10-12 @ RPE 7 (90 sec rest)
4. Shrugs: 3x12-15 @ RPE 7 (60 sec rest)
5. Barbell Curls: 3x10-12 @ RPE 7 (60 sec rest)
6. Hammer Curls: 3x12-15 @ RPE 6 (60 sec rest)

**Saturday - Legs Day (Hamstring/Glute Focus)**
1. Front Squat: 3x8-10 @ RPE 7 (2 min rest)
2. Stiff-Leg Deadlift: 3x8-10 @ RPE 7 (2 min rest)
3. Bulgarian Split Squats: 3x10-12/leg @ RPE 7 (90 sec rest)
4. Leg Extensions: 3x15-20 @ RPE 6 (60 sec rest)
5. Seated Calf Raises: 4x20 @ RPE 6 (60 sec rest)
6. Hanging Leg Raises: 3x15 @ RPE 7 (60 sec rest)

**Sunday - Rest**

---

## Implementation in Swift

The onboarding flow will:
1. Show when no profile exists
2. Collect all data in a beautiful multi-step form
3. Generate program using Python + local AI logic
4. Save profile and program
5. Show Week 1 preview
6. Launch into regular app experience

User can re-take questionnaire anytime from Settings → "Update Profile & Program"

---

## Next Steps

1. Create UserProfile model
2. Build OnboardingView (multi-step form)
3. Create program generation service
4. Integrate with existing app
5. Test complete flow

Ready to implement!
