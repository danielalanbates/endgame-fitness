# 🎮 Leveling & Progression System

## Overview

The Workout Tracker now features a comprehensive RPG-style leveling system with XP progression, level-based rewards, inactivity penalties, and goal-specific talent recommendations.

---

## 🆙 Leveling System

### Core Mechanics

**Level Range**: 1-50 (Level 50 = "Legend" tier)

**XP Formula**: Exponential scaling
- Base XP: 100 for level 2
- Multiplier: 1.15× per level
- Level 10 requires: ~1,900 total XP
- Level 25 requires: ~24,500 total XP
- Level 50 requires: ~500,000+ total XP

### Level Tiers

| Level Range | Tier | Description |
|-------------|------|-------------|
| 1-10 | **Novice** | Just starting your fitness journey |
| 11-20 | **Apprentice** | Building consistency and habits |
| 21-30 | **Expert** | Experienced lifter with solid foundation |
| 31-40 | **Master** | Advanced athlete with years of training |
| 41-49 | **Elite** | Peak performance, elite dedication |
| 50 | **Legend** | The pinnacle of fitness achievement |

---

## ⭐ XP Earning System

### XP Calculation

XP = (Volume XP + Duration XP) × Quality Multiplier × Performance Multiplier

**Volume XP**: Total weight moved ÷ 100
- Example: 10,000 lbs moved = 100 XP

**Duration XP**: Workout time ÷ 3 minutes
- Example: 60-minute workout = 20 XP

**Quality Multiplier**: 0.6× to 1.0× based on feedback ratings
- Average rating of 5/5 = 1.0× multiplier
- Average rating of 3/5 = 0.8× multiplier
- Average rating of 1/5 = 0.6× multiplier

**Performance Multiplier**: 1.0× + (Streak × 0.05)
- 0-day streak: 1.0× (no bonus)
- 5-day streak: 1.25× (+25% XP)
- 10-day streak: 1.50× (+50% XP)

**XP Range**: 25-500 XP per workout
- Minimum: 25 XP (light workout, poor form)
- Average: 150-250 XP (solid workout)
- Maximum: 500 XP (heavy volume, perfect form, long streak)

### Example Calculations

**Scenario 1: Beginner Workout**
- Volume: 3,000 lbs (30 XP)
- Duration: 30 minutes (10 XP)
- Quality: 3/5 average (0.8× multiplier)
- Streak: 0 days (1.0× multiplier)
- **Total: 32 XP**

**Scenario 2: Intermediate Workout**
- Volume: 12,000 lbs (120 XP)
- Duration: 60 minutes (20 XP)
- Quality: 4/5 average (0.9× multiplier)
- Streak: 5 days (1.25× multiplier)
- **Total: 158 XP**

**Scenario 3: Advanced Workout**
- Volume: 25,000 lbs (250 XP)
- Duration: 90 minutes (30 XP)
- Quality: 5/5 average (1.0× multiplier)
- Streak: 10 days (1.50× multiplier)
- **Total: 420 XP**

---

## 🎁 Talent Point Rewards

### Points Per Level

**Standard Levels**: 1 talent point
- Levels 1, 2, 3, 4, 6, 7, 8, 9, 11-14, 16-19, etc.

**Every 5th Level**: +2 talent points (total 2)
- Levels 5, 15, 25, 35, 45

**Every 10th Level**: +3 talent points (total 3)
- Levels 10, 20, 30, 40, 50

### Total Talent Points by Level

| Level | Points Earned | Cumulative | Notes |
|-------|---------------|------------|-------|
| 1-4 | 1/level | 4 | Starting phase |
| 5 | 2 | 6 | Tier 1 milestone |
| 6-9 | 1/level | 10 | Building up |
| 10 | 3 | 13 | **Novice → Apprentice** |
| 15 | 2 | 20 | Mid-tier bonus |
| 20 | 3 | 31 | **Apprentice → Expert** |
| 25 | 2 | 42 | Mid-tier bonus |
| 30 | 3 | 54 | **Expert → Master** |
| 40 | 3 | 76 | **Master → Elite** |
| 50 | 3 | 90 | **LEGEND STATUS** |

**Max talent points at level 50**: ~90 points
- More than enough to master 2-3 specializations
- Encourages focused builds over jack-of-all-trades

