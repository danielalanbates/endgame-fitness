//
//  AvatarSystem.swift
//  3D Blob Avatar for WorkoutTracker
//
//  Progressive blob character that evolves with user's fitness journey
//

import SwiftUI
import SceneKit

// MARK: - Avatar Body Profile
struct AvatarBodyProfile: Codable, Equatable {
    // Initial approximation (from questionnaire)
    var height: Height           // Short, Average, Tall
    var bodyType: BodyType       // Slim, Average, Muscular, Heavy
    var bellySize: BellySize     // Flat, Small, Medium, Large

    // Fitness progression (changes over time)
    var muscleLevel: Int         // 0-100 (based on total volume lifted)
    var leanLevel: Int          // 0-100 (based on weight loss progress)
    var shoulderWidth: Int      // 0-100 (upper body development)
    var legThickness: Int       // 0-100 (lower body development)

    // Visual customization (unlocks)
    var skinColor: BlobColor     // Unlocks at level 5
    var hasEyes: Bool           // Unlocks at level 3
    var hasMouth: Bool          // Unlocks at level 3
    var outfit: AvatarOutfit?   // Unlocks at level 10+

    enum Height: String, Codable, CaseIterable {
        case short = "Short"
        case average = "Average"
        case tall = "Tall"

        var scaleY: Float {
            switch self {
            case .short: return 0.85
            case .average: return 1.0
            case .tall: return 1.15
            }
        }
    }

    enum BodyType: String, Codable, CaseIterable {
        case slim = "Slim"
        case average = "Average"
        case athletic = "Athletic"
        case heavy = "Heavy"

        var baseScale: Float {
            switch self {
            case .slim: return 0.85
            case .average: return 1.0
            case .athletic: return 1.1
            case .heavy: return 1.3
            }
        }
    }

    enum BellySize: String, Codable, CaseIterable {
        case flat = "Flat"
        case small = "Small"
        case medium = "Medium"
        case large = "Large"

        var bellyScale: Float {
            switch self {
            case .flat: return 0.9
            case .small: return 1.1
            case .medium: return 1.3
            case .large: return 1.5
            }
        }
    }

    enum BlobColor: String, Codable, CaseIterable {
        case blue = "Blue"        // Default (level 1)
        case green = "Green"      // Unlock level 5
        case purple = "Purple"    // Unlock level 10
        case orange = "Orange"    // Unlock level 15
        case red = "Red"          // Unlock level 20
        case gold = "Gold"        // Unlock level 30
        case rainbow = "Rainbow"  // Unlock level 50

        var color: PlatformColor {
            switch self {
            case .blue: return PlatformColor(red: 0.3, green: 0.5, blue: 0.9, alpha: 1.0)
            case .green: return PlatformColor(red: 0.3, green: 0.8, blue: 0.4, alpha: 1.0)
            case .purple: return PlatformColor(red: 0.6, green: 0.3, blue: 0.9, alpha: 1.0)
            case .orange: return PlatformColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 1.0)
            case .red: return PlatformColor(red: 0.9, green: 0.3, blue: 0.3, alpha: 1.0)
            case .gold: return PlatformColor(red: 0.9, green: 0.7, blue: 0.2, alpha: 1.0)
            case .rainbow: return PlatformColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0) // Handled with gradient
            }
        }

        var unlockLevel: Int {
            switch self {
            case .blue: return 1
            case .green: return 5
            case .purple: return 10
            case .orange: return 15
            case .red: return 20
            case .gold: return 30
            case .rainbow: return 50
            }
        }
    }

    enum AvatarOutfit: String, Codable, CaseIterable {
        case none = "None"
        case gymShirt = "Gym Shirt"      // Level 10
        case tank = "Tank Top"           // Level 15
        case hoodie = "Hoodie"           // Level 20
        case champion = "Champion Belt"  // Level 30
        case legend = "Legend Crown"     // Level 50

        var unlockLevel: Int {
            switch self {
            case .none: return 1
            case .gymShirt: return 10
            case .tank: return 15
            case .hoodie: return 20
            case .champion: return 30
            case .legend: return 50
            }
        }
    }

    // Default blob (brand new user)
    static var defaultBlob: AvatarBodyProfile {
        AvatarBodyProfile(
            height: .average,
            bodyType: .average,
            bellySize: .medium,
            muscleLevel: 0,
            leanLevel: 0,
            shoulderWidth: 0,
            legThickness: 0,
            skinColor: .blue,
            hasEyes: false,
            hasMouth: false,
            outfit: nil
        )
    }
}

