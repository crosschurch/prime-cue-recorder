import Foundation

public struct PPSlideIndex: Equatable, Sendable {
    public let uuid: String
    public let name: String
    public let index: Int   // 0-based across the whole presentation
}

public struct PPPresentation: Sendable {
    public let uuid: String
    public let name: String
    public let slides: [(group: String, text: String)]
}

/// Talks to ProPresenter 7's network API (ProPresenter > Settings > Network > Enable Network).
public final class ProPresenterClient: @unchecked Sendable {
    let base: URL
    let session: URLSession

    public init?(host: String, port: Int) {
        guard let url = URL(string: "http://\(host.trimmingCharacters(in: .whitespaces)):\(port)") else { return nil }
        base = url
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        session = URLSession(configuration: config)
    }

    /// e.g. "ProPresenter 7.16"
    public func version() async throws -> String {
        let json = try await get("version")
        return json["host_description"] as? String ?? json["name"] as? String ?? "ProPresenter"
    }

    /// The slide currently showing, or nil when nothing is.
    public func slideIndex() async throws -> PPSlideIndex? {
        guard let current = try await get("v1/presentation/slide_index")["presentation_index"] as? [String: Any],
              let index = current["index"] as? Int,
              let id = current["presentation_id"] as? [String: Any],
              let uuid = id["uuid"] as? String else { return nil }
        return PPSlideIndex(uuid: uuid, name: id["name"] as? String ?? "", index: index)
    }

    public func presentation(uuid: String) async throws -> PPPresentation {
        let p = try await get("v1/presentation/\(uuid)")["presentation"] as? [String: Any] ?? [:]
        let id = p["id"] as? [String: Any] ?? [:]
        let slides = (p["groups"] as? [[String: Any]] ?? []).flatMap { group in
            (group["slides"] as? [[String: Any]] ?? []).map {
                (group: group["name"] as? String ?? "", text: $0["text"] as? String ?? "")
            }
        }
        return PPPresentation(uuid: uuid, name: id["name"] as? String ?? "", slides: slides)
    }

    private func get(_ path: String) async throws -> [String: Any] {
        let (data, response) = try await session.data(from: base.appendingPathComponent(path))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
