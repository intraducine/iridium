import Foundation
import IridiumCore

public struct PerformanceTelemetrySnapshot: Codable, Hashable, Sendable {
    public var averageFPS: Double
    public var frameTimeP95MS: Double
    public var memoryPressureRatio: Double
    public var thermalState: HostThermalState

    public init(
        averageFPS: Double,
        frameTimeP95MS: Double,
        memoryPressureRatio: Double,
        thermalState: HostThermalState
    ) {
        self.averageFPS = averageFPS
        self.frameTimeP95MS = frameTimeP95MS
        self.memoryPressureRatio = memoryPressureRatio
        self.thermalState = thermalState
    }
}

public enum ThermalMitigationAction: String, Codable, CaseIterable, Sendable {
    case none
    case reduceResolution
    case capFrameRate
    case disableShaderPrewarm
    case blockLaunch
}

public protocol RuntimeAdaptationPolicy: Sendable {
    func mitigation(for telemetry: PerformanceTelemetrySnapshot, basePolicy: RuntimePolicy) -> ThermalMitigationAction
}

public struct DefaultRuntimeAdaptationPolicy: RuntimeAdaptationPolicy {
    public init() {}

    public func mitigation(for telemetry: PerformanceTelemetrySnapshot, basePolicy: RuntimePolicy) -> ThermalMitigationAction {
        let resolutionCanDrop = basePolicy.resolutionScale > 0.5
        let frameCapCanDrop = (basePolicy.framePacingCap ?? 120) > 45
        let shaderPressureCanDrop = basePolicy.shaderStrategy != .onDemand
        let sustainedPressure = telemetry.thermalState == .serious ||
            telemetry.memoryPressureRatio >= 0.9 ||
            telemetry.frameTimeP95MS >= 35

        if telemetry.thermalState == .critical || telemetry.memoryPressureRatio >= 0.98 {
            return .blockLaunch
        }

        if sustainedPressure, resolutionCanDrop {
            return .reduceResolution
        }

        if sustainedPressure, frameCapCanDrop {
            return .capFrameRate
        }

        if sustainedPressure, shaderPressureCanDrop {
            return .disableShaderPrewarm
        }

        if telemetry.thermalState == .serious || telemetry.memoryPressureRatio >= 0.94 {
            return .blockLaunch
        }

        return .none
    }
}
