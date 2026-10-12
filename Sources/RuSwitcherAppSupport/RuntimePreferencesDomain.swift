import Foundation

public enum RuntimePreferencesDomain {
    public static let hidProbeSuiteName = "com.ruswitcher.hidhost"

    public static func isolatedSuiteName(arguments: [String]) -> String? {
        if let index = arguments.firstIndex(of: "--external-native-probe"),
           arguments.indices.contains(index + 1), let runID = UUID(uuidString: arguments[index + 1]) {
            return "com.ruswitcher.nativeprobe.\(runID.uuidString.lowercased())"
        }
        let probeArguments = Set([
            "--hid-probe",
            "--hid-probe-file",
            "--hid-transport-probe-file",
        ])
        guard arguments.contains(where: { argument in probeArguments.contains(argument) }),
              !arguments.contains("--hid-use-standard-preferences") else { return nil }
        return hidProbeSuiteName
    }
}
