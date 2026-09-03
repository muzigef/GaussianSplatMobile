import simd

func matrixTranslation(_ x: Float, _ y: Float, _ z: Float) -> simd_float4x4 {
    simd_float4x4(columns: (
        SIMD4<Float>(1, 0, 0, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(x, y, z, 1)
    ))
}

func matrixRotation(radians: Float, axis: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(simd_quatf(angle: radians, axis: simd_normalize(axis)))
}

func perspectiveRightHanded(
    verticalFieldOfView: Float,
    aspectRatio: Float,
    nearZ: Float,
    farZ: Float
) -> simd_float4x4 {
    let yScale = 1 / tan(verticalFieldOfView * 0.5)
    let xScale = yScale / max(aspectRatio, 0.001)
    let zScale = farZ / (nearZ - farZ)

    return simd_float4x4(columns: (
        SIMD4<Float>(xScale, 0, 0, 0),
        SIMD4<Float>(0, yScale, 0, 0),
        SIMD4<Float>(0, 0, zScale, -1),
        SIMD4<Float>(0, 0, zScale * nearZ, 0)
    ))
}
