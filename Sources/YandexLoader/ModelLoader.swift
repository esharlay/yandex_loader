import AppKit
import SceneKit
import ModelIO
import SceneKit.ModelIO
import simd

enum ModelLoader {
    static let extensions: Set<String> = ["stl", "glb", "gltf", "obj", "usd", "usda", "usdc", "usdz", "dae", "ply", "abc", "scn"]
    static func load(_ url: URL) throws -> SCNNode {
        switch url.pathExtension.lowercased() {
        case "stl": return try stl(Data(contentsOf: url))
        case "ply": return try ply(Data(contentsOf: url))
        case "gltf", "glb": return try GLTFReader(url: url).load()
        default:
            if let scene = try? SCNScene(url: url, options: [.checkConsistency: true]) { return scene.rootNode }
            let asset = MDLAsset(url: url); asset.loadTextures()
            guard asset.count > 0 else { throw LoaderError.message("Не удалось прочитать модель этого формата.") }
            return SCNScene(mdlAsset: asset).rootNode
        }
    }
    static func geometry(vertices: [SCNVector3], indices: [UInt32], normals: [SCNVector3]? = nil) throws -> SCNGeometry {
        guard !vertices.isEmpty, !indices.isEmpty, indices.allSatisfy({ Int($0) < vertices.count }) else { throw LoaderError.message("В модели нет корректных треугольников.") }
        var sources = [SCNGeometrySource(vertices: vertices)]
        if let normals, normals.count == vertices.count { sources.append(SCNGeometrySource(normals: normals)) }
        else {
            var sums = Array(repeating: SIMD3<Float>.zero, count: vertices.count)
            func vector(_ index: UInt32) -> SIMD3<Float> { let v = vertices[Int(index)]; return SIMD3(Float(v.x), Float(v.y), Float(v.z)) }
            for i in stride(from: 0, to: indices.count - 2, by: 3) {
                let a = indices[i], b = indices[i+1], c = indices[i+2]
                let n = simd_cross(vector(b) - vector(a), vector(c) - vector(a))
                sums[Int(a)] += n; sums[Int(b)] += n; sums[Int(c)] += n
            }
            sources.append(SCNGeometrySource(normals: sums.map { let n = simd_length($0) > 0 ? simd_normalize($0) : SIMD3<Float>(0, 1, 0); return SCNVector3(n.x, n.y, n.z) }))
        }
        let data = indices.withUnsafeBytes { Data($0) }
        let element = SCNGeometryElement(data: data, primitiveType: .triangles, primitiveCount: indices.count / 3, bytesPerIndex: 4)
        let g = SCNGeometry(sources: sources, elements: [element]); let material = SCNMaterial(); material.diffuse.contents = NSColor(calibratedRed: 0.64, green: 0.72, blue: 0.85, alpha: 1); material.roughness.contents = 0.72; material.metalness.contents = 0.05; material.isDoubleSided = true; material.lightingModel = .physicallyBased; g.materials = [material]
        return g
    }
    static func stl(_ data: Data) throws -> SCNNode {
        var vertices: [SCNVector3] = [], normals: [SCNVector3] = []
        if data.count >= 84 {
            let count = Int(data.u32(80))
            if count > 0 && count <= (data.count - 84) / 50 && 84 + count * 50 == data.count {
                vertices.reserveCapacity(count * 3)
                for i in 0..<count {
                    let base = 84 + i * 50; let n = SCNVector3(data.f32(base), data.f32(base + 4), data.f32(base + 8))
                    for j in 0..<3 { let o = base + 12 + j * 12; vertices.append(SCNVector3(data.f32(o), data.f32(o + 4), data.f32(o + 8))); normals.append(n) }
                }
            }
        }
        if vertices.isEmpty {
            guard let text = String(data: data, encoding: .utf8) else { throw LoaderError.message("Файл STL повреждён.") }
            for line in text.components(separatedBy: .newlines) {
                let p = line.split(whereSeparator: { $0.isWhitespace })
                if p.count >= 4 && p[0] == "vertex", let x = Float(p[1]), let y = Float(p[2]), let z = Float(p[3]) { vertices.append(SCNVector3(x, y, z)) }
            }
        }
        guard vertices.count % 3 == 0, vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { throw LoaderError.message("Некорректные координаты STL.") }
        // Generate face normals for STL exports whose stored normals are zero.
        if normals.count != vertices.count || normals.contains(where: { $0.x == 0 && $0.y == 0 && $0.z == 0 }) {
            normals = []
            for i in stride(from: 0, to: vertices.count, by: 3) {
                func vector(_ v: SCNVector3) -> SIMD3<Float> { SIMD3(Float(v.x), Float(v.y), Float(v.z)) }
                let a = vector(vertices[i]), b = vector(vertices[i+1]), c = vector(vertices[i+2])
                let cross = simd_cross(b-a, c-a); let n = simd_length(cross) > 0 ? simd_normalize(cross) : SIMD3<Float>(0, 1, 0)
                normals += Array(repeating: SCNVector3(n.x, n.y, n.z), count: 3)
            }
        }
        return SCNNode(geometry: try geometry(vertices: vertices, indices: vertices.indices.map(UInt32.init), normals: normals))
    }
    static func ply(_ data: Data) throws -> SCNNode {
        guard let marker = data.range(of: Data("end_header".utf8)), let header = String(data: data.prefix(marker.upperBound), encoding: .ascii), header.hasPrefix("ply") else { throw LoaderError.message("Файл PLY повреждён.") }
        var offset = marker.upperBound
        if offset < data.count && data[offset] == 13 { offset += 1 }; if offset < data.count && data[offset] == 10 { offset += 1 }
        struct Property { var name: String; var type: String; var listType: String? }
        struct Element { var name: String; var count: Int; var properties: [Property] }
        var elements: [Element] = []; let ascii = header.contains("format ascii"); let big = header.contains("binary_big_endian")
        for line in header.components(separatedBy: .newlines) {
            let p = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if p.first == "element", p.count == 3, let n = Int(p[2]), n >= 0 { elements.append(Element(name: p[1], count: n, properties: [])) }
            if p.first == "property", !elements.isEmpty {
                if p.count == 3 { elements[elements.count-1].properties.append(Property(name: p[2], type: p[1])) }
                else if p.count == 5 && p[1] == "list" { elements[elements.count-1].properties.append(Property(name: p[4], type: p[3], listType: p[2])) }
            }
        }
        let tokens = ascii ? String(decoding: data.suffix(from: offset), as: UTF8.self).split(whereSeparator: { $0.isWhitespace }) : []; var ti = 0
        func number(_ type: String) throws -> Double {
            if ascii { guard ti < tokens.count, let d = Double(tokens[ti]), d.isFinite else { throw LoaderError.message("Неверные данные PLY.") }; ti += 1; return d }
            let bytes: Int
            switch type { case "char", "uchar", "int8", "uint8": bytes = 1; case "short", "ushort", "int16", "uint16": bytes = 2; case "double", "float64": bytes = 8; default: bytes = 4 }
            guard offset + bytes <= data.count else { throw LoaderError.message("Файл PLY обрезан.") }
            var bits: UInt64 = 0
            for i in 0..<bytes { bits |= UInt64(data[offset+i]) << ((big ? bytes-1-i : i) * 8) }; offset += bytes
            switch type {
            case "float", "float32": return Double(Float(bitPattern: UInt32(bits)))
            case "double", "float64": return Double(bitPattern: bits)
            case "char", "int8": return Double(Int8(bitPattern: UInt8(bits)))
            case "short", "int16": return Double(Int16(bitPattern: UInt16(bits)))
            case "int", "int32": return Double(Int32(bitPattern: UInt32(bits)))
            default: return Double(bits)
            }
        }
        var vertices: [SCNVector3] = [], indices: [UInt32] = []
        for element in elements {
            guard element.count <= 30_000_000 else { throw LoaderError.message("Слишком много элементов в PLY.") }
            for _ in 0..<element.count {
                var xyz = ["x": 0.0, "y": 0.0, "z": 0.0]
                for property in element.properties {
                    if let listType = property.listType {
                        let value = try number(listType); guard value >= 0, value <= 1_000_000 else { throw LoaderError.message("Неверный список PLY.") }
                        var face: [UInt32] = []
                        for _ in 0..<Int(value) { let index = try number(property.type); if element.name == "face" && ["vertex_indices", "vertex_index"].contains(property.name) { guard index >= 0, index < Double(UInt32.max) else { throw LoaderError.message("Неверный индекс PLY.") }; face.append(UInt32(index)) } }
                        if face.count >= 3 { for j in 1..<(face.count-1) { indices += [face[0], face[j], face[j+1]] } }
                    } else { let n = try number(property.type); if element.name == "vertex" && xyz[property.name] != nil { xyz[property.name] = n } }
                }
                if element.name == "vertex" { vertices.append(SCNVector3(xyz["x"]!, xyz["y"]!, xyz["z"]!)) }
            }
        }
        return SCNNode(geometry: try geometry(vertices: vertices, indices: indices))
    }
    static func triangleCount(_ node: SCNNode) -> Int {
        var result = 0
        func visit(_ n: SCNNode) { for e in n.geometry?.elements ?? [] { switch e.primitiveType { case .triangles: result += e.primitiveCount; case .triangleStrip: result += e.primitiveCount; case .polygon: result += e.primitiveCount; default: break } }; n.childNodes.forEach(visit) }; visit(node); return result
    }
}

