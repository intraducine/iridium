import Foundation

public enum CPUTranslationLayer: String, Codable, CaseIterable, Sendable {
    case x86ToARM64JIT
    case x64ToARM64JIT

    public var displayName: String {
        switch self {
        case .x86ToARM64JIT:
            "x86 -> ARM64 JIT"
        case .x64ToARM64JIT:
            "x64 -> ARM64 JIT"
        }
    }
}

public enum GraphicsStack: String, Codable, CaseIterable, Sendable {
    case dxvkViaMoltenVK
    case vkd3dViaMoltenVK
    case metalOpenGLFallback
    case dxmtViaMetal

    public var displayName: String {
        switch self {
        case .dxvkViaMoltenVK:
            "DXVK via MoltenVK"
        case .vkd3dViaMoltenVK:
            "VKD3D via MoltenVK"
        case .metalOpenGLFallback:
            "Metal OpenGL Fallback"
        case .dxmtViaMetal:
            "DXMT via Metal"
        }
    }
}

public struct RuntimeDescriptor: Hashable, Codable, Sendable {
    public var identifier: String
    public var name: String
    public var cpuTranslation: CPUTranslationLayer
    public var graphicsStack: GraphicsStack
    public var exposesDesktopShell: Bool

    public init(
        identifier: String = "iridium-runtime-base",
        name: String,
        cpuTranslation: CPUTranslationLayer,
        graphicsStack: GraphicsStack,
        exposesDesktopShell: Bool
    ) {
        self.identifier = identifier
        self.name = name
        self.cpuTranslation = cpuTranslation
        self.graphicsStack = graphicsStack
        self.exposesDesktopShell = exposesDesktopShell
    }
}

public extension RuntimeDescriptor {
    static let defaultDescriptor = RuntimeDescriptor(
        identifier: "iridium-runtime-base",
        name: "Iridium Runtime Base",
        cpuTranslation: .x64ToARM64JIT,
        graphicsStack: .metalOpenGLFallback,
        exposesDesktopShell: false
    )
}

public enum BundledRuntimeCatalog {
    public static let defaultRuntime = RuntimeDescriptor.defaultDescriptor
}
