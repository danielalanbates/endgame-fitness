import React, { useState, useEffect } from 'react';
import './App.css';
import { PRESETS, EXERCISE_DATABASE, TALENT_TREE_DATA } from './data/constants';
import AICoachCamera from './components/AICoachCamera';
import { authService, User } from './services/auth';

interface Exercise {
  name: string;
  sets: number;
  reps: number;
  weight: string;
  completed?: boolean[];
}

interface Workout {
  id: string;
  date: string;
  preset: string;
  exercises: Exercise[];
}

interface UserTalent {
  id: string;
  rank: number;
}

interface AppData {
  currentPreset: string | null;
  repRange: number;
  volumeIntensity: number;
  frequency: number;
  bodybuilderMiniActive: boolean;
  workoutHistory: Workout[];
  currentStreak: number;
  totalVolume: number;
  talentPoints: number;
  spentTalents: UserTalent[];
}

const App: React.FC = () => {
  // State
  const [currentPreset, setCurrentPreset] = useState<string | null>(null);
  const [repRange, setRepRange] = useState(50);
  const [volumeIntensity, setVolumeIntensity] = useState(50);
  const [frequency, setFrequency] = useState(50);
  const [bodybuilderMiniActive, setBodybuilderMiniActive] = useState(false);
  const [currentWorkout, setCurrentWorkout] = useState<Workout | null>(null);
  const [history, setHistory] = useState<Workout[]>([]);
  const [talentPoints, setTalentPoints] = useState(5);
  const [spentTalents, setSpentTalents] = useState<UserTalent[]>([]);
  
  // Stats
  const [currentStreak, setCurrentStreak] = useState(0);
  const [totalVolume, setTotalVolume] = useState(0);

  // AI Camera State
  const [activeCameraExercise, setActiveCameraExercise] = useState<string | null>(null);

  // Auth State
  const [user, setUser] = useState<User | null>(null);
  const [isAuthLoading, setIsAuthLoading] = useState(true);

  // Load Data
  useEffect(() => {
    authService.init();
    setUser(authService.state.user);
    setIsAuthLoading(false);

    const saved = localStorage.getItem('endgameFitnessData');
    if (saved) {
      const data: AppData = JSON.parse(saved);
      setCurrentPreset(data.currentPreset);
      setRepRange(data.repRange);
      setVolumeIntensity(data.volumeIntensity);
      setFrequency(data.frequency);
      setBodybuilderMiniActive(data.bodybuilderMiniActive);
      setHistory(data.workoutHistory || []);
      setCurrentStreak(data.currentStreak || 0);
      setTotalVolume(data.totalVolume || 0);
      setTalentPoints(data.talentPoints ?? 5);
      setSpentTalents(data.spentTalents || []);
    }
  }, []);

  const handleLogin = async () => {
    setIsAuthLoading(true);
    const result = await authService.loginWithGoogle();
    if (result.success) {
      setUser(result.user || null);
    }
    setIsAuthLoading(false);
  };

  const handleLogout = () => {
    authService.logout();
    setUser(null);
  };

  // Save Data
  const persist = (updates: Partial<AppData>) => {
    const data: AppData = {
      currentPreset,
      repRange,
      volumeIntensity,
      frequency,
      bodybuilderMiniActive,
      workoutHistory: history,
      currentStreak,
      totalVolume,
      talentPoints,
      spentTalents,
      ...updates
    };
    localStorage.setItem('endgameFitnessData', JSON.stringify(data));
  };

  const handlePresetSelect = (id: string) => {
    const preset = PRESETS[id];
    setCurrentPreset(id);
    setRepRange(preset.repRangeBase);
    setVolumeIntensity(preset.volumeIntensityBase);
    setFrequency(preset.frequencyBase);
    persist({ 
      currentPreset: id, 
      repRange: preset.repRangeBase, 
      volumeIntensity: preset.volumeIntensityBase, 
      frequency: preset.frequencyBase 
    });
  };

  const buyTalent = (talentId: string) => {
    const talent = TALENT_TREE_DATA.talents.find(t => t.id === talentId);
    if (!talent || talentPoints <= 0) return;

    const existing = spentTalents.find(t => t.id === talentId);
    if (existing && existing.rank >= talent.maxRank) return;

    // Check prerequisites
    const unmetPrereq = talent.prerequisites.some(pId => {
      const p = spentTalents.find(st => st.id === pId);
      return !p || p.rank === 0;
    });
    if (unmetPrereq) return;

    let newSpent;
    if (existing) {
      newSpent = spentTalents.map(t => t.id === talentId ? { ...t, rank: t.rank + 1 } : t);
    } else {
      newSpent = [...spentTalents, { id: talentId, rank: 1 }];
    }

    setSpentTalents(newSpent);
    setTalentPoints(talentPoints - 1);
    persist({ spentTalents: newSpent, talentPoints: talentPoints - 1 });
  };

  const generateWorkout = () => {
    if (!currentPreset) return;

    const exercises = Object.values(EXERCISE_DATABASE);
    const count = Math.floor(4 + (frequency / 25));
    const selected = exercises.sort(() => 0.5 - Math.random()).slice(0, count);

    const generatedExercises: Exercise[] = selected.map(ex => {
      let sets = Math.floor(3 + (volumeIntensity / 30));
      let reps = Math.floor(8 + (repRange / 12));
      
      // Apply talent modifiers
      if (spentTalents.some(t => t.id === 'vol_baseline')) sets += 1;
      if (bodybuilderMiniActive) sets += 2;

      return {
        name: ex.name,
        sets,
        reps,
        weight: 'TBD',
        completed: new Array(sets).fill(false)
      };
    });

    const workout: Workout = {
      id: Date.now().toString(),
      date: new Date().toLocaleDateString(),
      preset: currentPreset,
      exercises: generatedExercises
    };

    setCurrentWorkout(workout);
  };

  const toggleSet = (exIndex: number, setIndex: number) => {
    if (!currentWorkout) return;
    const newWorkout = { ...currentWorkout };
    const exercise = newWorkout.exercises[exIndex];
    exercise.completed![setIndex] = !exercise.completed![setIndex];
    
    // AI Adjustment Logic: If a user completes all sets easily, suggest more intensity
    const completedSets = exercise.completed!.filter(c => c).length;
    if (completedSets === exercise.sets) {
      console.log(`[${user?.selectedModel || 'Cerebras'} Recommendation]: User completed all sets of ${exercise.name}. Suggesting +5% weight for next session.`);
      // In a real app, this would update the user's "progression" state
    }

    setCurrentWorkout(newWorkout);
  };

  const finishWorkout = () => {
    if (!currentWorkout) return;
    const newHistory = [currentWorkout, ...history];
    setHistory(newHistory);
    setCurrentWorkout(null);
    setCurrentStreak(currentStreak + 1);
    setTotalVolume(totalVolume + 1000); // Dummy volume calc
    persist({ workoutHistory: newHistory, currentStreak: currentStreak + 1, totalVolume: totalVolume + 1000 });
  };

  return (
    <div id="app">
      <header>
        <h1>Endgame Fitness</h1>
        <div className="header-right">
          {user ? (
            <div className="user-profile">
              <span className="user-name">{user.name}</span>
              <span className={`membership-badge ${user.membership}`}>{user.membership}</span>
              <button className="text-btn" onClick={handleLogout}>Logout</button>
            </div>
          ) : (
            <button className="primary-btn login-btn" onClick={handleLogin} disabled={isAuthLoading}>
              {isAuthLoading ? 'Connecting...' : 'Login with Google'}
            </button>
          )}
          <div className="stats-bar">
            <span>🔥 {currentStreak} Day Streak</span>
            <span>💎 {talentPoints} Talent Points</span>
          </div>
        </div>
      </header>

      <main>
        {currentWorkout ? (
          <section className="active-workout card">
            <div className="card-header">
              <h3>Active Session: {currentWorkout.preset.toUpperCase()}</h3>
              <button className="text-btn" onClick={() => setCurrentWorkout(null)}>Cancel</button>
            </div>
            <div className="exercise-list">
              {currentWorkout.exercises.map((ex, i) => (
                <div key={i} className="exercise-item">
                  <div className="ex-info">
                    <strong>{ex.name}</strong>
                    <span>{ex.sets} x {ex.reps}</span>
                    <button className="text-btn camera-btn" onClick={() => setActiveCameraExercise(ex.name)}>📹 Live Coach</button>
                  </div>
                  <div className="set-bubbles">
                    {ex.completed?.map((done, si) => (
                      <div 
                        key={si} 
                        className={`bubble ${done ? 'done' : ''}`}
                        onClick={() => toggleSet(i, si)}
                      />
                    ))}
                  </div>
                </div>
              ))}
            </div>
            <button className="primary-btn" onClick={finishWorkout}>Finish Workout</button>
            {activeCameraExercise && (
              <AICoachCamera 
                exerciseName={activeCameraExercise} 
                onClose={() => setActiveCameraExercise(null)} 
              />
            )}
          </section>
        ) : (
          <>
            <section className="modulator card">
              <h3>Workout Modulator</h3>
              <div className="preset-grid">
                {Object.keys(PRESETS).map(id => (
                  <button
                    key={id}
                    className={`preset-chip ${currentPreset === id ? 'active' : ''}`}
                    onClick={() => handlePresetSelect(id)}
                  >
                    {id.replace('_', ' ')}
                  </button>
                ))}
              </div>
              
              <div className="modifier-row">
                <label className="switch">
                  <input type="checkbox" checked={bodybuilderMiniActive} onChange={(e) => {
                    setBodybuilderMiniActive(e.target.checked);
                    persist({ bodybuilderMiniActive: e.target.checked });
                  }} />
                  <span className="slider round"></span>
                </label>
                <span>Bodybuilder Mini (Hypertrophy Layer)</span>
              </div>

              <button className="primary-btn" onClick={generateWorkout} disabled={!currentPreset}>
                Start New Session
              </button>
            </section>

            <section className="talents card">
              <h3>Talent Tree</h3>
              <div className="talent-grid">
                {TALENT_TREE_DATA.talents.map(t => {
                  const userT = spentTalents.find(st => st.id === t.id);
                  const isLocked = t.prerequisites.some(pId => {
                    const p = spentTalents.find(st => st.id === pId);
                    return !p || p.rank === 0;
                  });
                  return (
                    <div 
                      key={t.id} 
                      className={`talent-card ${userT ? 'active' : ''} ${isLocked ? 'locked' : ''}`}
                      onClick={() => !isLocked && buyTalent(t.id)}
                    >
                      <span className="icon">{t.icon}</span>
                      <div className="info">
                        <strong>{t.name}</strong>
                        <span>{userT?.rank || 0} / {t.maxRank}</span>
                      </div>
                    </div>
                  );
                })}
              </div>
            </section>

            <section className="history card">
              <h3>Recent History</h3>
              {history.length === 0 ? (
                <p className="empty">No workouts logged yet.</p>
              ) : (
                <div className="history-list">
                  {history.slice(0, 3).map(w => (
                    <div key={w.id} className="history-item">
                      <span>{w.date}</span>
                      <strong>{w.preset.toUpperCase()}</strong>
                      <span>{w.exercises.length} Exercises</span>
                    </div>
                  ))}
                </div>
              )}
            </section>
          </>
        )}
      </main>
    </div>
  );
};

export default App;
