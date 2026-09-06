import Foundation

/// The `{"error": "..."}` wire shape returned by generation failures (404) and other
/// non-2xx responses (investigation §1.8). Internal — callers see `VeloxQuantError`, not this.
struct ErrorBody: Codable {
    let error: String
}
