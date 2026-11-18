# Changelog

All notable changes to WorkoutTracker Enhanced will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2025-11-02

### 🎉 Initial Release

#### Added
- **Complete macOS app** with SwiftUI interface
- **Smart data persistence** with automatic JSON storage
- **Python integration** for custom workout program generation
- **Progress tracking** with charts and analytics
- **Rest timer** with 90-second countdown and audio notifications
- **Export/Import functionality** for workout data backup
- **Pre-loaded workout templates**:
  - 5/3/1 Wendler
  - Starting Strength
  - Push/Pull/Legs
  - Upper/Lower Split
- **Menu bar integration** for quick access
- **Keyboard shortcuts** for common actions
- **Dark mode support** with automatic theme switching
- **Streak calculation** for consecutive workout days
- **Real-time volume tracking** and statistics
- **Multiple tabs**: Dashboard, Workouts, Programs, Progress, History, Settings

#### Features Implemented

##### 1. Data Persistence
- Automatic save/load of workout sessions
- JSON-based storage in `~/Documents/workout_tracker/`
- Separate files for sessions and programs
- ISO 8601 date encoding

##### 2. Python Integration
- Direct integration with `workout_routine_generator.py`
- Generate custom programs with specific duration and frequency
- Automatic JSON output for Swift consumption
- Cross-platform path detection
- Comprehensive error handling

##### 3. Progress Tracking
- Dashboard stats (today's workouts, weekly count, streak, volume)
- Swift Charts integration (macOS 13.0+)
- Weekly activity bar chart
- Volume over time line chart
- Total workouts, average volume, streak calculation

##### 4. Workout Logging
- Start workout → Add exercises → Log sets → Complete flow
- Real-time volume tracking
- Muscle group categorization
- Visual checkmarks for completed sets

##### 5. Rest Timer
- Automatic 90-second countdown after each set
- Audio beep notification
- Non-blocking background operation
- Configurable default rest time

##### 6. Export/Import
- Export all sessions to JSON
- Import and merge workout data
- Keyboard shortcuts (`⌘⇧E`, `⌘⇧I`)
- Save panel integration

##### 7. Menu Bar Extra
- Quick access without opening main window
- Open WorkoutTracker
- Quick Log Workout (`⌘⌥L`)
- View Today's Progress
- Current streak display
- Quit option

#### Technical Improvements
- **Enhanced Python script** with:
  - Cross-platform path support
  - Comprehensive logging
  - Input validation
  - Error handling
  - Type hints
- **Improved PythonGeneratorService** with:
  - Multiple path search locations
  - Robust error messages
  - JSON validation
  - stderr capture
- **Zero dependencies** - Built entirely with standard frameworks
- **Clean architecture** - MVVM-inspired pattern with singleton services
- **Comprehensive documentation**:
  - README.md with full usage guide
  - Inline code comments
  - Docstrings for all major functions
  - Quick reference guides

#### Documentation
- ✅ Comprehensive README.md
- ✅ Detailed usage guide
- ✅ Keyboard shortcuts reference
- ✅ Data models documentation
- ✅ Troubleshooting guide
- ✅ Architecture overview
- ✅ Python integration details
- ✅ Contributing guidelines

#### Build & Distribution
- Swift Package Manager configuration
- macOS 13.0+ minimum requirement
- Apple Silicon and Intel support
- Lightweight binary (<5 MB)
- Fast startup (<1 second)

### Known Limitations
- macOS only (iOS/watchOS support planned for v2.0)
- Charts require macOS 13.0+ (graceful degradation on older systems)
- Python 3.10+ required for program generation
- No iCloud sync yet (planned for v1.1)

---

## [Unreleased]

### Planned for v1.1
- [ ] iCloud sync between devices
- [ ] Body measurement tracking
- [ ] Custom exercise library with search
- [ ] Photo attachments for exercises
- [ ] Workout notes with RPE (Rate of Perceived Exertion) tracking
- [ ] Personal record (PR) tracking and notifications
- [ ] Advanced analytics dashboard
- [ ] Workout templates marketplace

### Planned for v2.0
- [ ] iOS companion app
- [ ] Apple Watch integration
- [ ] HealthKit integration
- [ ] Social features (share workouts, compare with friends)
- [ ] Video exercise demonstrations
- [ ] Form check with camera
- [ ] Nutrition tracking integration
- [ ] Workout reminders and notifications

---

## Version History

### [1.0.0] - 2025-11-02
- Initial production-ready release
- All 7 core features implemented
- Comprehensive documentation
- DMG installer created

---

## Links

- **Repository**: https://github.com/yourusername/WorkoutTracker
- **Issues**: https://github.com/yourusername/WorkoutTracker/issues
- **Releases**: https://github.com/yourusername/WorkoutTracker/releases

---

**Note**: For detailed commit history, see [GitHub Commits](https://github.com/yourusername/WorkoutTracker/commits/main).

## 1.1.0 beta — 2026-11-18

- Consolidate the richer native training/game branch and preserve existing profiles.
- Facebook-only web and native authentication, persistent sessions, secure native handoff.
- Responsive training companion with account saves, workout recovery, progression, XP, quests and private friend invitations.
- Scoped BatesAI deployment, privacy/deletion instructions, local-only verification and disabled GitHub compute.
- Known release gate: Meta credentials/live-mode configuration and real Facebook authentication still required. Native/web logs remain separate; no stable release is asserted.