// MARK: - Avatar Evolution System
class AvatarEvolutionEngine {

    /// Update avatar based on workout progress
    static func updateAvatar(_ profile: inout AvatarBodyProfile,
                            totalVolume: Double,
                            weightChange: Double,
                            level: Int) {

        // Muscle level (0-100) based on total volume lifted
        // Every 100,000 lbs = +10 muscle points
        let volumePoints = min(100, Int(totalVolume / 10_000))
        profile.muscleLevel = volumePoints

        // Lean level (0-100) based on weight loss
        // Every 10 lbs lost = +10 lean points
        if weightChange < 0 {
            let leanPoints = min(100, Int(abs(weightChange) * 10))
            profile.leanLevel = leanPoints
        }

        // Body part development (based on volume distribution)
        // TODO: Track upper/lower split volume separately
        profile.shoulderWidth = min(100, volumePoints) // Simplified for now
        profile.legThickness = min(100, volumePoints)

        // Unlock features based on level
        if level >= 3 {
            profile.hasEyes = true
            profile.hasMouth = true
        }
    }

    /// Get body shape description for encouragement
    static func getProgressDescription(_ profile: AvatarBodyProfile) -> String {
        let muscleDesc: String
        if profile.muscleLevel < 20 {
            muscleDesc = "building a foundation"
        } else if profile.muscleLevel < 50 {
            muscleDesc = "developing muscle"
        } else if profile.muscleLevel < 80 {
            muscleDesc = "looking strong"
        } else {
            muscleDesc = "absolutely jacked"
        }

        let leanDesc: String
        if profile.leanLevel < 20 {
            leanDesc = "starting your journey"
        } else if profile.leanLevel < 50 {
            leanDesc = "getting leaner"
        } else if profile.leanLevel < 80 {
            leanDesc = "looking fit"
        } else {
            leanDesc = "totally shredded"
        }

        return "Your avatar is \(muscleDesc) and \(leanDesc)!"
    }
}

// MARK: - 3D Blob Renderer
class BlobAvatar3D {
    private var scene: SCNScene
    private var avatarNode: SCNNode
    private var profile: AvatarBodyProfile

    init(profile: AvatarBodyProfile) {
        self.profile = profile
        self.scene = SCNScene()
        self.avatarNode = SCNNode()

        setupScene()
        buildBlobBody()
    }

    private func setupScene() {
        // Camera
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(x: 0, y: 1.5, z: 5)
        scene.rootNode.addChildNode(cameraNode)

        // Lighting
        let lightNode = SCNNode()
        lightNode.light = SCNLight()
        lightNode.light?.type = .omni
        lightNode.position = SCNVector3(x: 0, y: 5, z: 5)
        scene.rootNode.addChildNode(lightNode)

        let ambientLight = SCNNode()
        ambientLight.light = SCNLight()
        ambientLight.light?.type = .ambient
        ambientLight.light?.color = PlatformColor(white: 0.4, alpha: 1.0)
        scene.rootNode.addChildNode(ambientLight)
    }

