import Foundation
import SpeakerKit

public enum SpeakerKitLoader {
    public static func load(downloadBase: URL? = nil) async throws -> SpeakerKit {
        try await SpeakerKit(PyannoteConfig(downloadBase: downloadBase?.path, download: true, load: true, verbose: false, logLevel: .none))
    }
}
