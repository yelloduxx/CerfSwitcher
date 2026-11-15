enum CallbackPhaseProbe {
    @inline(__always)
    static func mark(_ phase: StaticString) {}
}
