export interface Preset {
  id: string;
  name: string;
  repRangeBase: number;
  volumeIntensityBase: number;
  frequencyBase: number;
  description: string;
  focus: string;
}

export const PRESETS: Record<string, Omit<Preset, 'id' | 'name'>> = {
  optimal: { repRangeBase: 50, volumeIntensityBase: 50, frequencyBase: 50, description: "Balanced approach for general fitness and performance.", focus: "balanced" },
  time_crunched: { repRangeBase: 30, volumeIntensityBase: 70, frequencyBase: 70, description: "Short, high-intensity sessions for busy schedules.", focus: "intensity" },
  weekend_warrior: { repRangeBase: 60, volumeIntensityBase: 60, frequencyBase: 80, description: "Infrequent intense workouts for weekends.", focus: "intensity" },
  longevity: { repRangeBase: 20, volumeIntensityBase: 40, frequencyBase: 30, description: "Safety-focused, recovery-oriented for long-term health.", focus: "recovery" },
  strength: { repRangeBase: 80, volumeIntensityBase: 20, frequencyBase: 60, description: "Heavy lifting, low reps for strength gains.", focus: "strength" },
  weight_lifter: { repRangeBase: 70, volumeIntensityBase: 30, frequencyBase: 70, description: "Olympic-style lifting focus.", focus: "technical" },
  powerlifting: { repRangeBase: 85, volumeIntensityBase: 15, frequencyBase: 65, description: "Competitive powerlifting emphasis on main lifts.", focus: "strength" },
  power_building: { repRangeBase: 75, volumeIntensityBase: 25, frequencyBase: 60, description: "Hybrid strength and speed training.", focus: "power" },
  bodybuilding: { repRangeBase: 40, volumeIntensityBase: 80, frequencyBase: 40, description: "High volume for muscle hypertrophy.", focus: "hypertrophy" },
  functional_fitness: { repRangeBase: 50, volumeIntensityBase: 60, frequencyBase: 50, description: "Multi-joint movements for practical strength.", focus: "functional" },
  bodybuilder: { repRangeBase: 35, volumeIntensityBase: 85, frequencyBase: 35, description: "Maximum hypertrophy focus.", focus: "hypertrophy" }
};

export interface Exercise {
  name: string;
  type: string;
  muscleGroups: string[];
  difficulty: string;
}

export const EXERCISE_DATABASE: Record<string, Exercise> = {
  squats: { name: "Squats", type: "compound", muscleGroups: ["quads", "glutes", "hamstrings"], difficulty: "intermediate" },
  deadlifts: { name: "Deadlifts", type: "compound", muscleGroups: ["hamstrings", "glutes", "back"], difficulty: "advanced" },
  benchPress: { name: "Bench Press", type: "compound", muscleGroups: ["chest", "triceps", "shoulders"], difficulty: "intermediate" },
  overheadPress: { name: "Overhead Press", type: "compound", muscleGroups: ["shoulders", "triceps"], difficulty: "intermediate" },
  pullUps: { name: "Pull-ups", type: "compound", muscleGroups: ["back", "biceps"], difficulty: "intermediate" },
  rows: { name: "Bent-over Rows", type: "compound", muscleGroups: ["back", "biceps"], difficulty: "intermediate" },
  bicepCurls: { name: "Bicep Curls", type: "isolation", muscleGroups: ["biceps"], difficulty: "beginner" },
  tricepExtensions: { name: "Tricep Extensions", type: "isolation", muscleGroups: ["triceps"], difficulty: "beginner" },
  lateralRaises: { name: "Lateral Raises", type: "isolation", muscleGroups: ["shoulders"], difficulty: "beginner" },
  legPress: { name: "Leg Press", type: "compound", muscleGroups: ["quads", "glutes"], difficulty: "beginner" },
  legCurls: { name: "Leg Curls", type: "isolation", muscleGroups: ["hamstrings"], difficulty: "beginner" },
  calfRaises: { name: "Calf Raises", type: "isolation", muscleGroups: ["calves"], difficulty: "beginner" },
  burpees: { name: "Burpees", type: "functional", muscleGroups: ["full_body"], difficulty: "intermediate" },
  kettlebellSwings: { name: "Kettlebell Swings", type: "functional", muscleGroups: ["glutes", "hamstrings"], difficulty: "intermediate" },
  farmerWalks: { name: "Farmer's Walk", type: "functional", muscleGroups: ["grip", "core"], difficulty: "intermediate" }
};

