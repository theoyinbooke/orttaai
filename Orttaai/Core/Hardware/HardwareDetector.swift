// HardwareDetector.swift
// Orttaai

import Foundation
import IOKit
import os

enum HardwareTier: String, Codable {
    case m1_8gb
    case m1_16gb
    case m3_16gb
    case intel_unsupported
}

struct HardwareInfo {
    let chipName: String
    let isAppleSilicon: Bool
    let ramGB: Int
    let gpuCoreCount: Int
    let availableDiskSpaceGB: Double
    let tier: HardwareTier
    let recommendedModel: String
}

final class HardwareDetector {

    static func detect() -> HardwareInfo {
        let chipName = getChipName()
        let isAppleSilicon = checkAppleSilicon()
        let ramGB = getRAMInGB()
        let gpuCores = getGPUCoreCount()
        let diskSpaceGB = getAvailableDiskSpaceGB()
        let tier = determineTier(isAppleSilicon: isAppleSilicon, ramGB: ramGB, chipName: chipName)
        let model = recommendedModel(for: tier)

        let info = HardwareInfo(
            chipName: chipName,
            isAppleSilicon: isAppleSilicon,
            ramGB: ramGB,
            gpuCoreCount: gpuCores,
            availableDiskSpaceGB: diskSpaceGB,
            tier: tier,
            recommendedModel: model
        )

        Logger.model.info("Hardware: \(chipName), \(ramGB)GB RAM, \(gpuCores) GPU cores, \(diskSpaceGB, format: .fixed(precision: 1))GB disk, tier: \(tier.rawValue)")
        return info
    }

    static func getChipName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var result = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &result, &size, nil, 0)
        return String(cString: result)
    }

    static func checkAppleSilicon() -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return result == 0 && value == 1
    }

    static func getRAMInGB() -> Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }

    static func getGPUCoreCount() -> Int {
        var size = 0
        sysctlbyname("machdep.gpu.core_count", nil, &size, nil, 0)
        if size > 0 {
            var coreCount: Int32 = 0
            var coreCountSize = MemoryLayout<Int32>.size
            sysctlbyname("machdep.gpu.core_count", &coreCount, &coreCountSize, nil, 0)
            if coreCount > 0 {
                return Int(coreCount)
            }
        }
        // Fallback: try IOKit
        return getGPUCoreCountViaIOKit()
    }

    private static func getGPUCoreCountViaIOKit() -> Int {
        let matching = IOServiceMatching("AGXAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return 0
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let coreCountRef = IORegistryEntryCreateCFProperty(
                service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0
            ) {
                let coreCount = coreCountRef.takeRetainedValue()
                if let number = coreCount as? NSNumber {
                    IOObjectRelease(service)
                    return number.intValue
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        return 0
    }

    static func getAvailableDiskSpaceGB() -> Double {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        do {
            let values = try homeURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let bytes = values.volumeAvailableCapacityForImportantUsage {
                return Double(bytes) / (1024 * 1024 * 1024)
            }
        } catch {
            Logger.model.error("Failed to get disk space: \(error.localizedDescription)")
        }
        return 0
    }

    static func determineTier(isAppleSilicon: Bool, ramGB: Int, chipName: String) -> HardwareTier {
        guard isAppleSilicon else {
            return .intel_unsupported
        }

        let isM3OrNewer = chipName.contains("M3") || chipName.contains("M4")
            || chipName.contains("M5") || chipName.contains("M6")

        if isM3OrNewer && ramGB >= 16 {
            return .m3_16gb
        } else if ramGB >= 16 {
            return .m1_16gb
        } else {
            return .m1_8gb
        }
    }

    static func recommendedModel(for tier: HardwareTier) -> String {
        switch tier {
        case .m3_16gb:
            return "openai_whisper-large-v3_turbo"
        case .m1_16gb:
            return "openai_whisper-large-v3_turbo"
        case .m1_8gb:
            return "openai_whisper-small"
        case .intel_unsupported:
            return ""
        }
    }
}
