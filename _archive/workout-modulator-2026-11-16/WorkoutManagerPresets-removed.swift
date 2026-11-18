// Archived 2026-11-16 from WorkoutManager (WorkoutTrackerMac_Enhanced.swift).
// Dead once the Workout Modulator was removed: nothing called generateInitialProgram(),
// and the presets / sliders only fed the legacy Monday-Saturday template generators below.

// --- properties ---
    @Published var repRangeModulation: Double = 50.0 // 0-100, 50=neutral
    @Published var volumeIntensityModulation: Double = 50.0 // Lower=volume bias, higher=intensity bias
    @Published var frequencyModulation: Double = 50.0 // Lower=often, higher=sparingly
    @Published var bodybuilderMiniActive: Bool = false

// --- init call ---
        loadModulations()

// --- persistence ---
    func loadModulations() {
        repRangeModulation = UserDefaults.standard.double(forKey: "repRangeModulation") != 0 ? UserDefaults.standard.double(forKey: "repRangeModulation") : 50.0
        volumeIntensityModulation = UserDefaults.standard.double(forKey: "volumeIntensityModulation") != 0 ? UserDefaults.standard.double(forKey: "volumeIntensityModulation") : 50.0
        frequencyModulation = UserDefaults.standard.double(forKey: "frequencyModulation") != 0 ? UserDefaults.standard.double(forKey: "frequencyModulation") : 50.0
        bodybuilderMiniActive = UserDefaults.standard.bool(forKey: "bodybuilderMiniActive")
    }

    func saveModulations() {
        UserDefaults.standard.set(repRangeModulation, forKey: "repRangeModulation")
        UserDefaults.standard.set(volumeIntensityModulation, forKey: "volumeIntensityModulation")
        UserDefaults.standard.set(frequencyModulation, forKey: "frequencyModulation")
        UserDefaults.standard.set(bodybuilderMiniActive, forKey: "bodybuilderMiniActive")
        UserDefaults.standard.synchronize()
    }

// --- generateInitialProgram ---
    func generateInitialProgram() {
        guard userProfile != nil else { return }

        // Start with optimal preset by default
        generateProgramWithPreset(preset: "optimal")
    }