export const TALENT_TREE_DATA = {
  categories: {
    volume: { name: 'Volume', icon: '📊', color: '#007AFF', description: 'Increase training volume and work capacity' },
    intensity: { name: 'Intensity', icon: '⚡', color: '#FF3B30', description: 'Focus on heavy loads and power development' },
    frequency: { name: 'Frequency', icon: '📅', color: '#34C759', description: 'Train more often with optimized scheduling' },
    technique: { name: 'Technique', icon: '🎯', color: '#5856D6', description: 'Perfect form and mind-muscle connection' },
    recovery: { name: 'Recovery', icon: '💤', color: '#FF9500', description: 'Enhanced rest and deload protocols' }
  },
  talents: [
    { id: 'vol_baseline', name: 'Volume Foundation', description: '+10% total sets per workout', category: 'volume', icon: '📊', maxRank: 3, prerequisites: [] },
    { id: 'vol_high', name: 'High Volume', description: '+20% total sets, best for hypertrophy', category: 'volume', icon: '📈', maxRank: 5, prerequisites: ['vol_baseline'] },
    { id: 'vol_super', name: 'Super Volume', description: '+10% additional sets, elite recovery required', category: 'volume', icon: '📉', maxRank: 3, prerequisites: ['vol_high'] },
    { id: 'int_baseline', name: 'Intensity Foundation', description: '+5% working weight on compounds', category: 'intensity', icon: '⚡', maxRank: 3, prerequisites: [] },
    { id: 'int_heavy', description: '-20% reps, +15% weight, lower rep ranges', name: 'Heavy Lifting', category: 'intensity', icon: '🔥', maxRank: 5, prerequisites: ['int_baseline'] },
    { id: 'int_explosive', name: 'Explosive Power', description: 'Olympic lift variations, speed-focused', category: 'intensity', icon: '💥', maxRank: 3, prerequisites: ['int_heavy'] },
    { id: 'freq_baseline', name: 'Training Frequency', description: 'Optimized rest days, consistent schedule', category: 'frequency', icon: '📅', maxRank: 3, prerequisites: [] },
    { id: 'freq_high', name: 'High Frequency', description: '+1 training day per week', category: 'frequency', icon: '📆', maxRank: 3, prerequisites: ['freq_baseline'] },
    { id: 'freq_split', name: 'Advanced Split', description: 'Push/Pull/Legs 6-day split', category: 'frequency', icon: '🔀', maxRank: 2, prerequisites: ['freq_high'] },
    { id: 'tech_baseline', name: 'Form Focus', description: 'Slower rep tempo, perfect technique', category: 'technique', icon: '🎯', maxRank: 3, prerequisites: [] },
    { id: 'tech_compound', name: 'Compound Mastery', description: 'Prioritize big 3: squat/bench/deadlift', category: 'technique', icon: '🏋️', maxRank: 3, prerequisites: ['tech_baseline'] },
    { id: 'tech_isolation', name: 'Isolation Expert', description: 'More single-joint movements', category: 'technique', icon: '💪', maxRank: 3, prerequisites: ['tech_baseline'] },
    { id: 'rec_baseline', name: 'Recovery Protocol', description: '+30s rest between sets', category: 'recovery', icon: '💤', maxRank: 3, prerequisites: [] },
    { id: 'rec_active', name: 'Active Recovery', description: 'Light cardio on rest days', category: 'recovery', icon: '🚶', maxRank: 2, prerequisites: ['rec_baseline'] },
    { id: 'rec_deload', name: 'Smart Deloading', description: 'Auto deload every 3rd week at 60%', category: 'recovery', icon: '📉', maxRank: 3, prerequisites: ['rec_baseline'] }
  ]
};
