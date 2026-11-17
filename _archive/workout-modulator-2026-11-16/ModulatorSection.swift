// Archived 2026-11-16 from the Programs page.
// What it did: the three sliders only fed WorkoutManager.generateProgramWithPreset, which runs
// only when a preset button is tapped; each preset then REPLACED the current program (no confirm)
// with a legacy 4-exercise Monday-Saturday schedule. The sliders alone changed nothing, and the
// presets duplicated the Program Wizard / Smart Advisor and the catalog with worse output.
// The WorkoutManager preset/modulation code it drove is archived beside it (WorkoutManagerPresets-removed.swift).

struct ModulatorSection: View {
    @EnvironmentObject var workoutManager: WorkoutManager

    private static let presets: [(title: String, subtitle: String, icon: String, preset: String)] = [
        ("Optimal", "Balanced approach", "⚖️", "optimal"),
        ("Time Crunched", "Short, intense sessions", "⏱️", "time_crunched"),
        ("Weekend Warrior", "Infrequent, long sessions", "🏔️", "weekend_warrior"),
        ("Longevity", "Safety-focused, recovery", "🛡️", "longevity"),
        ("Strength", "Heavy lifting, low reps", "💪", "strength"),
        ("Weight Lifter", "Olympic-style training", "🏋️", "weight_lifter"),
        ("Powerlifting", "Main lifts focus", "🐘", "powerlifting"),
        ("Power Building", "Hybrid strength/speed", "⚡", "power_building"),
        ("Bodybuilding", "High volume hypertrophy", "🏆", "bodybuilding"),
        ("Functional Fitness", "Multi-joint movements", "🤸", "functional_fitness"),
        ("Bodybuilder MAX", "Precautions thrown out", "🔥", "bodybuilder"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("🎛️ Workout Modulator")
                .font(.title2)
                .bold()
            Text("Fine-tune your training approach")
                .font(.caption)
                .foregroundColor(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250))], spacing: 16) {
                modSlider(value: $workoutManager.repRangeModulation, icon: "repeat", color: .brandBlue,
                          title: "Rep Range (Safe to Maximal)", low: "Safer", high: "Maximal")
                modSlider(value: $workoutManager.volumeIntensityModulation, icon: "chart.bar.fill", color: .brandGreen,
                          title: "Volume vs Intensity", low: "Volume", high: "Intensity")
                modSlider(value: $workoutManager.frequencyModulation, icon: "calendar.badge.clock", color: .brandOrange,
                          title: "Training Frequency", low: "Often", high: "Sparingly")
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("🎯 Bodybuilder Mini")
                    .font(.subheadline)
                    .bold()
                Toggle("Add intense hypertrophy exercises to any program", isOn: $workoutManager.bodybuilderMiniActive)
                    .toggleStyle(.switch)
                    .tint(.brandOrange)
            }
            .padding()
            .background(Color.orange.opacity(0.1))
            .cornerRadius(12)

            VStack(alignment: .leading, spacing: 16) {
                Text("🎯 Training Presets")
                    .font(.title2)
                    .bold()
                Text("Choose your training style to auto-adjust modulation settings")
                    .font(.caption)
                    .foregroundColor(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], spacing: 12) {
                    ForEach(Self.presets, id: \.preset) { p in
                        PresetButton(title: p.title, subtitle: p.subtitle, icon: p.icon,
                                     preset: p.preset, workoutManager: workoutManager)
                    }
                }
            }
            .padding()
            .background(Color.brandPurple.opacity(0.1))
            .cornerRadius(12)
        }
    }

    private func modSlider(value: Binding<Double>, icon: String, color: Color, title: String, low: String, high: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: icon).foregroundColor(color)
                Text(title).font(.subheadline).bold()
            }
            VStack {
                Slider(value: value, in: 0...100, step: 5).tint(color)
                HStack {
                    Text(low).font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(value.wrappedValue))%").font(.headline)
                    Spacer()
                    Text(high).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }
}

struct PresetButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let preset: String
    let workoutManager: WorkoutManager

    @State private var isHovering = false

    var body: some View {
        Button(action: {
            workoutManager.generateProgramWithPreset(preset: preset)
        }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Text(icon)
                        .font(.title)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline)
                            .bold()
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(Color.gray.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.blue, lineWidth: 1)
            )
            .cornerRadius(12)
            .scaleEffect(isHovering ? 1.02 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.2)) {
                isHovering = hovering
            }
        }
    }
}