---

## 📉 Degradation System

### Inactivity Penalties

**Goal**: Maintain 2+ workouts per week

| Days Inactive | XP Penalty | Effect |
|---------------|------------|--------|
| 0-7 days | 0 XP | ✅ Safe zone |
| 8-14 days | -50 XP | ⚠️ 1-2 weeks inactive |
| 15-21 days | -150 XP | ⚠️⚠️ 2-3 weeks inactive |
| 22-30 days | -300 XP | 🚨 3-4 weeks inactive |
| 31+ days | -500 XP | 🚨🚨 1+ month inactive |

### Degradation Rules

1. **XP Loss**: Applied to both current and total XP
2. **Level Down**: If total XP drops below current level threshold
3. **Talent Points**: Kept! (Don't lose allocated points)
4. **Consecutive Weeks**: Reset to 0
5. **Frequency**: Checked when user opens app

### Protection Mechanisms

- **Grace Period**: 7 days (1 week) with no penalty
- **Weekly Goal**: 2+ workouts = no degradation
- **Level Floor**: Can't go below level 1
- **XP Floor**: Can't go negative

### Example Degradation Scenarios

**Scenario 1: Minor Break**
- Level 15 with 8,500 total XP
- 10 days inactive
- Penalty: -50 XP
- New total: 8,450 XP
- **Result**: Still level 15 (no level loss)

**Scenario 2: Extended Break**
- Level 10 with 2,000 total XP
- 25 days inactive
- Penalty: -300 XP
- New total: 1,700 XP
- **Result**: Drops to level 9

**Scenario 3: Long Hiatus**
- Level 20 with 10,000 total XP
- 60 days inactive (2 months)
- Penalty: -500 XP
- New total: 9,500 XP
- **Result**: Still level 20, but close to dropping

---

## 🎯 Goal-Specific Talent Recommendations

### Talent Categories Aligned with Goals

Each talent now shows **recommended goals** in its description.

#### **Build Muscle** 💪
**Recommended Talents:**
- Volume Foundation (vol_baseline)
- High Volume (vol_high)
- Super Volume (vol_super)
- Isolation Expert (tech_isolation)
- Tempo Training (tech_tempo)
- Advanced Split (freq_split)

**Strategy**: Maximize volume and hypertrophy-focused techniques

---

#### **Get Stronger** 🏋️
**Recommended Talents:**
- Intensity Foundation (int_baseline)
- Heavy Lifting (int_heavy)
- Compound Mastery (tech_compound)
- Form Focus (tech_baseline)

**Strategy**: Focus on intensity and compound movements

---

#### **Lose Weight** 🔥
**Recommended Talents:**
- Training Frequency (freq_baseline)
- High Frequency (freq_high)
- Full Body Focus (freq_full)
- Active Recovery (rec_active)

**Strategy**: High frequency with full-body workouts and active recovery

---

#### **Improve Endurance** 🏃
**Recommended Talents:**
- Training Frequency (freq_baseline)
- High Frequency (freq_high)
- Active Recovery (rec_active)
- Recovery Protocol (rec_baseline)

**Strategy**: Frequent training with emphasis on recovery

---

#### **General Fitness** ✨
**Recommended Talents:**
- Training Frequency (freq_baseline)
- Full Body Focus (freq_full)
- Form Focus (tech_baseline)
- Recovery Protocol (rec_baseline)

**Strategy**: Balanced approach with form emphasis

---

#### **Athletic Performance** ⚡
**Recommended Talents:**
- Explosive Power (int_explosive)
- Mobility Work (rec_mobility)
- Form Focus (tech_baseline)

**Strategy**: Power development and injury prevention

---

## 🏆 Progression Milestones

### Level Milestones

**Level 10**: "Apprentice Unlocked"
- Bonus: +3 talent points
- Unlock: Advanced talent tier access

**Level 20**: "Expert Unlocked"
- Bonus: +3 talent points
- Unlock: Elite workout templates

**Level 30**: "Master Unlocked"
- Bonus: +3 talent points
- Unlock: Master-tier challenges

**Level 40**: "Elite Unlocked"
- Bonus: +3 talent points
- Unlock: Elite-only features

**Level 50**: "LEGEND STATUS"
- Bonus: +3 talent points
- Unlock: All game features, exclusive title

### Consecutive Week Milestones

**4 Weeks Active**: "Monthly Grinder" badge
**12 Weeks Active**: "Quarterly Champion" badge
**26 Weeks Active**: "Half-Year Hero" badge
**52 Weeks Active**: "Annual Legend" badge

---

## 📊 Technical Implementation

### UserProfile Fields

```swift
struct UserProfile: Codable {
    // Leveling
    var level: Int                    // Current level (1-50)
    var currentXP: Int                // XP in current level
    var totalXP: Int                  // Lifetime XP earned
    var lastWorkoutDate: Date?        // For degradation check
    var consecutiveWeeksActive: Int   // Weeks with 2+ workouts
}
```

### Key Functions

**LevelingSystem.calculateXP()**: Award XP after workout
**LevelingSystem.levelFromXP()**: Determine level from total XP
**LevelingSystem.degradationPenalty()**: Calculate inactivity penalty
**LevelingSystem.talentPointsForLevel()**: Points awarded per level
**WorkoutManager.checkAndApplyDegradation()**: Apply penalties on app launch

---

## 🎨 UI Integration Points

### ProfileView Additions

**Level Display Card:**
```
┌─────────────────────────────┐
│ ⭐ Level 15 (Apprentice)    │
│                             │
│ ▰▰▰▰▰▰▰▱▱▱▱▱▱▱▱ 45% to L16 │
│ 3,450 / 4,250 XP            │
│                             │
│ Consecutive Weeks: 8 🔥     │
└─────────────────────────────┘
```

**Degradation Warning:**
```
⚠️ 5 days since last workout!
Work out within 2 days to avoid XP loss.
```

**Level Up Notification:**
```
🎉 LEVEL UP! 🎉
You reached Level 16!
+1 Talent Point awarded
```

### SpecializationView

**Recommended Talent Badge:**
```swift
if tree.isTalentRecommended(talent.id, for: profile.primaryGoals) {
    // Show ⭐ recommended badge
}
```

---

## 🚀 Future Enhancements

### Season System (v2.0)
- 12-week seasons with leaderboards
- Season-specific cosmetic rewards
- Seasonal challenges

### Prestige System (v2.5)
- Reset to level 1 after hitting 50
- Keep talent points
- Earn prestige tokens for exclusive perks
- Prestige icon next to name

### Guild System (v3.0)
- Team up with friends
- Guild-wide XP pools
- Shared challenges
- Guild vs Guild competitions

### Achievement System
- "First Blood": Complete first workout (+50 XP)
- "Century Club": Hit 100 total workouts (+200 XP)
- "Iron Will": 30-day streak (+500 XP)
- "Volume King": Move 1,000,000 lbs total (+1000 XP)

---

## 📈 Balance Philosophy

### Design Goals

1. **Consistency Rewards**: Regular training > sporadic heroics
2. **Quality Matters**: Form and effort boost XP
3. **Natural Pace**: Average player hits level 20 in ~6 months
4. **No Pay-to-Win**: Time and effort only
5. **Forgiveness**: 7-day grace period before penalties
6. **Meaningful Choices**: Talent recommendations guide but don't force

### Leveling Pace Estimates

**Casual** (2-3 workouts/week):
- Level 10: ~3 months
- Level 20: ~8 months
- Level 30: ~18 months
- Level 50: ~4-5 years

**Dedicated** (4-5 workouts/week):
- Level 10: ~6 weeks
- Level 20: ~4 months
- Level 30: ~9 months
- Level 50: ~2-3 years

**Hardcore** (6+ workouts/week):
- Level 10: ~4 weeks
- Level 20: ~2.5 months
- Level 30: ~6 months
- Level 50: ~1.5-2 years

---

## ✅ Summary

The leveling system adds:
- **Progression**: Clear path from Novice to Legend
- **Motivation**: XP and levels create short-term goals
- **Accountability**: Degradation system encourages consistency
- **Personalization**: Goal-based talent recommendations
- **Depth**: 50 levels of meaningful advancement
- **Retention**: Keep players coming back 2x/week minimum

**Everything is implemented and ready to use!** 🎮💪
