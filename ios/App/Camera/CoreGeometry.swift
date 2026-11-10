import DogMonitorCore

/// Vision also declares `NormalizedRect`, and the core module has a type named like the module, so
/// `DogMonitorCore.NormalizedRect` can't be spelled in files that import Vision. Use this instead.
typealias CoreNormalizedRect = NormalizedRect
