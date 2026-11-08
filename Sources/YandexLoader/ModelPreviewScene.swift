import SceneKit
import AppKit
import simd

struct ModelPreviewScene {
    let scene: SCNScene
    let modelRoot: SCNNode
    let camera: SCNNode
    let dimensions: SCNVector3

    static func make(model: SCNNode, fileExtension: String, zUp: Bool, aspectRatio: CGFloat) -> ModelPreviewScene {
        let scene = SCNScene()
        let orientation = SCNNode()
        orientation.addChildNode(model)
        let native = orientation.boundingBox
        let dimensions = SCNVector3(native.max.x - native.min.x, native.max.y - native.min.y, native.max.z - native.min.z)
        if ["stl", "ply"].contains(fileExtension.lowercased()) && zUp {
            // Map the file's +Z to the viewer's +Y; its -Y front then faces +Z.
            orientation.eulerAngles.x = -.pi / 2
        }

        // A node's bounding box excludes its own transform. Measure from a separate
        // parent so centring and camera fitting include the axis rotation above.
        let modelRoot = SCNNode()
        modelRoot.addChildNode(orientation)
        let bounds = modelRoot.boundingBox
        let center = SCNVector3((bounds.min.x + bounds.max.x) / 2, (bounds.min.y + bounds.max.y) / 2, (bounds.min.z + bounds.max.z) / 2)
        modelRoot.position = SCNVector3(-center.x, -center.y, -center.z)
        scene.rootNode.addChildNode(modelRoot)

        let x = bounds.max.x - bounds.min.x, y = bounds.max.y - bounds.min.y, z = bounds.max.z - bounds.min.z
        let radius = max(0.001, sqrt(x*x + y*y + z*z) / 2)
        let verticalFOV: CGFloat = .pi / 4
        let horizontalFOV = 2 * atan(tan(verticalFOV / 2) * max(0.1, aspectRatio))
        let distance = radius / sin(min(verticalFOV, horizontalFOV) / 2) * 1.12
        let direction = simd_normalize(SIMD3<Float>(1, 0.65, 1.8))
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 45
        camera.camera?.zNear = Double(radius / 1000)
        camera.camera?.zFar = Double(distance + radius * 4)
        camera.camera?.wantsHDR = true
        camera.camera?.wantsExposureAdaptation = false
        camera.camera?.exposureOffset = -0.15
        camera.camera?.contrast = 0.12
        camera.camera?.screenSpaceAmbientOcclusionIntensity = 1.0
        camera.camera?.screenSpaceAmbientOcclusionRadius = radius * 0.10
        camera.camera?.screenSpaceAmbientOcclusionBias = radius * 0.001
        camera.camera?.screenSpaceAmbientOcclusionDepthThreshold = radius * 0.3
        camera.simdPosition = direction * Float(distance)
        camera.look(at: SCNVector3Zero, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
        scene.rootNode.addChildNode(camera)

        let ambient = SCNNode()
        ambient.light = SCNLight(); ambient.light?.type = .ambient; ambient.light?.intensity = 100
        scene.rootNode.addChildNode(ambient)
        // Camera-relative studio lighting reveals relief while keeping the unlit side readable.
        func studioLight(_ name: String, position: SCNVector3, intensity: CGFloat, shadows: Bool = false) {
            let node = SCNNode(); node.name = name; node.light = SCNLight(); node.light?.type = .directional
            node.light?.intensity = intensity
            node.position = position
            camera.addChildNode(node)
            node.look(at: SCNVector3Zero)
            if shadows {
                node.light?.castsShadow = true
                node.light?.shadowMode = .forward
                node.light?.shadowColor = NSColor.black.withAlphaComponent(0.65)
                node.light?.shadowRadius = 2
                node.light?.shadowSampleCount = 16
                node.light?.shadowMapSize = CGSize(width: 1024, height: 1024)
                node.light?.orthographicScale = radius * 2.4
                node.light?.zNear = radius / 1000
                node.light?.zFar = distance + radius * 5
                node.light?.maximumShadowDistance = distance + radius * 5
                node.light?.shadowBias = 0.5
            }
        }
        studioLight("Preview key light", position: SCNVector3(-radius * 2, radius * 2.5, 0), intensity: 950, shadows: true)
        studioLight("Preview fill light", position: SCNVector3(radius * 2, radius * 0.5, 0), intensity: 140)
        return ModelPreviewScene(scene: scene, modelRoot: modelRoot, camera: camera, dimensions: dimensions)
    }
}