    private func buildBlobBody() {
        avatarNode.removeFromParentNode()
        avatarNode = SCNNode()

        // Base material
        let material = SCNMaterial()
        material.diffuse.contents = profile.skinColor.color
        material.specular.contents = PlatformColor.white
        material.shininess = 0.3

        // HEAD (blob sphere, no neck)
        let headRadius: SCNFloat = 0.4
        let headSphere = SCNSphere(radius: headRadius)
        headSphere.materials = [material]
        let headNode = SCNNode(geometry: headSphere)
        headNode.position = SCNVector3(
            x: 0,
            y: scn(2.0 * profile.height.scaleY), // Top of body
            z: 0
        )
        avatarNode.addChildNode(headNode)

        // Eyes (if unlocked)
        if profile.hasEyes {
            addEyes(to: headNode, headRadius: headRadius)
        }

        // Mouth (if unlocked)
        if profile.hasMouth {
            addMouth(to: headNode, headRadius: headRadius)
        }

        // TORSO (ellipsoid blob)
        let torsoWidth = scn(0.6 * profile.bodyType.baseScale)
        let torsoHeight = scn(1.2 * profile.height.scaleY)
        let torsoDepth = scn(0.5 * profile.bodyType.baseScale)

        let torsoSphere = SCNSphere(radius: 0.5)
        torsoSphere.materials = [material]
        let torsoNode = SCNNode(geometry: torsoSphere)
        torsoNode.scale = SCNVector3(
            x: scn(torsoWidth),
            y: scn(torsoHeight),
            z: scn(torsoDepth)
        )
        torsoNode.position = SCNVector3(x: 0, y: 1.0, z: 0)
        avatarNode.addChildNode(torsoNode)

        // BELLY (if present)
        if profile.bellySize != .flat {
            let bellyScale = profile.bellySize.bellyScale
            let bellySphere = SCNSphere(radius: 0.35)
            bellySphere.materials = [material]
            let bellyNode = SCNNode(geometry: bellySphere)
            bellyNode.scale = SCNVector3(
                x: scn(bellyScale),
                y: scn(bellyScale * 0.8),
                z: scn(bellyScale * 1.2)
            )
            bellyNode.position = SCNVector3(x: 0, y: 0.8, z: 0.4)
            avatarNode.addChildNode(bellyNode)
        }

        // ARMS (blob cylinders)
        addArm(side: .left, material: material)
        addArm(side: .right, material: material)

        // LEGS (blob cylinders)
        addLeg(side: .left, material: material)
        addLeg(side: .right, material: material)

        scene.rootNode.addChildNode(avatarNode)
    }

    private func addEyes(to headNode: SCNNode, headRadius: CGFloat) {
        let eyeMaterial = SCNMaterial()
        eyeMaterial.diffuse.contents = PlatformColor.black

        let eyeRadius: SCNFloat = 0.08
        let eyeOffset = headRadius * 0.6

        // Left eye
        let leftEye = SCNSphere(radius: eyeRadius)
        leftEye.materials = [eyeMaterial]
        let leftEyeNode = SCNNode(geometry: leftEye)
        leftEyeNode.position = SCNVector3(x: -0.15, y: 0.1, z: scn(eyeOffset))
        headNode.addChildNode(leftEyeNode)

        // Right eye
        let rightEye = SCNSphere(radius: eyeRadius)
        rightEye.materials = [eyeMaterial]
        let rightEyeNode = SCNNode(geometry: rightEye)
        rightEyeNode.position = SCNVector3(x: 0.15, y: 0.1, z: scn(eyeOffset))
        headNode.addChildNode(rightEyeNode)
    }

    private func addMouth(to headNode: SCNNode, headRadius: CGFloat) {
        // Simple smile (small sphere)
        let mouthMaterial = SCNMaterial()
        mouthMaterial.diffuse.contents = PlatformColor.black

        let mouth = SCNSphere(radius: 0.05)
        mouth.materials = [mouthMaterial]
        let mouthNode = SCNNode(geometry: mouth)
        mouthNode.position = SCNVector3(x: 0, y: -0.1, z: scn(headRadius * 0.6))
        headNode.addChildNode(mouthNode)
    }

    private enum Side {
        case left, right
    }