extension Data {
    func u32(_ offset: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(self[offset + $1]) << ($1 * 8) } }
    func f32(_ offset: Int) -> Float { Float(bitPattern: u32(offset)) }
}

// Static glTF 2.0 scene reader: transforms, indexed meshes, buffers and base-color textures.
final class GLTFReader {
    let url: URL
    var json: [String: Any] = [:]
    var buffers: [Data] = []
    init(url: URL) { self.url = url }
    func load() throws -> SCNNode {
        let data = try Data(contentsOf: url); var bin: Data?
        if url.pathExtension.lowercased() == "glb" {
            guard data.count >= 20, data.u32(0) == 0x46546C67, data.u32(4) == 2 else { throw LoaderError.message("Некорректный GLB 2.0.") }
            var offset = 12
            while offset + 8 <= data.count {
                let length = Int(data.u32(offset)), type = data.u32(offset + 4); offset += 8
                guard length <= data.count - offset else { throw LoaderError.message("Файл GLB обрезан.") }
                let chunk = data.subdata(in: offset..<offset+length)
                if type == 0x4E4F534A { json = try JSONSerialization.jsonObject(with: chunk) as? [String: Any] ?? [:] }
                if type == 0x004E4942 { bin = chunk }; offset += length
            }
        } else { json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:] }
        for (index, b) in array("buffers").enumerated() {
            if let uri = b["uri"] as? String { buffers.append(try uriData(uri)) }
            else if index == 0, let bin { buffers.append(bin) }
            else { throw LoaderError.message("Не найден буфер glTF.") }
        }
        if let required = json["extensionsRequired"] as? [String], required.contains(where: { ["KHR_draco_mesh_compression", "EXT_meshopt_compression"].contains($0) }) { throw LoaderError.message("Эта модель использует сжатие Draco/meshopt. Экспортируйте GLB без сжатия.") }
        let nodes = array("nodes"), meshes = array("meshes")
        func makeNode(_ index: Int, visited: Set<Int>) throws -> SCNNode {
            guard nodes.indices.contains(index), !visited.contains(index) else { throw LoaderError.message("Некорректное дерево glTF.") }
            var visited = visited; visited.insert(index); let item = nodes[index]; let node = SCNNode(); node.name = item["name"] as? String
            if let matrix = item["matrix"] as? [Double], matrix.count == 16 {
                let m = matrix.map(Float.init); node.simdTransform = simd_float4x4(SIMD4(m[0],m[1],m[2],m[3]), SIMD4(m[4],m[5],m[6],m[7]), SIMD4(m[8],m[9],m[10],m[11]), SIMD4(m[12],m[13],m[14],m[15]))
            } else {
                if let v = item["translation"] as? [Float], v.count == 3 { node.simdPosition = SIMD3(v[0],v[1],v[2]) }
                if let v = item["scale"] as? [Float], v.count == 3 { node.simdScale = SIMD3(v[0],v[1],v[2]) }
                if let v = item["rotation"] as? [Float], v.count == 4 { node.simdOrientation = simd_quatf(ix: v[0], iy: v[1], iz: v[2], r: v[3]) }
            }
            if let mi = item["mesh"] as? Int, meshes.indices.contains(mi) {
                for p in meshes[mi]["primitives"] as? [[String: Any]] ?? [] { node.addChildNode(try primitive(p)) }
            }
            for child in item["children"] as? [Int] ?? [] { node.addChildNode(try makeNode(child, visited: visited)) }
            return node
        }
        let root = SCNNode(); let scenes = array("scenes"); let si = json["scene"] as? Int ?? 0
        let children = Set(nodes.flatMap { $0["children"] as? [Int] ?? [] })
        let roots = scenes.indices.contains(si) ? scenes[si]["nodes"] as? [Int] ?? [] : nodes.indices.filter { !children.contains($0) }
        for i in roots { root.addChildNode(try makeNode(i, visited: [])) }
        guard ModelLoader.triangleCount(root) > 0 else { throw LoaderError.message("В glTF нет треугольной геометрии.") }
        return root
    }
    func array(_ key: String) -> [[String: Any]] { json[key] as? [[String: Any]] ?? [] }
    func uriData(_ uri: String) throws -> Data {
        if uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ","), let d = Data(base64Encoded: String(uri[uri.index(after: comma)...])) { return d }
        guard !uri.contains("://") else { throw LoaderError.message("Внешние сетевые ресурсы glTF не поддерживаются.") }
        let local = url.deletingLastPathComponent().appendingPathComponent(uri.removingPercentEncoding ?? uri).standardizedFileURL
        return try Data(contentsOf: local)
    }
    func accessor(_ index: Int) throws -> [[Float]] {
        let accessors = array("accessors"), views = array("bufferViews")
        guard accessors.indices.contains(index) else { throw LoaderError.message("Некорректный accessor glTF.") }
        let a = accessors[index]
        guard a["sparse"] == nil, let vi = a["bufferView"] as? Int, views.indices.contains(vi) else { throw LoaderError.message("Разреженные accessor glTF не поддерживаются. Экспортируйте модель с обычными буферами.") }
        let v = views[vi], bi = v["buffer"] as? Int ?? 0, count = a["count"] as? Int ?? 0, type = a["componentType"] as? Int ?? 5126
        guard buffers.indices.contains(bi), count >= 0, count <= 30_000_000 else { throw LoaderError.message("Неверный буфер glTF.") }
        let components = ["SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4][a["type"] as? String ?? ""] ?? 1
        let size = [5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4][type] ?? 4
        let stride = v["byteStride"] as? Int ?? size * components, start = (v["byteOffset"] as? Int ?? 0) + (a["byteOffset"] as? Int ?? 0), data = buffers[bi], normalized = a["normalized"] as? Bool == true
        guard start >= 0, stride >= size * components, count == 0 || start + (count-1) * stride + components * size <= data.count else { throw LoaderError.message("Буфер glTF обрезан.") }
        return (0..<count).map { i in (0..<components).map { j in
            let o = start + i * stride + j * size; var n: Float
            switch type {
            case 5120: n = Float(Int8(bitPattern: data[o])); if normalized { n = max(-1, n / 127) }
            case 5121: n = Float(data[o]); if normalized { n /= 255 }
            case 5122: n = Float(Int16(bitPattern: UInt16(data[o]) | UInt16(data[o+1]) << 8)); if normalized { n = max(-1, n / 32767) }
            case 5123: n = Float(UInt16(data[o]) | UInt16(data[o+1]) << 8); if normalized { n /= 65535 }
            case 5125: n = Float(data.u32(o))
            default: n = data.f32(o)
            }; return n
        } }
    }
    func primitive(_ p: [String: Any]) throws -> SCNNode {
        guard let attributes = p["attributes"] as? [String: Int], let position = attributes["POSITION"] else { throw LoaderError.message("В glTF нет координат вершин.") }
        let coords = try accessor(position)
        guard coords.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }) else { throw LoaderError.message("Неверные координаты glTF.") }
        let vertices = coords.map { SCNVector3($0[0],$0[1],$0[2]) }
        var indices = try (p["indices"] as? Int).map { try accessor($0).map { row -> UInt32 in guard let n = row.first, n >= 0, n < Float(UInt32.max) else { throw LoaderError.message("Неверный индекс glTF.") }; return UInt32(n) } } ?? vertices.indices.map(UInt32.init)
        let mode = p["mode"] as? Int ?? 4
        if mode == 5 || mode == 6 {
            let original = indices; indices = []
            if original.count >= 3 { for i in 2..<original.count { indices += mode == 6 ? [original[0],original[i-1],original[i]] : (i % 2 == 0 ? [original[i-2],original[i-1],original[i]] : [original[i-1],original[i-2],original[i]]) } }
        } else if mode != 4 { return SCNNode() }
        let normals = try (attributes["NORMAL"]).map { try accessor($0).compactMap { $0.count == 3 ? SCNVector3($0[0],$0[1],$0[2]) : nil } }
        var geometry = try ModelLoader.geometry(vertices: vertices, indices: indices, normals: normals)
        if let uv = attributes["TEXCOORD_0"] {
            let points = try accessor(uv).compactMap { $0.count == 2 ? CGPoint(x: Double($0[0]), y: Double(1-$0[1])) : nil }
            if points.count == vertices.count { geometry = SCNGeometry(sources: geometry.sources + [SCNGeometrySource(textureCoordinates: points)], elements: geometry.elements) }
        }
        let material = SCNMaterial(); material.lightingModel = .physicallyBased
        let materials = array("materials")
        let m = (p["material"] as? Int).flatMap { materials.indices.contains($0) ? materials[$0] : nil } ?? [:]
        let pbr = m["pbrMetallicRoughness"] as? [String: Any] ?? [:]
        let color = pbr["baseColorFactor"] as? [Double] ?? [0.7,0.75,0.85,1]
        if color.count == 4 { material.diffuse.contents = NSColor(calibratedRed: color[0], green: color[1], blue: color[2], alpha: color[3]) }
        material.roughness.contents = pbr["roughnessFactor"] as? Double ?? 1; material.metalness.contents = pbr["metallicFactor"] as? Double ?? 0
        material.isDoubleSided = m["doubleSided"] as? Bool ?? true
        if let texture = pbr["baseColorTexture"] as? [String: Any], let ti = texture["index"] as? Int {
            let textures = array("textures"), images = array("images"), views = array("bufferViews")
            if textures.indices.contains(ti), let ii = textures[ti]["source"] as? Int, images.indices.contains(ii) {
                var imageData: Data?
                if let uri = images[ii]["uri"] as? String { imageData = try uriData(uri) }
                else if let vi = images[ii]["bufferView"] as? Int, views.indices.contains(vi) {
                    let v = views[vi], bi = v["buffer"] as? Int ?? 0, start = v["byteOffset"] as? Int ?? 0, len = v["byteLength"] as? Int ?? 0
                    if buffers.indices.contains(bi), start >= 0, len >= 0, start + len <= buffers[bi].count { imageData = buffers[bi].subdata(in: start..<start+len) }
                }
                if let imageData, let image = NSImage(data: imageData) { material.diffuse.contents = image }
            }
        }
        geometry.materials = [material]; return SCNNode(geometry: geometry)
    }
}
