import AppKit
import Carbon
import InputMethodKit
import RuSwitcherCore

@objc(RuSwitcherInputApplication)
final class RuSwitcherInputApplication: NSApplication {}

private func registerInputMethod() -> Int32 {
    let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
    guard status == noErr else {
        FileHandle.standardError.write(Data("registration failed: \(status)\n".utf8))
        return 1
    }
    var failed = false
    for mode in InputMethodMode.allCases {
        let conditions = [
            kTISPropertyInputSourceID as String: mode.sourceID,
        ] as CFDictionary
        guard let sources = TISCreateInputSourceList(conditions, true)?.takeRetainedValue()
                as? [TISInputSource],
              let source = sources.first
        else {
            FileHandle.standardError.write(Data("input source missing: \(mode.sourceID)\n".utf8))
            failed = true
            continue
        }
        let status = TISEnableInputSource(source)
        if status != noErr {
            FileHandle.standardError.write(Data("enable failed: \(mode.sourceID) status=\(status)\n".utf8))
            failed = true
        }
    }
    return failed ? 1 : 0
}

private func verifyRegistration() -> Int32 {
    for mode in InputMethodMode.allCases {
        let conditions = [
            kTISPropertyInputSourceID as String: mode.sourceID,
        ] as CFDictionary
        guard let sources = TISCreateInputSourceList(conditions, true)?.takeRetainedValue()
                as? [TISInputSource],
              let source = sources.first
        else {
            FileHandle.standardError.write(Data("input source missing: \(mode.sourceID)\n".utf8))
            return 1
        }
        let selectable = booleanProperty(source, key: kTISPropertyInputSourceIsSelectCapable)
        let enabled = booleanProperty(source, key: kTISPropertyInputSourceIsEnabled)
        guard selectable, enabled else {
            FileHandle.standardError.write(Data(
                "input source unavailable: \(mode.sourceID) selectable=\(selectable) enabled=\(enabled)\n".utf8
            ))
            return 1
        }
    }
    return 0
}

private func booleanProperty(_ source: TISInputSource, key: CFString) -> Bool {
    guard let pointer = TISGetInputSourceProperty(source, key) else { return false }
    let value = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
    return (value as? NSNumber)?.boolValue == true
}

private func selfCheck() -> Int32 {
    guard Bundle.main.bundleIdentifier == InputMethodMode.bundleIdentifier,
          NSClassFromString("RuSwitcherInputController") != nil,
          LanguageModelStore.bundled != nil,
          InputMethodMode.allCases.allSatisfy({ mode in
              guard let modes = Bundle.main.object(forInfoDictionaryKey: "ComponentInputModeDict")
                      as? [String: Any],
                    let list = modes["tsInputModeListKey"] as? [String: Any]
              else { return false }
              return list[mode.sourceID] != nil
          })
    else {
        FileHandle.standardError.write(Data("Input Method self-check failed\n".utf8))
        return 1
    }
    return 0
}

if CommandLine.arguments.contains("--register") {
    exit(registerInputMethod())
}
if CommandLine.arguments.contains("--verify-registration") {
    exit(verifyRegistration())
}
if CommandLine.arguments.contains("--self-check") {
    exit(selfCheck())
}
if CommandLine.arguments.contains("--select-en") {
    exit(InputMethodMode.english.select() ? 0 : 1)
}
if CommandLine.arguments.contains("--select-ru") {
    exit(InputMethodMode.russian.select() ? 0 : 1)
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
guard let connectionName = Bundle.main.object(forInfoDictionaryKey: "InputMethodConnectionName")
        as? String,
      let bundleIdentifier = Bundle.main.bundleIdentifier
else {
    fatalError("Input Method bundle metadata is incomplete")
}
let server = IMKServer(name: connectionName, bundleIdentifier: bundleIdentifier)
withExtendedLifetime(server) {
    application.run()
}