// --- presets and template generators ---
    // Generate program with specific preset and modulation settings
    func generateProgramWithPreset(preset: String) {
        switch preset {
        case "optimal":
            generateOptimalProgram()
        case "time_crunched":
            generateTimeCrunchedProgram()
        case "weekend_warrior":
            generateWeekendWarriorProgram()
        case "longevity":
            generateLongevityProgram()
        case "strength":
            generateStrengthProgram()
        case "weight_lifter":
            generateWeightLifterProgram()
        case "powerlifting":
            generatePowerliftingProgram()
        case "power_building":
            generatePowerBuildingProgram()
        case "bodybuilding":
            generateBodybuildingProgram()
        case "functional_fitness":
            generateFunctionalFitnessProgram()
        case "bodybuilder":
            generateBodybuilderProgram()
        default:
            setPushPullLegsProgram()
        }

        // Apply bodybuilder mini if active
        if bodybuilderMiniActive {
            applyBodybuilderMini()
        }
    }

    private func generateOptimalProgram() {
        // Optimal: Balanced approach - 3-4 days/week, moderate intensity
        let daysPerWeek = calculateModulatedDays(frequencyModulation * 1.0) // Balanced
        let intensity = volumeIntensityModulation

        weeklySchedule = generateBalancedSchedule(days: Int(daysPerWeek), intensity: intensity)
    }

    private func generateTimeCrunchedProgram() {
        // Time Crunched: Short sessions, high intensity, variable frequency
        let daysPerWeek = calculateModulatedDays(frequencyModulation * 0.7) // More frequent
        let intensity = volumeIntensityModulation * 1.3 // Higher intensity

        weeklySchedule = generateHighIntensitySchedule(days: Int(daysPerWeek), intensity: intensity)
    }

    private func generateWeekendWarriorProgram() {
        // Weekend Warrior: Infrequent, long sessions, high intensity
        let daysPerWeek = calculateModulatedDays(frequencyModulation * 0.6) // Less frequent
        let intensity = volumeIntensityModulation * 1.4 // Very high intensity

        weeklySchedule = generateLowFrequencyHighIntensitySchedule(days: Int(max(2, daysPerWeek)), intensity: intensity)
    }

    private func generateLongevityProgram() {
        // Longevity: Safety-focused, recovery-oriented, lower intensity
        let daysPerWeek = calculateModulatedDays(frequencyModulation * 0.8) // Moderate frequency
        let intensity = volumeIntensityModulation * 0.7 // Lower intensity

        weeklySchedule = generateRecoveryFocusedSchedule(days: Int(daysPerWeek), intensity: intensity)
    }

    private func generateStrengthProgram() {
        // Strength: Heavy lifting, low reps, compound focus
        let daysPerWeek = calculateModulatedDays(frequencyModulation * 0.9)
        let intensity = volumeIntensityModulation * 0.6 // Lower volume, high intensity

        weeklySchedule = generateStrengthFocusedSchedule(days: Int(daysPerWeek), intensity: intensity)
    }

    private func generateWeightLifterProgram() {
        // Weight Lifter: Olympic-style training
        let daysPerWeek = calculateModulatedDays(frequencyModulation * 0.8)
        let intensity = volumeIntensityModulation * 0.8

        weeklySchedule = generateOlympicStyleSchedule(days: Int(daysPerWeek), intensity: intensity)
    }

    private func generatePowerliftingProgram() {
        // Powerlifting: Main lifts focus, low frequency
        let daysPerWeek = calculateModulatedDays(frequencyModulation * 0.7)
        let intensity = volumeIntensityModulation * 0.5 // Very high intensity

        weeklySchedule = generatePowerliftingSchedule(days: Int(daysPerWeek), intensity: intensity)
    }

    private func generatePowerBuildingProgram() {
        // Power Building: Hybrid strength and speed
        let daysPerWeek = calculateModulatedDays(frequencyModulation * 0.85)
        let intensity = volumeIntensityModulation * 0.7

        weeklySchedule = generatePowerBuildingSchedule(days: Int(daysPerWeek), intensity: intensity)
    }

    private func generateBodybuildingProgram() {
        // Bodybuilding: High volume hypertrophy
        let daysPerWeek = calculateModulatedDays(frequencyModulation * 1.1)
        let intensity = volumeIntensityModulation * 1.2 // High volume

        weeklySchedule = generateHypertrophySchedule(days: Int(daysPerWeek), intensity: intensity)
    }

    private func generateFunctionalFitnessProgram() {
        // Functional Fitness: Multi-joint movements
        let daysPerWeek = calculateModulatedDays(frequencyModulation * 0.95)
        let intensity = volumeIntensityModulation * 1.1

        weeklySchedule = generateFunctionalFitnessSchedule(days: Int(daysPerWeek), intensity: intensity)
    }

    private func generateBodybuilderProgram() {
        // Bodybuilder Maximum: All precautions thrown out for max hypertrophy
        let daysPerWeek = calculateModulatedDays(frequencyModulation * 1.2)
        let intensity = volumeIntensityModulation * 1.4 // Maximum volume

        weeklySchedule = generateMaximumHypertrophySchedule(days: Int(daysPerWeek), intensity: intensity)
    }

    // Calculate training days per week based on frequency modulation
    private func calculateModulatedDays(_ frequencyMod: Double) -> Double {
        let baseDays = 4.0
        let modulation = (frequencyMod - 50.0) / 50.0 // Convert to -1 to +1 scale
        let modulatedDays = baseDays + (modulation * 2.0) // ±2 days variation
        return max(2.0, min(6.0, modulatedDays))
    }

    // Rep range modulation helper
    private func modulateReps(_ baseReps: String, _ repModulation: Double) -> String {
        let modulation = (repModulation - 50.0) / 50.0 // Convert to -1 to +1 scale
        let parts = baseReps.split(separator: "-").map { String($0) }

        if parts.count == 2, let low = Int(parts[0]), let high = Int(parts[1]) {
            let range = high - low
            let newLow = max(1, Int(Double(low) + modulation * Double(range) * 0.5))
            let newHigh = max(newLow + 3, Int(Double(high) + modulation * Double(range) * 0.5))
            return "\(newLow)-\(newHigh)"
        }

        return baseReps
    }

    // Apply bodybuilder mini (additional hypertrophy exercises)
    private func applyBodybuilderMini() {
        for i in 0..<weeklySchedule.count {
            // Add isolation exercises based on the main lifts in each workout
            var additionalExercises = [String]()

            for mainExercise in weeklySchedule[i].exercises {
                switch mainExercise.lowercased() {
                case let ex where ex.contains("bench"):
                    additionalExercises.append("Cable Flyes 3x12-15")
                case let ex where ex.contains("squat"):
                    additionalExercises.append("Leg Extensions 3x15-20")
                case let ex where ex.contains("press"):
                    additionalExercises.append("Tricep Extensions 3x12-15")
                case let ex where ex.contains("pull"):
                    additionalExercises.append("Bicep Curls 3x12-15")
                default:
                    break
                }
            }

            weeklySchedule[i].exercises.append(contentsOf: additionalExercises)
            weeklySchedule[i].estimatedDuration += 15 // Extra 15 minutes
        }
    }

    // Schedule generation helpers
    private func generateBalancedSchedule(days: Int, intensity: Double) -> [ScheduledWorkout] {
        let daysOfWeek = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        var schedule = [ScheduledWorkout]()

        for i in 0..<days {
            let dayIndex = i % daysOfWeek.count
            let exercises = [
                "Squats \(modulateReps("8-12", repRangeModulation))",
                "Bench Press \(modulateReps("8-12", repRangeModulation))",
                "Bent-over Rows \(modulateReps("8-12", repRangeModulation))",
                "Overhead Press \(modulateReps("10-15", repRangeModulation))"
            ]

            schedule.append(ScheduledWorkout(
                dayOfWeek: daysOfWeek[dayIndex],
                workoutType: "Balanced Training",
                exercises: exercises,
                estimatedDuration: 60
            ))
        }

        return schedule
    }

    private func generateHighIntensitySchedule(days: Int, intensity: Double) -> [ScheduledWorkout] {
        let daysOfWeek = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        var schedule = [ScheduledWorkout]()

        for i in 0..<days {
            let dayIndex = i % daysOfWeek.count
            let exercises = [
                "Squats \(modulateReps("5-8", repRangeModulation))",
                "Bench Press \(modulateReps("5-8", repRangeModulation))",
                "Pull-ups \(modulateReps("6-10", repRangeModulation))"
            ]

            schedule.append(ScheduledWorkout(
                dayOfWeek: daysOfWeek[dayIndex],
                workoutType: "High Intensity",
                exercises: exercises,
                estimatedDuration: 45
            ))
        }

        return schedule
    }

    private func generateLowFrequencyHighIntensitySchedule(days: Int, intensity: Double) -> [ScheduledWorkout] {
        let workoutDays = ["Saturday", "Sunday"] // Weekend focused
        var schedule = [ScheduledWorkout]()

        for i in 0..<min(days, workoutDays.count) {
            let exercises = [
                "Squats \(modulateReps("4-6", repRangeModulation))",
                "Bench Press \(modulateReps("4-6", repRangeModulation))",
                "Deadlifts \(modulateReps("4-6", repRangeModulation))",
                "Overhead Press \(modulateReps("6-8", repRangeModulation))",
                "Pull-ups \(modulateReps("6-8", repRangeModulation))"
            ]

            schedule.append(ScheduledWorkout(
                dayOfWeek: workoutDays[i],
                workoutType: "Weekend Warrior",
                exercises: exercises,
                estimatedDuration: 90
            ))
        }

        return schedule
    }

    private func generateRecoveryFocusedSchedule(days: Int, intensity: Double) -> [ScheduledWorkout] {
        let daysOfWeek = ["Monday", "Wednesday", "Friday"]
        var schedule = [ScheduledWorkout]()

        for i in 0..<min(days, daysOfWeek.count) {
            let exercises = [
                "Goblet Squats \(modulateReps("12-15", repRangeModulation))",
                "Dumbbell Press \(modulateReps("12-15", repRangeModulation))",
                "Lat Pulldowns \(modulateReps("12-15", repRangeModulation))",
                "Planks 3x30s"
            ]

            schedule.append(ScheduledWorkout(
                dayOfWeek: daysOfWeek[i],
                workoutType: "Recovery Focused",
                exercises: exercises,
                estimatedDuration: 50
            ))
        }

        return schedule
    }

    private func generateStrengthFocusedSchedule(days: Int, intensity: Double) -> [ScheduledWorkout] {
        let daysOfWeek = ["Monday", "Thursday"]
        var schedule = [ScheduledWorkout]()

        for i in 0..<min(days, daysOfWeek.count) {
            let exercises = [
                "Squats \(modulateReps("4-6", repRangeModulation))",
                "Bench Press \(modulateReps("4-6", repRangeModulation))",
                "Deadlifts \(modulateReps("4-6", repRangeModulation))",
                "Overhead Press \(modulateReps("4-6", repRangeModulation))"
            ]

            schedule.append(ScheduledWorkout(
                dayOfWeek: daysOfWeek[i],
                workoutType: "Strength Training",
                exercises: exercises,
                estimatedDuration: 75
            ))
        }

        return schedule
    }

    private func generateOlympicStyleSchedule(days: Int, intensity: Double) -> [ScheduledWorkout] {
        let daysOfWeek = ["Monday", "Wednesday", "Friday"]
        var schedule = [ScheduledWorkout]()

        for i in 0..<min(days, daysOfWeek.count) {
            let exercises = [
                "Hang Power Cleans \(modulateReps("5-8", repRangeModulation))",
                "Front Squats \(modulateReps("5-8", repRangeModulation))",
                "Push Press \(modulateReps("5-8", repRangeModulation))",
                "Snatches \(modulateReps("4-6", repRangeModulation))"
            ]

            schedule.append(ScheduledWorkout(
                dayOfWeek: daysOfWeek[i],
                workoutType: "Olympic Lifting",
                exercises: exercises,
                estimatedDuration: 90
            ))
        }

        return schedule
    }

    private func generatePowerliftingSchedule(days: Int, intensity: Double) -> [ScheduledWorkout] {
        let daysOfWeek = ["Monday", "Wednesday", "Friday"]
        var schedule = [ScheduledWorkout]()

        for i in 0..<min(days, daysOfWeek.count) {
            let exercises = [
                "Squats \(modulateReps("3-5", repRangeModulation))",
                "Bench Press \(modulateReps("3-5", repRangeModulation))",
                "Deadlifts \(modulateReps("3-5", repRangeModulation))"
            ]

            schedule.append(ScheduledWorkout(
                dayOfWeek: daysOfWeek[i],
                workoutType: "Powerlifting",
                exercises: exercises,
                estimatedDuration: 80
            ))
        }

        return schedule
    }

    private func generatePowerBuildingSchedule(days: Int, intensity: Double) -> [ScheduledWorkout] {
        let daysOfWeek = ["Monday", "Tuesday", "Thursday", "Friday"]
        var schedule = [ScheduledWorkout]()

        for i in 0..<min(days, daysOfWeek.count) {
            let exercises: [String]
            if i % 2 == 0 {
                // Heavy day
                exercises = [
                    "Squats \(modulateReps("4-6", repRangeModulation))",
                    "Bench Press \(modulateReps("4-6", repRangeModulation))",
                    "Deadlifts \(modulateReps("4-6", repRangeModulation))"
                ]
            } else {
                // Speed day
                exercises = [
                    "Box Squats \(modulateReps("6-8", repRangeModulation))",
                    "Close Grip Bench \(modulateReps("6-8", repRangeModulation))",
                    "Snatch Grip Pulls \(modulateReps("6-8", repRangeModulation))"
                ]
            }

            schedule.append(ScheduledWorkout(
                dayOfWeek: daysOfWeek[i],
                workoutType: "Power Building",
                exercises: exercises,
                estimatedDuration: 70
            ))
        }

        return schedule
    }

    private func generateHypertrophySchedule(days: Int, intensity: Double) -> [ScheduledWorkout] {
        let bodyParts = ["Chest", "Back", "Legs", "Shoulders", "Arms"]
        var schedule = [ScheduledWorkout]()
        let daysOfWeek = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

        for i in 0..<days {
            let focusArea = bodyParts[i % bodyParts.count]
            var exercises = [String]()

            switch focusArea {
            case "Chest":
                exercises = [
                    "Bench Press \(modulateReps("8-12", repRangeModulation))",
                    "Incline Dumbbell Press \(modulateReps("8-12", repRangeModulation))",
                    "Cable Flyes \(modulateReps("10-15", repRangeModulation))"
                ]
            case "Back":
                exercises = [
                    "Pull-ups \(modulateReps("8-12", repRangeModulation))",
                    "Lat Pulldowns \(modulateReps("10-15", repRangeModulation))",
                    "Bent-over Rows \(modulateReps("8-12", repRangeModulation))"
                ]
            case "Legs":
                exercises = [
                    "Squats \(modulateReps("8-12", repRangeModulation))",
                    "Leg Press \(modulateReps("10-15", repRangeModulation))",
                    "Leg Extensions \(modulateReps("12-15", repRangeModulation))"
                ]
            case "Shoulders":
                exercises = [
                    "Overhead Press \(modulateReps("8-12", repRangeModulation))",
                    "Lateral Raises \(modulateReps("10-15", repRangeModulation))",
                    "Rear Delt Flyes \(modulateReps("10-15", repRangeModulation))"
                ]
            case "Arms":
                exercises = [
                    "Barbell Curls \(modulateReps("8-12", repRangeModulation))",
                    "Tricep Extensions \(modulateReps("10-15", repRangeModulation))",
                    "Hammer Curls \(modulateReps("10-15", repRangeModulation))"
                ]
            default:
                exercises = ["Bench Press \(modulateReps("8-12", repRangeModulation))"]
            }

            schedule.append(ScheduledWorkout(
                dayOfWeek: daysOfWeek[i % daysOfWeek.count],
                workoutType: "\(focusArea) Hypertrophy",
                exercises: exercises,
                estimatedDuration: 60
            ))
        }

        return schedule
    }

    private func generateFunctionalFitnessSchedule(days: Int, intensity: Double) -> [ScheduledWorkout] {
        let daysOfWeek = ["Monday", "Tuesday", "Wednesday", "Thursday", "Saturday"]
        var schedule = [ScheduledWorkout]()

        for i in 0..<min(days, daysOfWeek.count) {
            let exercises = [
                "Burpees \(modulateReps("8-12", repRangeModulation))",
                "Kettlebell Swings \(modulateReps("10-15", repRangeModulation))",
                "Box Jumps \(modulateReps("8-12", repRangeModulation))",
                "Farmer's Walk 4x30m",
                "Medicine Ball Slams \(modulateReps("8-12", repRangeModulation))"
            ]

            schedule.append(ScheduledWorkout(
                dayOfWeek: daysOfWeek[i],
                workoutType: "Functional Fitness",
                exercises: exercises,
                estimatedDuration: 50
            ))
        }

        return schedule
    }

    private func generateMaximumHypertrophySchedule(days: Int, intensity: Double) -> [ScheduledWorkout] {
        let bodyParts = ["Chest", "Back", "Legs", "Shoulders", "Arms"]
        var schedule = [ScheduledWorkout]()
        let daysOfWeek = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

        for i in 0..<days {
            let focusArea1 = bodyParts[i % bodyParts.count]
            let focusArea2 = bodyParts[(i + 1) % bodyParts.count]
            var exercises = [String]()

            // Primary focus area
            switch focusArea1 {
            case "Chest":
                exercises.append(contentsOf: [
                    "Bench Press \(modulateReps("6-10", repRangeModulation))",
                    "Incline Bench Press \(modulateReps("8-12", repRangeModulation))",
                    "Decline Bench Press \(modulateReps("8-12", repRangeModulation))",
                    "Cable Flyes \(modulateReps("10-15", repRangeModulation))",
                    "Push-ups \(modulateReps("15-20", repRangeModulation))"
                ])
            case "Back":
                exercises.append(contentsOf: [
                    "Pull-ups \(modulateReps("6-10", repRangeModulation))",
                    "Lat Pulldowns \(modulateReps("8-12", repRangeModulation))",
                    "Bent-over Rows \(modulateReps("8-12", repRangeModulation))",
                    "Seated Cable Rows \(modulateReps("10-15", repRangeModulation))",
                    "Face Pulls \(modulateReps("12-15", repRangeModulation))"
                ])
            case "Legs":
                exercises.append(contentsOf: [
                    "Squats \(modulateReps("8-12", repRangeModulation))",
                    "Leg Press \(modulateReps("10-15", repRangeModulation))",
                    "Lunges \(modulateReps("10-15", repRangeModulation))",
                    "Leg Extensions \(modulateReps("12-15", repRangeModulation))",
                    "Leg Curls \(modulateReps("12-15", repRangeModulation))"
                ])
            default:
                exercises.append("Rest and Recovery Day")
            }

            // Secondary focus area
            switch focusArea2 {
            case "Shoulders":
                exercises.append("Overhead Press \(modulateReps("8-12", repRangeModulation))")
                exercises.append("Lateral Raises \(modulateReps("10-15", repRangeModulation))")
            case "Arms":
                exercises.append("Bicep Curls \(modulateReps("8-12", repRangeModulation))")
                exercises.append("Tricep Extensions \(modulateReps("10-15", repRangeModulation))")
            default:
                break
            }

            schedule.append(ScheduledWorkout(
                dayOfWeek: daysOfWeek[i % daysOfWeek.count],
                workoutType: "Maximum Hypertrophy",
                exercises: exercises,
                estimatedDuration: 90
            ))
        }

        return schedule
    }