    private func addArm(side: Side, material: SCNMaterial) {
        let armLength: SCNFloat = 0.8
        let armRadius: SCNFloat = 0.12

        let armCylinder = SCNCylinder(radius: armRadius, height: armLength)
        armCylinder.materials = [material]
        let armNode = SCNNode(geometry: armCylinder)

        // Position at shoulder height (top of torso) and angle downward
        let xOffset: SCNFloat = side == .left ? -0.6 : 0.6  // Closer to torso
        armNode.position = SCNVector3(x: xOffset, y: 1.6, z: 0)  // Higher, at shoulder level

        // Rotate arm to angle down naturally
        let angleDirection: SCNFloat = side == .left ? SCNFloat.pi / 6 : -SCNFloat.pi / 6
        armNode.eulerAngles = SCNVector3(x: 0, y: 0, z: angleDirection)

        // Hand (small sphere at end of arm)
        let handSphere = SCNSphere(radius: 0.15)
        handSphere.materials = [material]
        let handNode = SCNNode(geometry: handSphere)
        // Position hand at the bottom of the arm cylinder (local coordinate: negative Y = down)
        handNode.position = SCNVector3(x: 0, y: -scn(armLength / 2) - 0.15, z: 0)
        armNode.addChildNode(handNode)

        avatarNode.addChildNode(armNode)
    }

    private func addLeg(side: Side, material: SCNMaterial) {
        let legLength: SCNFloat = 1.0
        let legRadius: SCNFloat = 0.15

        let legCylinder = SCNCylinder(radius: legRadius, height: legLength)
        legCylinder.materials = [material]
        let legNode = SCNNode(geometry: legCylinder)

        // Position
        let xOffset: SCNFloat = side == .left ? -0.25 : 0.25
        legNode.position = SCNVector3(x: xOffset, y: scn(legLength / 2), z: 0)

        // Foot (small sphere)
        let footSphere = SCNSphere(radius: 0.18)
        footSphere.materials = [material]
        let footNode = SCNNode(geometry: footSphere)
        footNode.position = SCNVector3(x: 0, y: scn(-legLength / 2 - 0.1), z: 0.1)
        legNode.addChildNode(footNode)

        avatarNode.addChildNode(legNode)
    }

    // MARK: - Animation Methods

    /// Make the blob do a squat animation
    func performSquat(duration: TimeInterval = 1.0) {
        let squatDown = SCNAction.moveBy(x: 0, y: -0.3, z: 0, duration: duration / 2)
        let squatUp = SCNAction.moveBy(x: 0, y: 0.3, z: 0, duration: duration / 2)
        let sequence = SCNAction.sequence([squatDown, squatUp])
        avatarNode.runAction(sequence)
    }

    /// Make the blob do a jumping jack
    func performJumpingJack(duration: TimeInterval = 1.0) {
        let jump = SCNAction.moveBy(x: 0, y: 0.3, z: 0, duration: duration / 4)
        let land = SCNAction.moveBy(x: 0, y: -0.3, z: 0, duration: duration / 4)
        let sequence = SCNAction.sequence([jump, land, jump, land])
        avatarNode.runAction(sequence)
    }

    /// Idle animation (gentle bounce)
    func startIdleAnimation() {
        let bounce = SCNAction.moveBy(x: 0, y: 0.05, z: 0, duration: 1.0)
        bounce.timingMode = .easeInEaseOut
        let sequence = SCNAction.sequence([bounce, bounce.reversed()])
        let loop = SCNAction.repeatForever(sequence)
        avatarNode.runAction(loop, forKey: "idle")
    }

    func stopIdleAnimation() {
        avatarNode.removeAction(forKey: "idle")
    }

    /// Celebrate animation (spin + jump)
    func celebrate() {
        let spin = SCNAction.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 1.0)
        let jump = SCNAction.moveBy(x: 0, y: 0.5, z: 0, duration: 0.5)
        let land = SCNAction.moveBy(x: 0, y: -0.5, z: 0, duration: 0.5)
        let sequence = SCNAction.sequence([
            SCNAction.group([spin, jump]),
            land
        ])
        avatarNode.runAction(sequence)
    }

    // MARK: - Update Methods

    func updateProfile(_ newProfile: AvatarBodyProfile) {
        self.profile = newProfile
        buildBlobBody() // Rebuild with new proportions
    }

    func getScene() -> SCNScene {
        return scene
    }
}
