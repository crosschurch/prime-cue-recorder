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

    /// Every playlist, with folders flattened.
    public func playlists() async throws -> [PPPlaylist] {
        func flatten(_ nodes: [[String: Any]]) -> [PPPlaylist] {
            nodes.flatMap { node -> [PPPlaylist] in
                let id = node["id"] as? [String: Any] ?? [:]
                if let children = node["children"] as? [[String: Any]], !children.isEmpty {
                    return flatten(children)
                }
                guard (node["field_type"] as? String ?? "playlist") == "playlist",
                      let uuid = id["uuid"] as? String else { return [] }
                return [PPPlaylist(id: uuid, name: id["name"] as? String ?? "")]
            }
        }
        return flatten(try await getAny("v1/playlists") as? [[String: Any]] ?? [])
    }

    /// The playlist in use right now: the one live content came from, else the one selected.
    public func currentPlaylistId() async -> String? {
        func uuid(_ json: [String: Any]?, _ keys: [String]) -> String? {
            var node: Any? = json
            for key in keys { node = (node as? [String: Any])?[key] }
            return node as? String
        }
        if let active = try? await get("v1/playlist/active"),
           let id = uuid(active, ["presentation", "playlist", "uuid"]) { return id }
        if let focused = try? await get("v1/playlist/focused") {
            return uuid(focused, ["playlist", "uuid"]) ?? uuid(focused, ["uuid"])
        }
        return nil
    }

    public func playlistItems(id: String) async throws -> [PPPlaylistItem] {
        let items = try await get("v1/playlist/\(id)")["items"] as? [[String: Any]] ?? []
        return items.enumerated().compactMap { offset, item in
            let id = item["id"] as? [String: Any] ?? [:]
            let info = item["presentation_info"] as? [String: Any]
            return PPPlaylistItem(id: id["uuid"] as? String ?? UUID().uuidString, name: id["name"] as? String ?? "",
                                  index: id["index"] as? Int ?? offset, type: item["type"] as? String ?? "",
                                  presentationId: info?["presentation_uuid"] as? String)
        }
    }

    private func get(_ path: String) async throws -> [String: Any] {
        try await getAny(path) as? [String: Any] ?? [:]
    }

    private func getAny(_ path: String) async throws -> Any {
        let (data, response) = try await session.data(from: base.appendingPathComponent(path))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONSerialization.jsonObject(with: data)
    }
}
